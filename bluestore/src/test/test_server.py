# Requests through the object server, answered by both backends and
# compared: the policy wiring first, then an object's lifecycle and the
# behaviour around it.
# see ARCHITECTURE.md#testing

from hashlib import md5

import pytest


@pytest.mark.diff
class TestPolicyWiring:
    """The custom swift.conf parsed and the bluestore policy registered
    (via the installed .pth hook -- no import in the harness)."""

    def test_bluestore_policy_present(self, policies):
        by_name = {p.name: p for p in policies}
        assert "bluestore" in by_name
        assert int(by_name["bluestore"]) == 1


@pytest.mark.diff
@pytest.mark.incremental
class TestObjectLifecycle:
    """One object, cradle to grave, states in lockstep on both backends."""

    PATH = "/sda1/0/a/c/lifecycle"
    SIZE = 2 ** 20 * 4 + 512
    BODY_A = b"A" * SIZE
    BODY_B = b"B" * SIZE
    BODY_C = b"C" * SIZE

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


def stamp(second):
    return "%010d.%05d" % (second, 0)


@pytest.mark.diff
@pytest.mark.incremental
class TestTombstones:
    """A DELETE leaves a tombstone that orders later requests."""

    PATH = "/sda1/0/a/c/tombstones"

    def test_delete_missing_is_404(self, call):
        assert call("DELETE", self.PATH).status_int == 404

    def test_put(self, call):
        assert call("PUT", self.PATH, body=b"first").status_int == 201

    def test_delete(self, call):
        assert call("DELETE", self.PATH).status_int == 204

    def test_get_and_head_are_404_with_timestamp(self, call):
        for method in ("GET", "HEAD"):
            resp = call(method, self.PATH)
            assert resp.status_int == 404
            assert "X-Backend-Timestamp" in resp.headers

    def test_older_put_conflicts(self, call):
        assert call("PUT", self.PATH, body=b"stale", timestamp=stamp(1)).status_int == 409

    def test_older_delete_is_404(self, call):
        assert call("DELETE", self.PATH, timestamp=stamp(1)).status_int == 404

    def test_newer_put(self, call):
        assert call("PUT", self.PATH, body=b"second").status_int == 201
        assert call("GET", self.PATH).body == b"second"


@pytest.mark.diff
@pytest.mark.incremental
class TestRanges:
    """Ranged reads, including one across the 1 MiB read chunk."""

    PATH = "/sda1/0/a/c/ranges"
    BODY = bytes(range(256)) * (3 * 2 ** 20 // 256)

    RANGES = [
        ("bytes=0-99", slice(0, 100)),
        ("bytes=-100", slice(-100, None)),
        ("bytes=3145000-", slice(3145000, None)),
        ("bytes=5-5", slice(5, 6)),
        ("bytes=1048000-1049000", slice(1048000, 1049001)),
    ]

    def test_put(self, call):
        assert call("PUT", self.PATH, body=self.BODY).status_int == 201

    @pytest.mark.parametrize("value, part", RANGES)
    def test_single_range(self, call, value, part):
        resp = call("GET", self.PATH, headers={"Range": value})
        assert resp.status_int == 206
        assert resp.body == self.BODY[part]

    def test_unsatisfiable(self, call):
        resp = call("GET", self.PATH, headers={"Range": "bytes=%d-" % len(self.BODY)})
        assert resp.status_int == 416

    def test_multiple_ranges(self, call):
        resp = call.diff("GET", self.PATH, headers={"Range": "bytes=0-9,1048570-1048585"})
        assert resp.status_int == 206
        assert self.BODY[0:10] in resp.body
        assert self.BODY[1048570:1048586] in resp.body


@pytest.mark.diff
@pytest.mark.incremental
class TestConditional:
    PATH = "/sda1/0/a/c/conditional"
    BODY = b"conditional"
    ETAG = md5(BODY).hexdigest()

    def test_put(self, call):
        assert call("PUT", self.PATH, body=self.BODY).status_int == 201

    def test_if_match(self, call):
        assert call("GET", self.PATH, headers={"If-Match": self.ETAG}).status_int == 200
        assert call("GET", self.PATH, headers={"If-Match": "nope"}).status_int == 412

    def test_if_none_match(self, call):
        assert call("GET", self.PATH, headers={"If-None-Match": self.ETAG}).status_int == 304
        assert call("GET", self.PATH, headers={"If-None-Match": "nope"}).status_int == 200

    def test_if_modified_since(self, call):
        after = {"If-Modified-Since": "Wed, 01 Jan 2020 00:00:00 GMT"}
        before = {"If-Modified-Since": "Thu, 01 Jan 1970 00:00:00 GMT"}
        assert call("GET", self.PATH, headers=after).status_int == 304
        assert call("GET", self.PATH, headers=before).status_int == 200


@pytest.mark.diff
class TestSmallObjects:
    def test_zero_bytes(self, call):
        path = "/sda1/0/a/c/zero"
        assert call("PUT", path, body=b"").status_int == 201

        resp = call("GET", path)
        assert resp.status_int == 200
        assert resp.body == b""
        assert call("HEAD", path).headers["Content-Length"] == "0"

    def test_overwrite_with_smaller(self, call):
        path = "/sda1/0/a/c/shrink"
        assert call("PUT", path, body=b"L" * (2 * 2 ** 20 + 3)).status_int == 201
        assert call("PUT", path, body=b"tiny body!").status_int == 201

        resp = call("GET", path)
        assert resp.body == b"tiny body!"
        assert resp.headers["Content-Length"] == "10"


@pytest.mark.diff
@pytest.mark.incremental
class TestPostMetadata:
    """What a POST replaces and what it has to leave alone."""

    PATH = "/sda1/0/a/c/post-metadata"

    def test_put(self, call):
        headers = {
            "Content-Type": "text/plain",
            "X-Object-Meta-A": "1",
            "X-Object-Sysmeta-S": "kept",
            "X-Object-Transient-Sysmeta-T": "old",
        }
        assert call("PUT", self.PATH, body=b"x", headers=headers).status_int == 201

    def test_post_replaces_user_metadata_and_type(self, call):
        headers = {"Content-Type": "text/html", "X-Object-Meta-B": "2"}
        assert call("POST", self.PATH, headers=headers).status_int == 202

        resp = call("HEAD", self.PATH)
        assert resp.headers["Content-Type"] == "text/html"
        assert resp.headers.get("X-Object-Meta-B") == "2"
        assert "X-Object-Meta-A" not in resp.headers

    def test_sysmeta_survives(self, call):
        assert call("HEAD", self.PATH).headers.get("X-Object-Sysmeta-S") == "kept"

    def test_transient_sysmeta_is_replaced(self, call):
        headers = {"Content-Type": "text/html", "X-Object-Transient-Sysmeta-T": "new"}
        assert call("POST", self.PATH, headers=headers).status_int == 202
        assert call("HEAD", self.PATH).headers.get("X-Object-Transient-Sysmeta-T") == "new"


@pytest.mark.diff
class TestPostKeepsContentType:
    """A POST that doesn't set Content-Type leaves the one the object has."""

    def test_post_without_content_type(self, call):
        path = "/sda1/0/a/c/post-keeps-type"
        assert call("PUT", path, body=b"x", headers={"Content-Type": "text/plain"}).status_int == 201
        assert call("POST", path, headers={"X-Object-Meta-A": "1"}).status_int == 202
        assert call("HEAD", path).headers["Content-Type"] == "text/plain"


@pytest.mark.diff
@pytest.mark.incremental
class TestTimestampOffset:
    """An offset in the data timestamp shows, and survives a POST."""

    PATH = "/sda1/0/a/c/offset"
    OFFSET = "0001000001.00000_0000000000000005"

    def test_put(self, call):
        assert call("PUT", self.PATH, body=b"x" * 1000, timestamp=self.OFFSET).status_int == 201

    def test_get(self, call):
        assert call("GET", self.PATH).headers["X-Backend-Data-Timestamp"] == self.OFFSET

    def test_post_then_head(self, call):
        assert call("POST", self.PATH, headers={"X-Object-Meta-Color": "blue"}).status_int == 202
        assert call("HEAD", self.PATH).headers["X-Backend-Data-Timestamp"] == self.OFFSET


@pytest.mark.diff
class TestLargeMetadata:
    """Sysmeta is outside the 4 KiB user-metadata limit."""

    def test_sysmeta_past_4k(self, call):
        path = "/sda1/0/a/c/large-metadata"
        headers = {"X-Object-Sysmeta-Big-%d" % i: "v" * 200 for i in range(40)}
        assert call("PUT", path, body=b"y", headers=headers).status_int == 201
        assert call("GET", path).status_int == 200
        assert call("HEAD", path).headers["X-Object-Sysmeta-Big-39"] == "v" * 200


@pytest.mark.diff
@pytest.mark.incremental
class TestPutUnderNewerPost:
    """PUT@1, POST@3, PUT@2: posix keeps POST@3's metadata over PUT@2's data."""

    PATH = "/sda1/0/a/c/put-under-post"
    BASE = 1_600_000

    def test_put(self, call):
        assert call("PUT", self.PATH, body=b"one", timestamp=stamp(self.BASE + 1)).status_int == 201

    def test_post(self, call):
        headers = {"X-Object-Meta-Color": "blue"}
        assert call("POST", self.PATH, timestamp=stamp(self.BASE + 3), headers=headers).status_int == 202

    def test_older_put_lands(self, call):
        assert call("PUT", self.PATH, body=b"two", timestamp=stamp(self.BASE + 2)).status_int == 201

    def test_get(self, call):
        resp = call("GET", self.PATH, timestamp=stamp(self.BASE + 4))
        assert resp.body == b"two"
        assert resp.headers.get("X-Object-Meta-Color") == "blue"


@pytest.mark.diff
@pytest.mark.incremental
class TestPostSurvivesDelete:
    """PUT@1, POST@5, DELETE@3, PUT@4: posix keeps the .meta newer than the
    .ts, and then newer than the second .data, so POST@5's metadata is back."""

    PATH = "/sda1/0/a/c/post-survives-delete"
    BASE = 1_700_000

    def test_put(self, call):
        assert call("PUT", self.PATH, body=b"one", timestamp=stamp(self.BASE + 1)).status_int == 201

    def test_post(self, call):
        headers = {"X-Object-Meta-Color": "blue"}
        assert call("POST", self.PATH, timestamp=stamp(self.BASE + 5), headers=headers).status_int == 202

    def test_older_delete(self, call):
        assert call("DELETE", self.PATH, timestamp=stamp(self.BASE + 3)).status_int == 204
        assert call("HEAD", self.PATH, timestamp=stamp(self.BASE + 6)).status_int == 404

    def test_put_under_the_post(self, call):
        assert call("PUT", self.PATH, body=b"two", timestamp=stamp(self.BASE + 4)).status_int == 201

        resp = call("GET", self.PATH, timestamp=stamp(self.BASE + 7))
        assert resp.body == b"two"
        assert resp.headers.get("X-Object-Meta-Color") == "blue"
        assert resp.headers["X-Backend-Timestamp"] == stamp(self.BASE + 5)


@pytest.mark.diff
@pytest.mark.incremental
class TestPostedContentTypeSurvives:
    """A content type set by a POST outlives a later POST that sets none."""

    PATH = "/sda1/0/a/c/posted-type-survives"

    def test_put(self, call):
        assert call("PUT", self.PATH, body=b"x", headers={"Content-Type": "text/plain"}).status_int == 201

    def test_post_with_type(self, call):
        assert call("POST", self.PATH, headers={"Content-Type": "text/html"}).status_int == 202

    def test_post_without_type(self, call):
        assert call("POST", self.PATH, headers={"X-Object-Meta-A": "1"}).status_int == 202
        assert call("HEAD", self.PATH).headers["Content-Type"] == "text/html"


@pytest.mark.diff
@pytest.mark.incremental
class TestOlderPostNewerType:
    """PUT@1, POST@3, then POST@2 with a content type: the object server lets
    it through for the type alone, which lands on POST@3's metadata."""

    PATH = "/sda1/0/a/c/older-post-newer-type"
    BASE = 1_900_000

    def test_put(self, call):
        headers = {"Content-Type": "text/plain"}
        assert call("PUT", self.PATH, body=b"x", timestamp=stamp(self.BASE + 1), headers=headers).status_int == 201

    def test_post(self, call):
        headers = {"X-Object-Meta-Color": "blue"}
        assert call("POST", self.PATH, timestamp=stamp(self.BASE + 3), headers=headers).status_int == 202

    def test_older_post_with_type(self, call):
        headers = {"Content-Type": "text/html", "X-Object-Meta-Shape": "square"}
        assert call("POST", self.PATH, timestamp=stamp(self.BASE + 2), headers=headers).status_int == 202

        resp = call("HEAD", self.PATH, timestamp=stamp(self.BASE + 4))
        assert resp.headers["Content-Type"] == "text/html"
        assert resp.headers.get("X-Object-Meta-Color") == "blue"
        assert "X-Object-Meta-Shape" not in resp.headers
        assert resp.headers["X-Backend-Timestamp"] == stamp(self.BASE + 3)


@pytest.mark.diff
class TestDeleteOffset:
    """A DELETE's timestamp offset is what a later 404 reports."""

    def test_offset_survives_delete(self, call):
        path = "/sda1/0/a/c/delete-offset"
        deleted = "0002000000.00000_0000000000000003"
        assert call("PUT", path, body=b"x", timestamp="0001999999.00000").status_int == 201
        assert call("DELETE", path, timestamp=deleted).status_int == 204
        assert call("HEAD", path, timestamp="0002000001.00000").headers["X-Backend-Timestamp"] == deleted
