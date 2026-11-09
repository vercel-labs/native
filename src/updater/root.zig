pub const feed = @import("feed.zig");
pub const c_api = @import("c_api.zig");

pub const Envelope = feed.Envelope;
pub const Release = feed.Release;
pub const VerifiedRelease = feed.VerifiedRelease;
pub const verifyEnvelope = feed.verifyEnvelope;
pub const releaseApplies = feed.releaseApplies;
pub const versionOrder = feed.versionOrder;
pub const archiveHashMatches = feed.archiveHashMatches;
