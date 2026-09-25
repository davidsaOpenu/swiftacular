# The Device on its own, without an object server: how it reads metadata, and
# what a read sees while a POST lands.
# see ARCHITECTURE.md#concurrency

import gc
import logging

import eventlet
import pytest

from swift.common.utils import Timestamp

from bluestore.device import BluestoreDevice
from bluestore.metadata import MetadataModel

pytestmark = pytest.mark.device

GiB = 2 ** 30
NAME = "a/c/o"
BODY = b"body " * 1000


# Swift bounds only user metadata, so the Device reads metadata until a read
# comes back short; a small chunk size makes that take many reads.
def test_reads_metadata_in_chunks(tmp_path):
    conf = {"disk_chunk_size": "4096", "bluestore_capacity": str(GiB)}
    device = BluestoreDevice(str(tmp_path / "store"), conf, logging.getLogger("test"))
    timestamp = Timestamp(1_000_000)
    metadata = {"X-Timestamp": timestamp.internal}
    metadata.update({"X-Object-Sysmeta-%d" % i: "v" * 1000 for i in range(100)})

    current = device.open(NAME)
    obj = device.create(current)
    device.write(obj, BODY)
    device.put(obj, timestamp.raw, metadata)

    assert device.read_metadata(device.open(NAME))["data"] == metadata
    del current, obj, device
    gc.collect()


# A POST's metadata write is prepared before it is synced, and BlueStore only
# returns what it has applied. The next read-modify-write on the name has to
# see it anyway, or the POST is lost.
def test_sees_prepared_metadata(tmp_path):
    conf = {"bluestore_capacity": str(GiB)}
    device = BluestoreDevice(str(tmp_path / "store"), conf, logging.getLogger("test"))
    timestamp = Timestamp(1_000_000)

    obj = device.create(device.open(NAME))
    device.write(obj, BODY)
    device.put(obj, timestamp.raw, {"X-Timestamp": timestamp.internal})

    current = device.open(NAME)
    post = {"X-Timestamp": Timestamp(1_000_001).internal, "X-Object-Meta-Color": "blue"}
    current.write_metadata(MetadataModel.post(device.read_metadata(current), post))

    found, metadata = device.open(NAME, with_metadata=True)
    assert found is current
    assert metadata["meta"] == post
    del obj, current, found, device
    gc.collect()


# One greenthread POSTs over and over while the test reads. Each read must be
# one whole POST, never the start of one and the rest of another. Small chunks
# make a read yield many times, so the two interleave.
def test_metadata_read_is_never_torn(tmp_path):
    conf = {"disk_chunk_size": "1024", "bluestore_capacity": str(GiB)}
    device = BluestoreDevice(str(tmp_path / "store"), conf, logging.getLogger("test"))
    timestamp = Timestamp(1_000_000)

    obj = device.create(device.open(NAME))
    device.write(obj, BODY)
    device.put(obj, timestamp.raw, {"X-Timestamp": timestamp.internal})

    def post(second, value):
        meta = {"X-Timestamp": Timestamp(second).internal}
        meta.update({"X-Object-Meta-%d" % i: value * 100 for i in range(100)})
        return meta

    posts = [post(1_000_001 + i, "ab"[i % 2]) for i in range(50)]
    current = device.open(NAME)
    device.write_metadata(current, posts[0])

    def post_all():
        for meta in posts[1:]:
            device.write_metadata(current, meta)

    poster = eventlet.spawn(post_all)
    while not poster.dead:
        assert device.read_metadata(current)["meta"] in posts
    poster.wait()

    del obj, current, device
    gc.collect()
