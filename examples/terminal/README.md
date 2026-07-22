# terminal

A recordable terminal: a real shell on a pty, rendered as real text on the canvas, and — the headline — sessions that replay byte-identical offline, with no shell present.

- The pty effect vocabulary (`fx.ptySpawn` / `ptyWrite` / `ptyResize` / `ptyKill`) owns the transport.
- [libghostty-vt](https://github.com/ghostty-org/ghostty) owns terminal state and damage (the `ghostty-vt` Zig module, pinned in `build.zig.zon`).
- The canvas owns the pixels: damaged rows re-render as styled text runs, the ANSI-16 palette derives from the active theme tokens, and 256-color/truecolor pass through exactly.

```sh
zig build run             # run the terminal
zig build test -Dplatform=null
```
