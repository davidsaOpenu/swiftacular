# The Device: everything the Python layer does with a store goes through it,
# and nothing else calls the engine. Calls that wait go to tpool. Calls that
# only prepare stay on the hub and keep the interpreter lock, so a decision and
# its transaction are one step, and the map moves to a new Object in that same
# step. A put or delete that loses to a newer one is dropped, as Swift's own
# backend drops it.
# see ARCHITECTURE.md#concurrency

import weakref

import eventlet
from eventlet import tpool

from bluestore._raw import Backend, Object, ChangedError, ConflictError, STATE
from bluestore.metadata import MetadataModel

# Seconds to wait before each retry of a read that raced a put. A put's renames
# are usually submitted by the time we run again, so the first only yields.
DURATIONS = (0, 0.0001, 0.001, 0.01)

def retry(fn):
    def wrapper(*args, **kwargs):
        for delay in DURATIONS:
            try:
                return fn(*args, **kwargs)
            except ChangedError:
                eventlet.sleep(delay)
        return fn(*args, **kwargs)
    return wrapper


class BluestoreDevice:
    def __init__(self, path, conf, logger):
        self.logger = logger

        self.chunk_size = int(conf.get('disk_chunk_size', 2 ** 20))
        self.capacity = int(conf.get('bluestore_capacity', 100 * (2 ** 30)))
        if conf.get('bluestore_capacity') is None:
            logger.warning("bluestore_capacity is not set")

        def mount():
            backend = tpool.execute(Backend, path, self.capacity)
            tpool.execute(backend.clean)
            tpool.execute(backend.submit)
            self.backend = backend

        # The Object each name resolves to, shared by every request that wants
        # it, and each Object's metadata version, raised by every POST.
        self.objects = weakref.WeakValueDictionary()
        self.versions = weakref.WeakKeyDictionary()

        self.backend = eventlet.spawn(mount)

    def open(self, name, with_metadata=False):
        if not isinstance(self.backend, Backend):
            self.backend.wait()

        def find():
            obj = self.backend.find(name)
            tpool.execute(obj.open)

            self.objects[name] = obj
            return obj

        while True:
            obj = self.objects.get(name)
            if obj is None:
                obj = eventlet.spawn(find)
                self.objects[name] = obj

            if not isinstance(obj, Object):
                obj.wait()
                continue

            if obj.state == STATE.MISSING or not with_metadata:
                metadata = None
                break

            metadata = self.read_metadata(obj)
            if self.objects.get(name) is not obj:
                continue

            break

        if with_metadata:
            return obj, metadata
        else:
            return obj

    def create(self, obj):
        return self.backend.create(obj.name)

    @retry
    def read(self, obj, start=None, end=None):
        offset = start or 0
        size = end - offset if end else float("inf")
        size = min(size, self.chunk_size)

        chunk = tpool.execute(obj.read, offset, size)

        return chunk, len(chunk) != size

    @retry
    def read_metadata(self, obj):
        version = self.versions.get(obj, 0)
        tpool.execute(obj.sync)
        data = bytearray()

        while True:
            chunk = tpool.execute(obj.read_metadata, len(data), self.chunk_size)
            data += chunk

            if self.versions.get(obj, 0) != version:
                version = self.versions.get(obj, 0)
                tpool.execute(obj.sync)
                data = bytearray()
            elif len(chunk) < self.chunk_size:
                return MetadataModel.get(data)

    def write(self, obj, data):
        obj.write(data)
        tpool.execute(self.backend.submit)

    def write_metadata(self, obj, post):
        obj, prev = self.open(obj.name, with_metadata=True)

        meta = MetadataModel.post(prev, post)
        if meta is None:
            return

        obj.write_metadata(meta)
        self.versions[obj] = self.versions.get(obj, 0) + 1

        tpool.execute(obj.sync)

    def delete(self, obj, timestamp, meta=None):
        prev, prev_meta = self.open(obj.name, with_metadata=True)

        tomb = self.backend.create(obj.name)
        tomb.tombstone(MetadataModel.delete(prev_meta, timestamp, meta))

        try:
            self.backend.put(tomb, prev, timestamp)
        except ConflictError:
            return

        self.objects[obj.name] = tomb
        tpool.execute(tomb.sync)

    def put(self, obj, timestamp, meta=None):
        prev, prev_meta = self.open(obj.name, with_metadata=True)
        meta = MetadataModel.put(prev_meta, meta)

        if meta is not None:
            obj.write_metadata(meta)

        try:
            self.backend.put(obj, prev, timestamp)
        except ConflictError:
            return

        self.objects[obj.name] = obj
        tpool.execute(obj.sync)
