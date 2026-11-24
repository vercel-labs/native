# three-game

Starfall, a small arcade game drawn with three.js: orbs fall the full height of the window toward a
paddle near the bottom that moves with the arrow keys, A and D, or the pointer. Each catch scores a
point and each miss costs one of three lives. The playfield is sized from the camera and the
window's shape, so the paddle and the orbs stay in view in any window, square ones included.

The scene has a data-texture grid floor that fades into the background through fog, a field of
stars, two point lights that pulse, and a pool of reused orb meshes, each with a soft additive halo
and a speed trail. A catch throws a burst of sparks and a rising "+1" and pops the score; a miss
throws red sparks, flares a red light on the floor and tints the sky red for a moment. Effects draw
from their own random generator, so the orbs fall the same way every round. Everything draws
through `requestAnimationFrame`, and materials use `dithering` so the dark gradients don't band.

## Build

```console
$ node ../../packages/cli/compiler/cli.ts build . -o build/three-game
$ NATIVE_STEPS='frame 0 | click #stage | frame 500' NATIVE_SNAPSHOT=game.png ./build/three-game
```

Arrow Left and Right (or A and D) move the paddle; a click starts a round. The game reuses one
sphere geometry and five materials, so a round draws the same handful of meshes it opened with.
