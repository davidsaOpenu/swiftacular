# The metadata rules on their own: what a read sees, what a new version keeps,
# and what a POST changes. Pure, so no store is involved.
# see ARCHITECTURE.md#interface
# see swift/obj/diskfile.py _construct_from_data_file

import json

import pytest

from swift.common.utils import Timestamp

from bluestore.metadata import MetadataModel

pytestmark = pytest.mark.device


def ts(second, offset=0):
    return Timestamp(second, offset=offset).internal


def blob(data, meta=None):
    sections = {"data": data}
    if meta is not None:
        sections["meta"] = meta
    return json.dumps(sections).encode()


def get(data, meta=None):
    return MetadataModel.get(blob(data, meta))


DATA = {
    "X-Timestamp": ts(1),
    "Content-Type": "text/plain",
    "Content-Length": "3",
    "ETag": "etag",
    "X-Static-Large-Object": "True",
    "X-Object-Sysmeta-S": "kept",
    "X-Object-Meta-A": "1",
}


class TestGet:
    def test_without_post(self):
        metadata = get(DATA)
        assert metadata["meta"] is None
        assert metadata["merged"] == DATA
        assert metadata["meta_ts"] == metadata["data_ts"] == metadata["type_ts"] == Timestamp(1)

    def test_post_replaces_all_but_the_data_fields(self):
        meta = {"X-Timestamp": ts(2), "X-Object-Meta-B": "2", "ETag": "forged", "X-Object-Sysmeta-S": "forged"}
        merged = get(DATA, meta)["merged"]

        assert merged["X-Timestamp"] == ts(2)
        assert merged["X-Object-Meta-B"] == "2"
        assert "X-Object-Meta-A" not in merged
        for key in ("ETag", "Content-Length", "X-Static-Large-Object", "X-Object-Sysmeta-S", "Content-Type"):
            assert merged[key] == DATA[key]

    def test_timestamps(self):
        metadata = get(DATA, {"X-Timestamp": ts(2)})
        assert metadata["meta_ts"] == Timestamp(2)
        assert metadata["data_ts"] == Timestamp(1)
        assert metadata["type_ts"] == Timestamp(1)

    def test_content_type_from_a_newer_post(self):
        meta = {"X-Timestamp": ts(2), "Content-Type": "text/html", "Content-Type-Timestamp": ts(2)}
        metadata = get(DATA, meta)
        assert metadata["merged"]["Content-Type"] == "text/html"
        assert metadata["type_ts"] == Timestamp(2)

    def test_content_type_older_than_the_data(self):
        data = dict(DATA, **{"X-Timestamp": ts(4)})
        meta = {"X-Timestamp": ts(6), "Content-Type": "text/html", "Content-Type-Timestamp": ts(3)}
        metadata = get(data, meta)
        assert metadata["merged"]["Content-Type"] == "text/plain"
        assert "Content-Type-Timestamp" not in metadata["merged"]
        assert metadata["type_ts"] == Timestamp(4)

    def test_data_timestamp_keeps_its_offset(self):
        metadata = get(dict(DATA, **{"X-Timestamp": ts(1, offset=5)}))
        assert metadata["data_ts"] == Timestamp(1, offset=5)


class TestPut:
    def test_nothing_before(self):
        assert json.loads(MetadataModel.put(None, DATA)) == {"data": DATA}

    def test_keeps_a_newer_post(self):
        prev = get(DATA, {"X-Timestamp": ts(5), "X-Object-Meta-B": "2"})
        new = json.loads(MetadataModel.put(prev, {"X-Timestamp": ts(3)}))
        assert new["meta"] == prev["meta"]

    @pytest.mark.parametrize("post", [2, 3])
    def test_drops_a_post_not_newer(self, post):
        prev = get(DATA, {"X-Timestamp": ts(post)})
        new = json.loads(MetadataModel.put(prev, {"X-Timestamp": ts(3)}))
        assert "meta" not in new


class TestDelete:
    def test_tombstone_from_the_timestamp(self):
        new = json.loads(MetadataModel.delete(None, Timestamp(7).raw))
        assert new == {"data": {"X-Timestamp": ts(7)}}

    def test_tombstone_from_given_metadata(self):
        given = {"X-Timestamp": ts(7, offset=2)}
        new = json.loads(MetadataModel.delete(None, Timestamp(7).raw, given))
        assert new == {"data": given}

    def test_keeps_a_newer_post(self):
        prev = get(DATA, {"X-Timestamp": ts(9)})
        new = json.loads(MetadataModel.delete(prev, Timestamp(7).raw))
        assert new["meta"] == prev["meta"]


class TestPost:
    def test_nothing_holds_the_name(self):
        assert MetadataModel.post(None, {"X-Timestamp": ts(2)}) is None

    @pytest.mark.parametrize("post", [0, 1])
    def test_not_newer_than_the_data(self, post):
        assert MetadataModel.post(get(DATA), {"X-Timestamp": ts(post)}) is None

    def test_first_post(self):
        post = {"X-Timestamp": ts(2), "X-Object-Meta-B": "2"}
        new = json.loads(MetadataModel.post(get(DATA), post))
        assert new == {"data": DATA, "meta": post}

    def test_newer_post_replaces(self):
        post = {"X-Timestamp": ts(3), "X-Object-Meta-C": "3"}
        new = json.loads(MetadataModel.post(get(DATA, {"X-Timestamp": ts(2), "X-Object-Meta-B": "2"}), post))
        assert new["meta"] == post

    def test_older_post_changes_nothing(self):
        prev = get(DATA, {"X-Timestamp": ts(3), "X-Object-Meta-B": "2"})
        assert MetadataModel.post(prev, {"X-Timestamp": ts(2), "X-Object-Meta-C": "3"}) is None

    def test_older_post_with_a_newer_content_type(self):
        meta = {"X-Timestamp": ts(3), "X-Object-Meta-B": "2"}
        post = {"X-Timestamp": ts(2), "X-Object-Meta-C": "3", "Content-Type": "text/html", "Content-Type-Timestamp": ts(2)}
        new = json.loads(MetadataModel.post(get(DATA, meta), post))
        assert new["meta"] == dict(meta, **{"Content-Type": "text/html", "Content-Type-Timestamp": ts(2)})

    def test_same_post_with_a_newer_content_type(self):
        meta = {"X-Timestamp": ts(3), "X-Object-Meta-B": "2"}
        post = dict(meta, **{"Content-Type": "text/html", "Content-Type-Timestamp": ts(2)})
        new = json.loads(MetadataModel.post(get(DATA, meta), post))
        assert new["meta"] == post

    def test_newer_post_keeps_an_older_posts_content_type(self):
        meta = {"X-Timestamp": ts(2), "Content-Type": "text/html", "Content-Type-Timestamp": ts(2)}
        post = {"X-Timestamp": ts(3), "X-Object-Meta-C": "3"}
        new = json.loads(MetadataModel.post(get(DATA, meta), post))
        assert new["meta"] == dict(post, **{"Content-Type": "text/html", "Content-Type-Timestamp": ts(2)})
