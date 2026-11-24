# three-hero

A lit, textured torus knot over a shadowed floor, orbited by a pointer drag, resized with the
window and drawn every frame with `requestAnimationFrame`. three.js 0.187 runs on the Native SDK
runtime through the standard web APIs only: `canvas.getContext("webgl2")`, typed-array textures,
pointer events, window resize and `requestAnimationFrame`.

The scene uses `MeshStandardMaterial` with a 512² procedural `DataTexture`, a directional key
light with a shadow map, two point lights, and a small in-app orbit control. The pointer drag
turns the camera around the knot; the wheel changes the distance.

## Build

```console
$ node ../../packages/cli/compiler/cli.ts build . -o build/three-hero
$ NATIVE_STEPS='frame 0 | frame 500' NATIVE_SNAPSHOT=hero.png ./build/three-hero
```

The build reads three.js from the app's `node_modules` the way any package is vendored: the
example compiles three.js 0.187 as published, with no patched files.

## Notes

`PCFSoftShadowMap` was removed in three 0.187, so the scene uses `PCFShadowMap`.

The standard `OrbitControls` addon does not compile yet: its `MOUSE`/`TOUCH` re-export bindings
read as undefined and its chained method calls are refused, so the app carries a small local
orbit control instead. Swap it back for the addon once those compiler gaps close.
