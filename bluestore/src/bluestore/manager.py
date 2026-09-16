from pathlib import Path

from swift.common.exceptions import DiskFileDeviceUnavailable
from swift.common.storage_policy import get_policy_string

from bluestore.diskfile import BluestoreDiskFile
from bluestore.policy import BluestorePolicy
from bluestore._raw import Backend


# The DiskFileManager interface this implements is covered by the object-server presentation.
# see ARCHITECTURE.md#interface
class BluestoreDiskFileManager:
    @classmethod
    def check_policy(cls, policy):
        if policy.policy_type != BluestorePolicy.policy_type:
            raise ValueError("Invalid policy_type: %s" % policy.policy_type)

    def __init__(self, conf, logger):
        self.chunk_size = int(conf.get('disk_chunk_size', 2 ** 20))
        self.devices = Path(conf.get('devices', '/srv/node'))

        self.capacity = int(conf.get('bluestore_capacity', 100 * (2 ** 30)))
        if conf.get('bluestore_capacity') is None:
            logger.warning("bluestore_capacity is not set")

        self.backends = {}

    # One store per device and policy, opened when a diskfile for it is first
    # wanted and held for as long as the manager lives.
    # see ARCHITECTURE.md#binding
    def get_backend(self, device, policy):
        device_path = self.devices / device
        if not device_path.is_dir():
            raise DiskFileDeviceUnavailable()

        path = str(device_path / get_policy_string("bluestore", policy))
        if path in self.backends:
            return self.backends[path]

        back = Backend(path, self.capacity)
        back.clean()

        self.backends[path] = back
        return back


    def get_diskfile(self, device, partition, account, container, obj, policy, **kwargs):
        backend = self.get_backend(device, policy)
        name = '/'.join((account, container, obj))

        return BluestoreDiskFile(backend, backend.find(name), self.chunk_size)

    def pickle_async_update(self, *args, **kwargs):
        pass
