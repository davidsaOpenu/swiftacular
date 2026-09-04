from swift.proxy.controllers.obj import ObjectControllerRouter, ReplicatedObjectController

# The proxy keeps a class per policy type describing how it spreads a request across the cluster,
# and refuses to route for a type that has none.
# Stock replicated behaviour is what we want, so this is registration and nothing else.
# see DESIGN.md#policy
@ObjectControllerRouter.register('bluestore')
class BluestoreObjectController(ReplicatedObjectController):
    pass
