# The DiskFileManager Swift finds through the entry point in pyproject.toml. It
# keeps one Device per device and policy, made when a request first wants it
# and held for as long as the manager lives, and hands out DiskFiles on them.
# see ARCHITECTURE.md#interface

from pathlib import Path

from swift.common.exceptions import DiskFileDeviceUnavailable
from swift.common.storage_policy import get_policy_string

from bluestore.device import BluestoreDevice
from bluestore.diskfile import BluestoreDiskFile
from bluestore.policy import BluestorePolicy


class BluestoreDiskFileManager:
    @classmethod
    def check_policy(cls, policy):
        if policy.policy_type != BluestorePolicy.policy_type:
            raise ValueError("Invalid policy_type: %s" % policy.policy_type)

    def __init__(self, conf, logger):
        self.logger = logger
        self.conf = conf

        self.devices_path = Path(conf.get('devices', '/srv/node'))
        self.devices = {dev.name: {} for dev in self.devices_path.iterdir() if dev.is_dir()}

    def get_device(self, device, policy):
        if device not in self.devices:
            raise DiskFileDeviceUnavailable()

        if policy.name in self.devices[device]:
            return self.devices[device][policy.name]

        path = str(self.devices_path / device / get_policy_string("bluestore", policy))
        dev = BluestoreDevice(path, self.conf, self.logger)

        self.devices[device][policy.name] = dev
        return dev

    def get_diskfile(self, device, partition, account, container, obj, policy, **kwargs):
        device = self.get_device(device, policy)
        name = '/'.join((account, container, obj))

        obj = device.open(name)
        return BluestoreDiskFile(device, obj)

    def pickle_async_update(self, *args, **kwargs):
        pass
