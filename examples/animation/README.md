# animation

Ember, a launch page of small motions in plain HTML, CSS and TypeScript: a scroll progress bar, a
marquee, floating gradient orbs, sections that reveal as they arrive (IntersectionObserver), counters
that run once (requestAnimationFrame), three parallax layers, a pointer-tilted card and a light/dark
theme cross-fade driven by CSS variables.

## Build

```console
$ node ../../packages/cli/compiler/cli.ts build . -o build/animation
$ NATIVE_STEPS='frame 0 | wheel #hero 700 | frame 400 | print #count-a' NATIVE_SNAPSHOT=animation.png ./build/animation
```
