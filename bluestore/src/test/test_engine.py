# The engine and the binding on their own, without an object server: the
# state rules, several stores in one process, and capacity.
# see ARCHITECTURE.md#testing

import gc
import os

import pytest

from bluestore._raw import Backend, ChangedError, ConflictError, StateError, STATE

pytestmark = pytest.mark.engine

GiB = 2 ** 30
NAME = "a/c/o"
BODY = b"body " * 1000


def put(back, name, body, metadata=b"{}", timestamp=None):
    prev = back.find(name)
    prev.open()

    obj = back.create(name)
    obj.write(body)
    obj.write_metadata(metadata)
    back.put(obj, prev, timestamp)
    obj.sync()
    return obj


def get(back, name, size=2 ** 20):
    obj = back.find(name)
    obj.open()
    return bytes(obj.read(0, size))


@pytest.fixture
def back(tmp_path):
    back = Backend(str(tmp_path / "store"), GiB)
    yield back
    del back
    gc.collect()


class TestStateRules:
    def test_open_only_once(self, back):
        obj = back.find(NAME)
        obj.open()
        assert obj.state == STATE.MISSING

        with pytest.raises(StateError):
            obj.open()

    def test_unwritten_objects_are_not_readable(self, back):
        obj = back.create(NAME)
        with pytest.raises(StateError):
            obj.read(0, 10)
        with pytest.raises(StateError):
            obj.read_metadata(0, 10)

        obj.write(b"x")
        assert obj.state == STATE.IN_WRITE
        with pytest.raises(StateError):
            obj.read(0, 10)

    def test_put_needs_a_written_object(self, back):
        prev = back.find(NAME)
        prev.open()
        with pytest.raises(StateError):
            back.put(back.create(NAME), prev)

    def test_tombstone_only_before_writing(self, back):
        obj = back.create(NAME)
        obj.write(b"x")
        with pytest.raises(StateError):
            obj.tombstone(b"{}")

    def test_no_metadata_on_a_retired_object(self, back):
        put(back, NAME, BODY)
        prev = back.find(NAME)
        prev.open()
        put_over = back.create(NAME)
        put_over.write(b"newer")
        put_over.write_metadata(b"{}")
        back.put(put_over, prev)
        put_over.sync()

        assert prev.state == STATE.OLD
        with pytest.raises(StateError):
            prev.write_metadata(b"{}")


class TestVersions:
    def test_conflict_when_not_newer(self, back):
        put(back, NAME, BODY, timestamp=200)
        for timestamp in (100, 200):
            prev = back.find(NAME)
            prev.open()
            obj = back.create(NAME)
            obj.write(b"stale")
            with pytest.raises(ConflictError):
                back.put(obj, prev, timestamp)

    def test_visible_after_sync(self, back):
        put(back, NAME, BODY, metadata=b'{"a": 1}', timestamp=300)
        obj = back.find(NAME)
        obj.open()
        assert obj.state == STATE.ACTIVE
        assert obj.ts == 300
        assert bytes(obj.read(0, len(BODY))) == BODY
        assert bytes(obj.read_metadata(0, 100)) == b'{"a": 1}'

    def test_read_through_a_stale_handle_changes(self, back):
        put(back, NAME, BODY)
        stale = back.find(NAME)
        stale.open()
        prev = back.find(NAME)
        prev.open()

        obj = back.create(NAME)
        obj.write(b"newer")
        obj.write_metadata(b"{}")
        back.put(obj, prev)
        obj.sync()

        with pytest.raises(ChangedError):
            stale.read(0, 10)

    def test_retired_object_stays_readable(self, back):
        put(back, NAME, BODY)
        prev = back.find(NAME)
        prev.open()

        obj = back.create(NAME)
        obj.write(b"newer")
        obj.write_metadata(b"{}")
        back.put(obj, prev)
        obj.sync()

        assert prev.state == STATE.OLD
        assert bytes(prev.read(0, len(BODY))) == BODY
        assert get(back, NAME) == b"newer"

    def test_tombstone(self, back):
        put(back, NAME, BODY)
        prev = back.find(NAME)
        prev.open()

        tomb = back.create(NAME)
        tomb.tombstone(b'{"deleted": 1}')
        back.put(tomb, prev)
        tomb.sync()

        obj = back.find(NAME)
        obj.open()
        assert obj.deleted
        assert bytes(obj.read(0, 10)) == b""


def test_estimates_are_unique(back):
    first, second = back.create(NAME).ts, back.create(NAME).ts
    assert first < second


def test_several_stores_in_one_process(tmp_path):
    body_a, body_b = os.urandom(3 * 2 ** 20), os.urandom(2 * 2 ** 20)

    a = Backend(str(tmp_path / "a"), GiB)
    put(a, NAME, body_a)
    assert get(a, NAME, len(body_a)) == body_a

    b = Backend(str(tmp_path / "b"), GiB)
    put(b, NAME, body_b)
    del b
    gc.collect()

    b = Backend(str(tmp_path / "b"))
    assert get(b, NAME, len(body_b)) == body_b
    del b
    gc.collect()

    b = Backend(str(tmp_path / "b"), 2 * GiB)
    assert os.path.getsize(tmp_path / "b" / "block") == 2 * GiB
    assert get(b, NAME, len(body_b)) == body_b
    put(b, "a/c/o2", body_b)
    assert get(b, "a/c/o2", len(body_b)) == body_b
    del b
    gc.collect()

    assert get(a, NAME, len(body_a)) == body_a
    del a
    gc.collect()


def test_capacity(tmp_path):
    path = str(tmp_path / "store")
    with pytest.raises(ValueError):
        Backend(path, 0)

    back = Backend(path, 2 * GiB)
    del back
    gc.collect()

    back = Backend(path, GiB)
    assert os.path.getsize(os.path.join(path, "block")) == 2 * GiB
    del back
    gc.collect()
