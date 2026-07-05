//! Session state fingerprinting: the record/replay verification hash.
//!
//! The fingerprint is the Wyhash of the runtime's ACCESSIBILITY snapshot
//! text — every window, view, and widget's semantic state (roles, names,
//! text values, control values, scroll offsets, bounds, focus/hover/
//! pressed flags) — deliberately NOT the full automation snapshot, whose
//! header carries wall-clock uptime, pids, and per-present GPU telemetry
//! that legitimately differ between a live run and its replay. Anything
//! that changes what the a11y tree says the app IS changes the hash;
//! anything that only says how fast the host drew does not.

const std = @import("std");
const automation = @import("../automation/root.zig");

pub fn RuntimeSessionState(comptime Runtime: type) type {
    return struct {
        /// Hash of the current semantic state. A formatting failure
        /// cannot happen with a draining hash writer, but the seam stays
        /// honest: 0 means "no fingerprint", and replay treats a 0-0
        /// comparison as a match of unknowns, never silently as proof.
        pub fn sessionStateFingerprint(self: *Runtime) u64 {
            const input = self.automationSnapshot("session");
            var buffer: [512]u8 = undefined;
            var hashing = std.Io.Writer.Hashing(std.hash.Wyhash).initHasher(std.hash.Wyhash.init(0), &buffer);
            automation.snapshot.writeA11yText(input, &hashing.writer) catch return 0;
            hashing.writer.flush() catch return 0;
            return hashing.hasher.final();
        }
    };
}
