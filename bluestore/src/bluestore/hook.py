import sys, importlib.abc, importlib.machinery

# Swift validates policy types while swift.common.storage_policy is still importing, so our registration has to run inside that import.
# This installs a finder that lets each target module load, then registers against it.
# see DESIGN.md#policy

def patch_policy(loader, module):
    try:
        loader.exec_module(module)
    except Exception as e:
        # The failure we expect is the configuration naming a policy type nobody has registered.
        # _POLICIES only exists once policy parsing has begun,
        # so its presence tells us we caught that failure and not an earlier, unrelated one.
        # see DESIGN.md#policy
        if hasattr(module, '_POLICIES'):
            # Stand in with an empty list so the import can finish.
            # bluestore.policy then registers the type and asks Swift to read the configuration again.
            # see DESIGN.md#policy
            module.POLICIES = module.StoragePolicySingleton()
        else:
            raise e

    import bluestore.policy

def patch_controller(loader, module):
    loader.exec_module(module)
    import bluestore.controller

class BluestorePatchLoader(importlib.abc.Loader):
    def __init__(self, loader, patch):
        self._loader = loader
        self._patch = patch

    def create_module(self, spec):
        return None

    def exec_module(self, module):
        self._patch(self._loader, module)

class BluestorePatchFinder(importlib.abc.MetaPathFinder):
    targets = {
        "swift.proxy.controllers.obj": patch_controller,
        "swift.common.storage_policy": patch_policy
    }

    def find_spec(self, fullname, path, target=None):
        if fullname not in self.targets:
            return None

        real_spec = importlib.machinery.PathFinder.find_spec(fullname, path)
        if real_spec is None:
            return None

        original_loader = real_spec.loader
        real_spec.loader = BluestorePatchLoader(original_loader, self.targets[fullname])
        return real_spec

# Front of the import machinery, so we intercept the target modules before the ordinary finder resolves them.
# see DESIGN.md#policy
sys.meta_path.insert(0, BluestorePatchFinder())
