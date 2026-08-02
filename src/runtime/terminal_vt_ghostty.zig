//! The `terminal_vt` seam's ENABLED half: re-exports libghostty-vt
//! (Ghostty's extracted terminal-state core, the `ghostty-vt` Zig
//! module) for the runtime's terminal-session store. Only an APP build
//! wires this wrapper, and only when it asks: pin `ghostty` as a lazy
//! dependency in the app's own `build.zig.zon` and set
//! `addAppArtifacts(.{ .terminal_sessions = true })`. This package pins
//! nothing, because a pin here is materialized into every consumer's
//! package directory even when lazy and unused.
//!
//! Everything else (the framework's own builds, scaffolded apps, the
//! wasm docs preview) gets `terminal_vt_stub.zig` and never traverses
//! ghostty's graph.

pub const enabled = true;
pub const vt = @import("ghostty-vt");
