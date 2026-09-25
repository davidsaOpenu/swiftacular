# Swift's metadata rules, kept the way its own backend keeps them: what the
# PUT or DELETE wrote and what the newest POST wrote are stored apart, as the
# blob's "data" and "meta", and merged when read. A POST belongs to the name,
# so it outlives a PUT or DELETE older than itself. Nothing here does I/O.
# see ARCHITECTURE.md#interface
# see swift/obj/diskfile.py _construct_from_data_file

import json

from swift.common.request_helpers import is_sys_meta
from swift.common.utils import Timestamp
from swift.common.utils.timestamp import PRECISION
from swift.obj.diskfile import DATAFILE_SYSTEM_META, RESERVED_DATAFILE_META


def ctype_timestamp(metadata):
    return Timestamp(metadata.get('Content-Type-Timestamp', 0))


# The PUT's metadata overlaid with the newest POST's, except for what a POST
# can never change, and the content type unless the POST's is newer.
def merge(data, meta):
    merged = dict(meta)
    merged.update((key, value) for key, value in data.items()
                  if key.lower() in RESERVED_DATAFILE_META | DATAFILE_SYSTEM_META
                  or is_sys_meta('object', key))

    if 'Content-Type' in data and Timestamp(data['X-Timestamp']) > ctype_timestamp(meta):
        merged['Content-Type'] = data['Content-Type']
        merged.pop('Content-Type-Timestamp', None)

    return merged


def time_of(data, key=None):
    if key is not None:
        data = data.get(key, {})

    ts = data.get('X-Timestamp')
    return Timestamp(ts) if ts else None


class MetadataModel:
    @classmethod
    def get(cls, blob):
        sections = json.loads(blob)
        data, meta = sections['data'], sections.get('meta')
        merged = dict(data) if meta is None else merge(data, meta)

        return {
            'data': data,
            'meta': meta,
            'merged': merged,
            'meta_ts': time_of(merged),
            'data_ts': time_of(data),
            'type_ts': Timestamp(merged.get('Content-Type-Timestamp', data['X-Timestamp'])),
        }

    @classmethod
    def put(cls, prev, data):
        sections = {'data': data}

        if prev is not None and prev['meta'] is not None and time_of(prev, 'meta') > time_of(data):
            sections['meta'] = prev['meta']

        return json.dumps(sections).encode()

    @classmethod
    def delete(cls, prev, timestamp, meta=None):
        if meta is None:
            meta = {'X-Timestamp': Timestamp(timestamp * PRECISION).internal}

        return cls.put(prev, meta)

    @classmethod
    def post(cls, prev, post):
        if prev is None or time_of(post) <= prev['data_ts']:
            return None

        meta = prev['meta']
        if meta is None or time_of(post) > time_of(meta):
            newer, older = post, meta or {}
        else:
            newer, older = meta, post

        merged = dict(newer)
        if ctype_timestamp(older) > ctype_timestamp(newer):
            merged['Content-Type'] = older['Content-Type']
            merged['Content-Type-Timestamp'] = older['Content-Type-Timestamp']

        if merged == meta:
            return None

        return json.dumps({'data': prev['data'], 'meta': merged}).encode()
