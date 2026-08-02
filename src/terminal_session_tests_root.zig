//! Test root for the terminal-session store tests, which only have
//! anything to assert in a build that WIRES the emulator behind
//! `<terminal pty={key}>`. This package pins no emulator (apps that want
//! live sessions pin it themselves and ask with
//! `addAppArtifacts(.{ .terminal_sessions = true })`), so under this
//! repository's own `zig build test` every case skips; an app build that
//! opts in points a test artifact at this file and runs them for real.
//! It lives beside `root.zig` because a test root sets the module path,
//! and the runtime's files import across `src/`.
//!
//! See `examples/workbench/build.zig` for the consumer-side wiring.

test {
    _ = @import("runtime/terminal_session_tests.zig");
}
