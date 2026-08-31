from swift.common.storage_policy import BaseStoragePolicy, reload_storage_policies

# The string used as policy_type in swift.conf. Swift refuses to start if the configuration names a type nobody registered.
# see DESIGN.md#policy
@BaseStoragePolicy.register('bluestore')
class BluestorePolicy(BaseStoragePolicy):
    def __init__(self, idx, name='', is_default=False,
            is_deprecated=False, object_ring=None, aliases='',
            # Points Swift at our manager. Must match the entry point name in pyproject.toml or startup fails with a resolution error.
            # see DESIGN.md#interface
            diskfile_module='egg:bluestore#manager'):
        super().__init__(idx, name=name, is_default=is_default,
            is_deprecated=is_deprecated, object_ring=object_ring,
            aliases=aliases, diskfile_module=diskfile_module)

    @property
    def quorum(self):
        # Standard replication cannot be done with bluestore so we can only have one replica.
        # A single copy means a quorum of one, which is an honest statement about durability.
        # see DESIGN.md#policy
        return 1

try:
    # Re-read the configuration now that the type is registered. Guarded because this module is also imported where there is no configuration to read.
    # see DESIGN.md#policy
	reload_storage_policies()
except Exception:
	pass
