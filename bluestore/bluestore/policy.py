from swift.common.storage_policy import BaseStoragePolicy, reload_storage_policies

@BaseStoragePolicy.register('bluestore')
class BluestorePolicy(BaseStoragePolicy):
    def __init__(self, idx, name='', is_default=False, is_deprecated=False,
            object_ring=None, aliases='', diskfile_module='egg:bluestore#manager'):
        super().__init__(idx, name=name, is_default=is_default,
            is_deprecated=is_deprecated, object_ring=object_ring,
            aliases=aliases, diskfile_module=diskfile_module)

    @property
    def quorum(self):
        # Standard replication cannot be done with bluestore so
        # we can only have one replica
        return 1

try:
  reload_storage_policies()
except Exception:
  pass
