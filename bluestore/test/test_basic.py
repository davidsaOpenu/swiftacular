# test_object_server_basic.py
#
# Basic operation of the object server, verified differentially: every
# call() runs against both the standard and bluestore backends and fails on
# ANY response difference. Classes are deliberate sequences -- methods run
# in definition order and build on shared server state.

from hashlib import md5
import pytest


class TestPolicyWiring:
    """The custom swift.conf parsed and the bluestore policy registered
    (via the installed .pth hook -- no import in the harness)."""

    def test_bluestore_policy_present(self, policies):
        by_name = {p.name: p for p in policies}
        assert "bluestore" in by_name
        assert int(by_name["bluestore"]) == 1


@pytest.mark.incremental
class TestObjectLifecycle:
    """One object, cradle to grave, states in lockstep on both backends."""

    PATH = "/sda1/0/a/c/lifecycle"
    BODY_A = b"A" * 512
    BODY_B = b"A" * 512
    BODY_C = b"A" * 512

    def test_get_before_put_is_404(self, call):
        assert call("GET", self.PATH).status_int == 404

    def test_put(self, call):
        resp = call("PUT", self.PATH, body=self.BODY_A,
                    headers={"Content-Type": "text/plain"})
        assert resp.status_int == 201

    def test_get_roundtrip(self, call):
        resp = call("GET", self.PATH)
        assert resp.status_int == 200
        assert resp.body == self.BODY_A
        assert resp.etag == md5(self.BODY_A).hexdigest()
        assert resp.headers["Content-Type"] == "text/plain"

    def test_head(self, call):
        resp = call("HEAD", self.PATH)
        assert resp.status_int == 200
        assert int(resp.headers["Content-Length"]) == len(self.BODY_A)
        assert resp.body == b""

    def test_post_metadata(self, call):
        resp = call("POST", self.PATH,
                    headers={"X-Object-Meta-Color": "blue",
                             "Content-Type": "text/plain"})
        assert resp.status_int == 202
        assert call("HEAD", self.PATH).headers["X-Object-Meta-Color"] == "blue"

    def test_overwrite_replaces_content_and_metadata(self, call):
        assert call("PUT", self.PATH, body=self.BODY_B).status_int == 201
        resp = call("GET", self.PATH)
        assert resp.body == self.BODY_B
        # user metadata does not survive a PUT
        assert "X-Object-Meta-Color" not in resp.headers

    def test_stale_put_conflicts(self, call):
        resp = call("PUT", self.PATH, body=b"stale",
                    timestamp="0000000001.00000")
        assert resp.status_int == 409
        assert call("GET", self.PATH).body == self.BODY_B

    def test_delete(self, call):
        assert call("DELETE", self.PATH).status_int == 204
        assert call("GET", self.PATH).status_int == 404

    def test_put_after_delete(self, call):
        assert call("PUT", self.PATH, body=self.BODY_C).status_int == 201
        assert call("GET", self.PATH).body == self.BODY_C
