//! Pure, testable pieces of the guest-mac CLI: verb/flag parsing, DHCP
//! lease matching (how `guest-mac ip` finds the guest without any agent
//! inside it — macOS's NAT DHCP server records every lease in
//! /var/db/dhcpd_leases), and state-file parsing.

const std = @import("std");

pub const Verb = enum {
    app,
    fetch,
    install,
    start,
    stop,
    status,
    ip,
    help,
};

pub const default_cpus: u32 = 4;
pub const default_memory_gb: u64 = 8;
pub const default_disk_gb: u64 = 90;
pub const default_share_tag = "repo";

pub const Command = struct {
    verb: Verb = .app,
    ipsw: ?[]const u8 = null,
    share: ?[]const u8 = null,
    tag: []const u8 = default_share_tag,
    cpus: u32 = default_cpus,
    memory_gb: u64 = default_memory_gb,
    disk_gb: u64 = default_disk_gb,
    force: bool = false,
    wait_seconds: u32 = 0,
};

pub const ParseError = error{
    UnknownVerb,
    UnknownFlag,
    MissingFlagValue,
    InvalidFlagValue,
};

pub fn parse(args: []const []const u8) ParseError!Command {
    var command: Command = .{};
    if (args.len == 0) return command;

    const verb_name = args[0];
    command.verb = std.meta.stringToEnum(Verb, verb_name) orelse {
        if (std.mem.eql(u8, verb_name, "--help") or std.mem.eql(u8, verb_name, "-h")) return .{ .verb = .help };
        return error.UnknownVerb;
    };

    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--force")) {
            command.force = true;
        } else if (std.mem.eql(u8, arg, "--headless")) {
            // `start` is always headless from the CLI; the flag is accepted
            // so agent scripts can be explicit about intent.
        } else if (std.mem.eql(u8, arg, "--ipsw")) {
            command.ipsw = try flagValue(args, &index);
        } else if (std.mem.eql(u8, arg, "--share")) {
            command.share = try flagValue(args, &index);
        } else if (std.mem.eql(u8, arg, "--tag")) {
            command.tag = try flagValue(args, &index);
        } else if (std.mem.eql(u8, arg, "--cpus")) {
            command.cpus = try flagInt(u32, args, &index);
        } else if (std.mem.eql(u8, arg, "--memory-gb")) {
            command.memory_gb = try flagInt(u64, args, &index);
        } else if (std.mem.eql(u8, arg, "--disk-gb")) {
            command.disk_gb = try flagInt(u64, args, &index);
        } else if (std.mem.eql(u8, arg, "--wait")) {
            command.wait_seconds = try flagInt(u32, args, &index);
        } else {
            return error.UnknownFlag;
        }
    }
    return command;
}

fn flagValue(args: []const []const u8, index: *usize) ParseError![]const u8 {
    if (index.* + 1 >= args.len) return error.MissingFlagValue;
    index.* += 1;
    return args[index.*];
}

fn flagInt(comptime T: type, args: []const []const u8, index: *usize) ParseError!T {
    const value = try flagValue(args, index);
    return std.fmt.parseInt(T, value, 10) catch error.InvalidFlagValue;
}

pub const usage =
    \\guest-mac — an in-repo macOS guest VM for live-GUI agent work.
    \\
    \\  guest-mac                run the windowed host app (guest display + controls)
    \\  guest-mac fetch          resolve and download the latest supported macOS IPSW
    \\  guest-mac install        create the VM bundle and restore macOS onto it
    \\                           [--ipsw PATH] [--cpus N] [--memory-gb N] [--disk-gb N]
    \\  guest-mac start          boot the guest headless (stays in the foreground)
    \\                           [--share DIR] [--tag NAME] [--cpus N] [--memory-gb N]
    \\  guest-mac stop           gracefully stop a running guest [--force]
    \\  guest-mac status         report bundle/run state
    \\  guest-mac ip             print the guest's DHCP address [--wait SECONDS]
    \\
    \\See tools/guest-mac/agents.md for the agent workflow and
    \\tools/guest-mac/README.md for provisioning.
    \\
;

// ---- DHCP lease parsing -----------------------------------------------------

/// Find the IPv4 address leased to `mac` in /var/db/dhcpd_leases content.
/// The leases file strips leading zeros per octet ("2" for "02") and
/// prefixes a hardware-type byte ("1,aa:bb:..."), so matching normalizes
/// both sides octet-by-octet instead of comparing strings.
pub fn leaseIpForMac(leases: []const u8, mac: []const u8) ?[]const u8 {
    const wanted = parseMac(mac) orelse return null;
    var current_ip: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, leases, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (std.mem.startsWith(u8, line, "{")) current_ip = null;
        if (std.mem.startsWith(u8, line, "ip_address=")) current_ip = line["ip_address=".len..];
        if (std.mem.startsWith(u8, line, "hw_address=")) {
            var value = line["hw_address=".len..];
            // Skip the "hardware type," prefix when present.
            if (std.mem.indexOfScalar(u8, value, ',')) |comma| value = value[comma + 1 ..];
            const found = parseMac(value) orelse continue;
            if (std.mem.eql(u8, &found, &wanted)) {
                if (current_ip) |ip| return ip;
            }
        }
    }
    return null;
}

fn parseMac(text: []const u8) ?[6]u8 {
    var octets: [6]u8 = undefined;
    var parts = std.mem.splitScalar(u8, std.mem.trim(u8, text, " \t"), ':');
    var count: usize = 0;
    while (parts.next()) |part| {
        if (count >= 6) return null;
        octets[count] = std.fmt.parseInt(u8, part, 16) catch return null;
        count += 1;
    }
    if (count != 6) return null;
    return octets;
}

// ---- state-file parsing -----------------------------------------------------

pub const StateFile = struct {
    state: []const u8 = "",
    pid: i32 = 0,
};

/// Minimal parse of the engine's state.json ({"state":"running","pid":N}).
/// Flat, engine-authored JSON — field scanning keeps this dependency-free
/// for the CLI verbs that only need two values.
pub fn parseStateFile(content: []const u8) StateFile {
    var result: StateFile = .{};
    if (jsonStringValue(content, "\"state\"")) |value| result.state = value;
    if (jsonNumberValue(content, "\"pid\"")) |value| result.pid = value;
    return result;
}

/// The guest's persistent MAC address from the engine's config.json — the
/// key `guest-mac ip` matches against DHCP leases without touching the
/// Virtualization engine.
pub fn macFromConfig(content: []const u8) ?[]const u8 {
    return jsonStringValue(content, "\"mac_address\"");
}

fn jsonStringValue(content: []const u8, key: []const u8) ?[]const u8 {
    const key_index = std.mem.indexOf(u8, content, key) orelse return null;
    const colon = std.mem.indexOfScalarPos(u8, content, key_index + key.len, ':') orelse return null;
    const open = std.mem.indexOfScalarPos(u8, content, colon, '"') orelse return null;
    const close = std.mem.indexOfScalarPos(u8, content, open + 1, '"') orelse return null;
    return content[open + 1 .. close];
}

fn jsonNumberValue(content: []const u8, key: []const u8) ?i32 {
    const key_index = std.mem.indexOf(u8, content, key) orelse return null;
    const colon = std.mem.indexOfScalarPos(u8, content, key_index + key.len, ':') orelse return null;
    var start = colon + 1;
    while (start < content.len and (content[start] == ' ' or content[start] == '\t')) start += 1;
    var end = start;
    while (end < content.len and (std.ascii.isDigit(content[end]) or content[end] == '-')) end += 1;
    if (end == start) return null;
    return std.fmt.parseInt(i32, content[start..end], 10) catch null;
}

// ---- tests ------------------------------------------------------------------

test "parse defaults to the app verb" {
    const command = try parse(&.{});
    try std.testing.expectEqual(Verb.app, command.verb);
    try std.testing.expectEqual(default_cpus, command.cpus);
    try std.testing.expectEqual(default_memory_gb, command.memory_gb);
    try std.testing.expectEqual(default_disk_gb, command.disk_gb);
    try std.testing.expectEqualStrings(default_share_tag, command.tag);
}

test "parse reads verbs and flags" {
    const install = try parse(&.{ "install", "--ipsw", "/tmp/restore.ipsw", "--disk-gb", "120" });
    try std.testing.expectEqual(Verb.install, install.verb);
    try std.testing.expectEqualStrings("/tmp/restore.ipsw", install.ipsw.?);
    try std.testing.expectEqual(@as(u64, 120), install.disk_gb);

    const start = try parse(&.{ "start", "--headless", "--share", "/repo", "--tag", "src", "--cpus", "6" });
    try std.testing.expectEqual(Verb.start, start.verb);
    try std.testing.expectEqualStrings("/repo", start.share.?);
    try std.testing.expectEqualStrings("src", start.tag);
    try std.testing.expectEqual(@as(u32, 6), start.cpus);

    const stop = try parse(&.{ "stop", "--force" });
    try std.testing.expect(stop.force);

    const ip = try parse(&.{ "ip", "--wait", "90" });
    try std.testing.expectEqual(@as(u32, 90), ip.wait_seconds);
}

test "parse rejects unknown verbs and flags loudly" {
    try std.testing.expectError(error.UnknownVerb, parse(&.{"boot"}));
    try std.testing.expectError(error.UnknownFlag, parse(&.{ "start", "--wat" }));
    try std.testing.expectError(error.MissingFlagValue, parse(&.{ "install", "--ipsw" }));
    try std.testing.expectError(error.InvalidFlagValue, parse(&.{ "start", "--cpus", "four" }));
}

test "lease parsing matches zero-stripped octets and lease boundaries" {
    // Real /var/db/dhcpd_leases entries are tab-indented; Zig multiline
    // literals cannot hold raw tabs, so the fixture embeds them explicitly.
    const leases = "{\n" ++
        "\tname=other\n" ++
        "\tip_address=192.168.64.4\n" ++
        "\thw_address=1,aa:bb:cc:dd:ee:ff\n" ++
        "\tidentifier=1,aa:bb:cc:dd:ee:ff\n" ++
        "\tlease=0x69123456\n" ++
        "}\n" ++
        "{\n" ++
        "\tname=guest\n" ++
        "\tip_address=192.168.64.7\n" ++
        "\thw_address=1,ee:d8:26:2:d6:7\n" ++
        "\tidentifier=1,ee:d8:26:2:d6:7\n" ++
        "\tlease=0x69123457\n" ++
        "}\n";
    try std.testing.expectEqualStrings("192.168.64.7", leaseIpForMac(leases, "ee:d8:26:02:d6:07").?);
    try std.testing.expectEqualStrings("192.168.64.4", leaseIpForMac(leases, "AA:BB:CC:DD:EE:FF").?);
    try std.testing.expect(leaseIpForMac(leases, "00:11:22:33:44:55") == null);
    try std.testing.expect(leaseIpForMac(leases, "not-a-mac") == null);
}

test "config parsing reads the persistent MAC address" {
    try std.testing.expectEqualStrings("ee:d8:26:02:d6:07", macFromConfig("{\n  \"cpus\" : 4,\n  \"mac_address\" : \"ee:d8:26:02:d6:07\"\n}").?);
    try std.testing.expect(macFromConfig("{}") == null);
}

test "state file parsing reads state and pid" {
    const parsed = parseStateFile("{\"pid\":4242,\"state\":\"running\"}");
    try std.testing.expectEqualStrings("running", parsed.state);
    try std.testing.expectEqual(@as(i32, 4242), parsed.pid);

    const empty = parseStateFile("{}");
    try std.testing.expectEqualStrings("", empty.state);
    try std.testing.expectEqual(@as(i32, 0), empty.pid);
}
