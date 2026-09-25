# Swift's DiskFile writer: each chunk goes to the Device as it arrives, and
# put() hands the name over once the body is in.

from swift.common.utils import Timestamp, md5


class BluestoreDiskFileWriter:
    def __init__(self, device, obj):
        self.device = device
        self.object = obj

        self.etag = md5(usedforsecurity=False)
        self.size = 0

    def open(self):
        return self

    def close(self):
        self.object = None

    def write(self, chunk):
        self.device.write(self.object, chunk)

        self.size += len(chunk)
        self.etag.update(chunk)

    def chunks_finished(self):
        return self.size, self.etag.hexdigest()

    def put(self, metadata):
        self.device.put(self.object, Timestamp(metadata['X-Timestamp']).raw, metadata)

    def commit(self, timestamp):
        pass
