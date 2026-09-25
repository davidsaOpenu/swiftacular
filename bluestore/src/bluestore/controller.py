# Registers Swift's stock replicated proxy controller for our policy type. The
# proxy refuses to route for a type that has none, and stock behaviour is what
# we want, so this is registration and nothing else.
# see ARCHITECTURE.md#policy

from swift.proxy.controllers.obj import ObjectControllerRouter, ReplicatedObjectController

@ObjectControllerRouter.register('bluestore')
class BluestoreObjectController(ReplicatedObjectController):
    pass
