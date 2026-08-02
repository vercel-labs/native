//! The `terminal_vt` seam's DISABLED half: the framework module imports
//! `terminal_vt` unconditionally, and the build graph wires either this
//! stub or `terminal_vt_ghostty.zig` (which re-exports the real
//! `ghostty-vt` module). With the stub in place `<terminal>` elements
//! render the honest empty surface — no emulator exists — and nothing
//! in the build traverses ghostty's dependency graph, which is the
//! load-bearing property for scaffolded and consumer builds (ghostty's
//! configure step walks lazy dependencies — wuffs, translate_c — whose
//! build scripts fail in consumer package stores, and its full build
//! pulls harfbuzz). Code that needs the emulator gates on `enabled` at
//! comptime and never references `vt` in the disabled branch.

pub const enabled = false;
