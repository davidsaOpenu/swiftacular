# Swift's DiskFile for one name: what the object server opens, reads, writes
# and deletes through. It translates each call into the Device's.
# see ARCHITECTURE.md#interface

from contextlib import contextmanager

from swift.common.exceptions import DiskFileDeleted, DiskFileNotExist, \
    DiskFileNotOpen, DiskFileQuarantined
from swift.common.utils import Timestamp

from bluestore.reader import BluestoreDiskFileReader
from bluestore.writer import BluestoreDiskFileWriter
from bluestore._raw import STATE


def when_open(fn):
    def wrapper(self, *args, **kwargs):
        if self.metadata is None:
            raise DiskFileNotOpen()
        return fn(self, *args, **kwargs)
    return wrapper


class BluestoreDiskFile:
    def __init__(self, device, obj):
        self.device = device
        self.object = obj

        self.metadata = None
        self.fragments = None

    def open(self, modernize=True, current_time=None):
        if self.object.state == STATE.MISSING:
            raise DiskFileNotExist()

        try:
            metadata = self.device.read_metadata(self.object)
        except (ValueError, KeyError) as err:
            raise DiskFileQuarantined("%s: unreadable metadata: %s" % (self.object.name, err))

        if self.object.deleted:
            raise DiskFileDeleted(metadata["data"])

        self.metadata = metadata
        return self

    @when_open
    def __enter__(self):
        return self

    def __exit__(self, *args):
        pass

    @when_open
    def get_metadata(self):
        return self.metadata["merged"]

    @when_open
    def get_datafile_metadata(self):
        return self.metadata["data"]

    @when_open
    def get_metafile_metadata(self):
        return self.metadata["meta"]

    @property
    @when_open
    def timestamp(self):
        return self.metadata["meta_ts"]

    @property
    @when_open
    def data_timestamp(self):
        return self.metadata["data_ts"]

    durable_timestamp = data_timestamp

    @property
    @when_open
    def content_type_timestamp(self):
        return self.metadata["type_ts"]

    @property
    @when_open
    def content_type(self):
        return self.metadata["merged"].get('Content-Type')

    def read_metadata(self, current_time=None):
        with self.open(current_time=current_time):
            return self.get_metadata()

    def write_metadata(self, metadata):
        with self.open():
            self.device.write_metadata(self.object, metadata)

    def delete(self, timestamp):
        stamp = Timestamp(timestamp)
        self.device.delete(self.object, stamp.raw, {'X-Timestamp': stamp.internal})

    def reader(self, keep_cache=False, cooperative_period=0, etag_validate_frac=1):
        return BluestoreDiskFileReader(self.device, self.object)

    def writer(self, size=None):
        return BluestoreDiskFileWriter(self.device, self.device.create(self.object))

    @contextmanager
    def create(self, size=None):
        writer = self.writer(size)
        try:
            yield writer.open()
        finally:
            writer.close()
