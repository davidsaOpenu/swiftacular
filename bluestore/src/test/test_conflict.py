# Requests that pass Swift's own timestamp checks and then lose a race to a
# newer one. A request is paused just before its write, on both backends at
# once, while the newer request lands; posix settles these by cleanup and
# answers success, so the responses and the state left behind are compared.
# see ARCHITECTURE.md#testing

from collections import Counter
from contextlib import contextmanager
from types import SimpleNamespace

import eventlet
import eventlet.event
import pytest

from swift.common.utils import Timestamp


# Wraps a DiskFile so its write waits while its timestamp is paused. The three
# requests write in three places: PUT in its writer's put(), POST in
# write_metadata() and DELETE in delete().
class PausingDiskFile:
    def __init__(self, disk_file, pauses):
        self.disk_file = disk_file
        self.pauses = pauses

    def __getattr__(self, name):
        return getattr(self.disk_file, name)

    def write_metadata(self, metadata):
        self.pauses.wait(metadata['X-Timestamp'])
        return self.disk_file.write_metadata(metadata)

    def delete(self, timestamp):
        self.pauses.wait(timestamp)
        return self.disk_file.delete(timestamp)

    def writer(self, size=None):
        writer = self.disk_file.writer(size=size)
        put = writer.put

        def paused_put(metadata):
            self.pauses.wait(metadata['X-Timestamp'])
            return put(metadata)

        writer.put = paused_put
        return writer


# The timestamps whose writes wait, and how many writes have arrived at each.
class Pauses:
    def __init__(self):
        self.gates = {}
        self.arrived = Counter()

    def wait(self, timestamp):
        key = Timestamp(timestamp).internal
        if key in self.gates:
            self.arrived[key] += 1
            self.gates[key].wait()


# with paused(method, path, ...) as request: the request is sent to both
# backends and held just before its write; the block runs while it waits;
# on leaving the block it finishes, and request.response is ours after
# comparing both backends' responses.
@pytest.fixture
def paused(object_server, call):
    pauses = Pauses()
    get_diskfile = object_server.get_diskfile
    object_server.get_diskfile = lambda *args, **kwargs: PausingDiskFile(get_diskfile(*args, **kwargs), pauses)

    @contextmanager
    def pause(method, path, **kwargs):
        sent = call.spawn(method, path, **kwargs)
        key = Timestamp(sent.timestamp).internal
        pauses.gates[key] = eventlet.event.Event()

        with eventlet.Timeout(10, AssertionError("%s %s never reached its write" % (method, path))):
            while pauses.arrived[key] < 2:
                eventlet.sleep(0.001)

        request = SimpleNamespace(timestamp=sent.timestamp, response=None)
        yield request

        pauses.gates.pop(key).send()
        request.response = sent.wait()

    try:
        yield pause
    finally:
        del object_server.get_diskfile


@pytest.mark.diff
class TestConflicts:
    def test_put_loses_to_newer_put(self, call, paused):
        path = "/sda1/0/a/c/put-loses"
        assert call("PUT", path, body=b"first").status_int == 201

        with paused("PUT", path, body=b"older") as older:
            assert call("PUT", path, body=b"newer").status_int == 201

        assert older.response.status_int == 201
        assert call("GET", path).body == b"newer"

    def test_delete_loses_to_newer_put(self, call, paused):
        path = "/sda1/0/a/c/delete-loses"
        assert call("PUT", path, body=b"first").status_int == 201

        with paused("DELETE", path) as older:
            assert call("PUT", path, body=b"newer").status_int == 201

        assert older.response.status_int == 204
        assert call("GET", path).body == b"newer"

    def test_older_post_onto_replaced_object(self, call, paused):
        path = "/sda1/0/a/c/post-onto-replaced"
        assert call("PUT", path, body=b"first").status_int == 201

        with paused("POST", path, headers={"X-Object-Meta-Color": "red"}) as older:
            assert call("PUT", path, body=b"newer", headers={"X-Object-Meta-Shape": "square"}).status_int == 201

        assert older.response.status_int == 202
        resp = call("GET", path)
        assert resp.headers.get("X-Object-Meta-Shape") == "square"
        assert "X-Object-Meta-Color" not in resp.headers

    def test_newer_post_onto_replaced_object(self, call, paused):
        path = "/sda1/0/a/c/newer-post-onto-replaced"
        assert call("PUT", path, body=b"first").status_int == 201
        put, post = call.stamps(2)

        with paused("POST", path, timestamp=post, headers={"X-Object-Meta-Color": "red"}) as newer:
            assert call("PUT", path, body=b"second", timestamp=put).status_int == 201

        assert newer.response.status_int == 202
        assert call("GET", path).headers.get("X-Object-Meta-Color") == "red"

    def test_older_post_lands_after_newer_post(self, call, paused):
        path = "/sda1/0/a/c/post-against-post"
        assert call("PUT", path, body=b"first").status_int == 201
        first, second = call.stamps(2)

        with paused("POST", path, timestamp=first, headers={"X-Object-Meta-Color": "red"}) as older:
            assert call("POST", path, timestamp=second, headers={"X-Object-Meta-Color": "blue"}).status_int == 202

        assert older.response.status_int == 202
        assert call("GET", path).headers.get("X-Object-Meta-Color") == "blue"

    def test_older_post_onto_deleted_object(self, call, paused):
        path = "/sda1/0/a/c/older-post-onto-deleted"
        assert call("PUT", path, body=b"first").status_int == 201

        with paused("POST", path, headers={"X-Object-Meta-Color": "red"}) as older:
            assert call("DELETE", path).status_int == 204

        assert older.response.status_int == 202
        assert call("GET", path).status_int == 404

    def test_newer_post_onto_deleted_object(self, call, paused):
        path = "/sda1/0/a/c/newer-post-onto-deleted"
        assert call("PUT", path, body=b"first").status_int == 201
        delete, put, post = call.stamps(3)

        with paused("POST", path, timestamp=post, headers={"X-Object-Meta-Color": "red"}) as newer:
            assert call("DELETE", path, timestamp=delete).status_int == 204

        assert newer.response.status_int == 202
        assert call("GET", path).status_int == 404

        assert call("PUT", path, body=b"second", timestamp=put).status_int == 201
        assert call("GET", path).headers.get("X-Object-Meta-Color") == "red"
