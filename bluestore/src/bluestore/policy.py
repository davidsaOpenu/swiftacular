# Registers the 'bluestore' policy type, the name swift.conf gives as a
# policy_type, and points it at our manager. Imported by the startup hook.
# see ARCHITECTURE.md#policy

from swift.common.storage_policy import BaseStoragePolicy, reload_storage_policies

@BaseStoragePolicy.register('bluestore')
class BluestorePolicy(BaseStoragePolicy):
    def __init__(self, idx, name='', is_default=False,
            is_deprecated=False, object_ring=None, aliases='',
            diskfile_module='egg:bluestore#manager'):
        super().__init__(idx, name=name, is_default=is_default,
            is_deprecated=is_deprecated, object_ring=object_ring,
            aliases=aliases, diskfile_module=diskfile_module)

    @property
    def quorum(self):
        # One copy, since replication cannot run here.
        return 1

# Swift gave up on the configuration before the type existed, so it is read
# again now. Outside Swift there is no configuration to read, and the failure
# does not matter.
try:
    reload_storage_policies()
except Exception:
    pass
