# Scenes and transitions

Use `SceneHost(RootScene)` to run a scene stack with `bairava.run`. A scene owns its state and
resources; the navigator is borrowed only during `update`.

A scene supplies:

- `init(ctx) !Self` to construct it.
- `update(self, ctx, nav)` to update and request a transition.
- `draw(self, dc)` to submit frame drawing.
- `deinit(self)` or the context-aware teardown hook when resource release needs the context.

`switchTo`, `push`, and `pop` are applied after the current scene's update returns. A newly requested
scene is not updated in the middle of the caller's update. If initialization of a transition fails,
the open scenes remain active and the error is logged.

Do not retain `ctx`, `dc`, or `nav` past the callback. A successful scene initialization is paired
with teardown when it is replaced, popped, or the host shuts down. The repository's
[public-API scene sample](https://github.com/ash5me/Bairava-Engine/tree/main/sample) is compiled by
the normal build and demonstrates the complete lifecycle.
