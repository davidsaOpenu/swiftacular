# Swift's DiskFile reader: an object's data a chunk at a time, for whole and
# ranged GETs alike.

from swift.common.swob import multi_range_iterator


class BluestoreDiskFileReader:
    def __init__(self, device, obj):
        self.device = device
        self.object = obj

        self.auto_close = True

    def __iter__(self):
        return self.app_iter_range()

    def app_iter_range(self, start=None, stop=None):
        offset = start or 0

        while stop is None or offset < stop:
            chunk, eof = self.device.read(self.object, offset, stop)
            if not chunk:
                break

            offset += len(chunk)
            yield chunk

            if eof:
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
