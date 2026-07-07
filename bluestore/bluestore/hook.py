import sys, importlib.abc, importlib.machinery

# This file does two things:
# 1) Ensure our policy type is loaded into swift
# 2) Change the behaviour of swift.common.storage_policy so
#    Instead of crashing on unknown policy types the policy
#    list isn't set. This gives us the opportunity to register
#    ourselves and reload the list

def patch_policy(loader, module):
    try:
        loader.exec_module(module)
    except Exception as e:
        # We want to make sure we only swallow errors
        # produced by policy loading luckily _POLICIES
        # is set right before loading
        if hasattr(module, '_POLICIES'):
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

sys.meta_path.insert(0, BluestorePatchFinder())
