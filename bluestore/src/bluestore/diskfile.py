from contextlib import contextmanager
import json

from swift.common import constraints
from swift.common.exceptions import DiskFileDeleted, DiskFileNotExist, \
    DiskFileNotOpen, DiskFileQuarantined
from swift.common.request_helpers import is_sys_meta
from swift.common.swob import multi_range_iterator
from swift.common.utils import Timestamp, md5
from swift.common.utils.timestamp import PRECISION
from swift.obj.diskfile import DATAFILE_SYSTEM_META, RESERVED_DATAFILE_META

from bluestore._raw import STATE


def when_open(fn):
    def wrapper(self, *args, **kwargs):
        if self.metadata is None:
            raise DiskFileNotOpen()
        return fn(self, *args, **kwargs)
    return wrapper


class BluestoreDiskFile:
    def __init__(self, backend, obj, chunk_size):
        self.chunk_size = chunk_size
        self.backend = backend
        self.object = obj

        self.metadata = None
        self.fragments = None

    def open(self, modernize=True, current_time=None):
        self.object.open()

        if self.object.state == STATE.MISSING:
            raise DiskFileNotExist()

        try:
            size = max(self.chunk_size, constraints.MAX_META_OVERALL_SIZE)
            metadata = json.loads(self.object.read_metadata(0, size))
        except ValueError as err:
            raise DiskFileQuarantined("%s: unreadable metadata: %s" % (self.object.name, err))

        if self.object.deleted:
            raise DiskFileDeleted(metadata)

        self.metadata = metadata
        return self

    @when_open
    def __enter__(self):
        return self

    def __exit__(self, *args):
        pass

    @when_open
    def get_metadata(self):
        return self.metadata

    get_datafile_metadata = get_metadata
    get_metafile_metadata = get_metadata

    @property
    @when_open
    def timestamp(self):
        return Timestamp(self.metadata['X-Timestamp'])

    @property
    @when_open
    def data_timestamp(self):
        return Timestamp(self.object.ts * PRECISION)

    content_type_timestamp = data_timestamp
    durable_timestamp = data_timestamp

    @property
    @when_open
    def content_type(self):
        return self.metadata.get('Content-Type')

    def read_metadata(self, current_time=None):
        with self.open(current_time=current_time):
            return self.get_metadata()

    def write_metadata(self, metadata):
        with self.open():
            static = {key: value for key, value in self.metadata.items()
                      if key.lower() in RESERVED_DATAFILE_META
                      or key.lower() in DATAFILE_SYSTEM_META
                      or is_sys_meta('object', key)}

            metadata.update(static)
            self.object.write_metadata(json.dumps(metadata).encode())

    def delete(self, timestamp):
        if self.object.state == STATE.PRE_SEARCH:
            self.object.open()

        stamp = Timestamp(timestamp)
        metadata = {'X-Timestamp': stamp.internal}

        tombstone = self.backend.create(self.object.name)
        tombstone.tombstone(json.dumps(metadata).encode())

        self.backend.put(tombstone, self.object, stamp.raw)
        self.object = tombstone

    def reader(self, keep_cache=False, cooperative_period=0, etag_validate_frac=1):
        return BluestoreDiskFileReader(self.object, self.chunk_size)

    def writer(self, size=None):
        return BluestoreDiskFileWriter(self.backend, self.backend.create(self.object.name))

    @contextmanager
    def create(self, size=None):
        writer = self.writer(size)
        try:
            yield writer.open()
        finally:
            writer.close()


class BluestoreDiskFileReader:
    def __init__(self, obj, chunk_size):
        self.chunk_size = chunk_size
        self.object = obj

        self.auto_close = True

    def __iter__(self):
        return self.app_iter_range()

    def app_iter_range(self, start=None, stop=None):
        offset = start or 0

        while stop is None or offset < stop:
            size = self.chunk_size
            if stop is not None:
                size = min(size, stop - offset)

            chunk = self.object.read(offset, size)
            if not chunk:
                break

            offset += len(chunk)
            yield chunk

            if len(chunk) < size:
                break

        if self.auto_close:
            self.close()

    def app_iter_ranges(self, ranges, content_type, boundary, size):
        if not ranges:
            yield b''
            return

        self.auto_close = False
        try:
            for chunk in multi_range_iterator(ranges, content_type,
                    boundary, size, self.app_iter_range):
                yield chunk
        finally:
            self.auto_close = True
            self.close()

    def close(self):
        self.object = None


class BluestoreDiskFileWriter:
    def __init__(self, backend, obj):
        self.backend = backend
        self.object = obj

        self.etag = md5(usedforsecurity=False)
        self.size = 0

    def open(self):
        return self

    def close(self):
        self.object = None

    def write(self, chunk):
        self.object.write(chunk)

        self.size += len(chunk)
        self.etag.update(chunk)

    def chunks_finished(self):
        return self.size, self.etag.hexdigest()

    def put(self, metadata):
        self.object.write_metadata(json.dumps(metadata).encode())

        prev = self.backend.find(self.object.name)
        prev.open()

        self.backend.put(self.object, prev, Timestamp(metadata['X-Timestamp']).raw)

    def commit(self, timestamp):
        pass
