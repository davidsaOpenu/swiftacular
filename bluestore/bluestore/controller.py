from swift.proxy.controllers.obj import ObjectControllerRouter, ReplicatedObjectController

# This tells the proxy to treat bluestore object requests
# The same way it treats replication objects. Nothing intresting
# just a technical requirement
@ObjectControllerRouter.register('bluestore')
class BluestoreObjectController(ReplicatedObjectController):
    pass
