const std = @import("std");

const skill_dirs = [_][]const u8{ "skills", "skill-data" };

const SkillInfo = struct {
    name: []const u8,
    description: []const u8,
    dir: []const u8,
    hidden: bool,
};

pub fn run(allocator: std.mem.Allocator, io: std.Io, env_map: *std.process.Environ.Map, args: []const []const u8) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    if (args.len == 0 or isHelp(args[0])) return usage(stdout);

    const root = try findPackageRoot(allocator, io, env_map) orelse {
        std.debug.print("native skills: could not find skills/ or skill-data/ near the native-sdk executable\n", .{});
        std.process.exit(1);
    };
    defer allocator.free(root);

    var skills = try discoverSkills(allocator, io, root);
    defer skills.deinit(allocator);

    const command = args[0];
    if (std.mem.eql(u8, command, "list")) {
        const visible_count = try printSkillList(stdout, skills.items);
        if (visible_count == 0) try stdout.print("No skills found.\n", .{});
    } else if (std.mem.eql(u8, command, "get")) {
        if (args.len < 2) return fail("No skill name provided. Usage: native skills get <name>");
        const include_supplementary = hasFlag(args[2..], "--full");
        if (std.mem.eql(u8, args[1], "--all")) {
            try printAllSkills(allocator, io, stdout, skills.items, include_supplementary);
            return;
        }
        const skill = findSkill(skills.items, args[1]) orelse {
            std.debug.print("Unknown skill: {s}\n", .{args[1]});
            std.process.exit(1);
        };
        try printSkill(allocator, io, stdout, skill, include_supplementary);
    } else {
        return usage(stdout);
    }
}

fn usage(stdout: *std.Io.Writer) !void {
    try stdout.print(
        \\usage: native skills <command>
        \\
        \\commands:
        \\  skills list
        \\  skills get <name> [--full]
        \\  skills get --all [--full]
        \\
        \\examples:
        \\  native skills list
        \\  native skills get core
        \\  native skills get core --full
        \\  native skills get automation
        \\
    , .{});
}

fn fail(message: []const u8) noreturn {
    std.debug.print("{s}\n", .{message});
    std.process.exit(1);
}

fn isHelp(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "help");
}

fn hasFlag(args: []const []const u8, name: []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, name)) return true;
    }
    return false;
}

fn findPackageRoot(allocator: std.mem.Allocator, io: std.Io, env_map: *std.process.Environ.Map) !?[]const u8 {
    if (try packageRootFromEnvironment(allocator, io, env_map)) |root| return root;

    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const executable_len = std.process.executablePath(io, &buffer) catch return null;
    return packageRootFromExecutablePath(allocator, io, buffer[0..executable_len]);
}

/// Resolve the package that owns the skill payload. The explicit skills
/// override wins, followed by the framework path supplied by the npm wrapper.
/// Invalid environment candidates fall through to the executable layout.
fn findPackageRootFromExecutable(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *std.process.Environ.Map,
    executable_path: []const u8,
) !?[]const u8 {
    if (try packageRootFromEnvironment(allocator, io, env_map)) |root| return root;
    return packageRootFromExecutablePath(allocator, io, executable_path);
}

fn packageRootFromEnvironment(allocator: std.mem.Allocator, io: std.Io, env_map: *std.process.Environ.Map) !?[]const u8 {
    const environment_candidates = [_][]const u8{
        "NATIVE_SDK_SKILLS_ROOT",
        "NATIVE_SDK_PATH",
    };
    for (environment_candidates) |name| {
        if (env_map.get(name)) |root| {
            if (root.len > 0 and try hasSkillDirs(allocator, io, root)) {
                return try allocator.dupe(u8, root);
            }
        }
    }
    return null;
}

/// Find payloads bundled with the executable or owned by the sibling main npm
/// package. This mirrors buildgraph.frameworkRootFromExecutable so direct
/// invocation works for flat bundles, checkouts, hoisted installs, and nested
/// optional dependencies without copying the payload into platform packages.
fn packageRootFromExecutablePath(allocator: std.mem.Allocator, io: std.Io, executable_path: []const u8) !?[]const u8 {
    var dir = std.fs.path.dirname(executable_path) orelse return null;
    if (try hasSkillDirs(allocator, io, dir)) return try allocator.dupe(u8, dir);
    var level: usize = 0;

    while (level < 4) : (level += 1) {
        const parent = std.fs.path.dirname(dir) orelse return null;
        if (try hasSkillDirs(allocator, io, parent)) return try allocator.dupe(u8, parent);

        const sibling = try std.fs.path.join(allocator, &.{ parent, "cli" });
        if (try hasSkillDirs(allocator, io, sibling)) return sibling;
        allocator.free(sibling);
        dir = parent;
    }

    return null;
}

fn hasSkillDirs(allocator: std.mem.Allocator, io: std.Io, root: []const u8) !bool {
    const skills_path = try std.fs.path.join(allocator, &.{ root, "skills" });
    defer allocator.free(skills_path);
    if (dirExists(io, skills_path)) return true;

    const data_path = try std.fs.path.join(allocator, &.{ root, "skill-data" });
    defer allocator.free(data_path);
    return dirExists(io, data_path);
}

fn dirExists(io: std.Io, path: []const u8) bool {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    dir.close(io);
    return true;
}

fn discoverSkills(allocator: std.mem.Allocator, io: std.Io, root: []const u8) !std.ArrayList(SkillInfo) {
    var skills: std.ArrayList(SkillInfo) = .empty;
    errdefer skills.deinit(allocator);

    for (skill_dirs) |dir_name| {
        const base = try std.fs.path.join(allocator, &.{ root, dir_name });
        defer allocator.free(base);

        var dir = std.Io.Dir.cwd().openDir(io, base, .{ .iterate = true }) catch continue;
        defer dir.close(io);

        var walker = try dir.walk(allocator);
        defer walker.deinit();

        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.eql(u8, std.fs.path.basename(entry.path), "SKILL.md")) continue;

            const skill_dir_rel = std.fs.path.dirname(entry.path) orelse "";
            const skill_dir = try std.fs.path.join(allocator, &.{ base, skill_dir_rel });
            errdefer allocator.free(skill_dir);

            const skill_path = try std.fs.path.join(allocator, &.{ base, entry.path });
            defer allocator.free(skill_path);

            const content = try std.Io.Dir.cwd().readFileAlloc(io, skill_path, allocator, .limited(1024 * 1024));
            defer allocator.free(content);

            const parsed = parseFrontmatter(content) orelse continue;
            try skills.append(allocator, .{
                .name = try allocator.dupe(u8, parsed.name),
                .description = try allocator.dupe(u8, parsed.description),
                .dir = skill_dir,
                .hidden = parsed.hidden,
            });
        }
    }

    std.mem.sort(SkillInfo, skills.items, {}, lessSkill);
    return skills;
}

fn lessSkill(_: void, a: SkillInfo, b: SkillInfo) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

const ParsedFrontmatter = struct {
    name: []const u8,
    description: []const u8,
    hidden: bool,
};

fn parseFrontmatter(content: []const u8) ?ParsedFrontmatter {
    if (!std.mem.startsWith(u8, content, "---\n")) return null;
    const frontmatter_end = std.mem.indexOf(u8, content[4..], "\n---") orelse return null;
    const frontmatter = content[4 .. 4 + frontmatter_end];

    var name: ?[]const u8 = null;
    var description: []const u8 = "";
    var hidden = false;

    var lines = std.mem.splitScalar(u8, frontmatter, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "name:")) {
            name = std.mem.trim(u8, line["name:".len..], " \t");
        } else if (std.mem.startsWith(u8, line, "description:")) {
            description = std.mem.trim(u8, line["description:".len..], " \t");
        } else if (std.mem.startsWith(u8, line, "hidden:")) {
            const value = std.mem.trim(u8, line["hidden:".len..], " \t");
            hidden = std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "yes");
        }
    }

    return .{ .name = name orelse return null, .description = description, .hidden = hidden };
}

fn printSkillList(stdout: *std.Io.Writer, skills: []const SkillInfo) !usize {
    var visible_count: usize = 0;
    for (skills) |skill| {
        if (skill.hidden) continue;
        visible_count += 1;
        if (skill.description.len > 0) {
            try stdout.print("{s}\t{s}\n", .{ skill.name, skill.description });
        } else {
            try stdout.print("{s}\n", .{skill.name});
        }
    }
    return visible_count;
}

fn findSkill(skills: []const SkillInfo, name: []const u8) ?SkillInfo {
    for (skills) |skill| {
        if (std.mem.eql(u8, skill.name, name)) return skill;
    }
    return null;
}

fn printAllSkills(allocator: std.mem.Allocator, io: std.Io, stdout: *std.Io.Writer, skills: []const SkillInfo, include_supplementary: bool) !void {
    var first = true;
    for (skills) |skill| {
        if (skill.hidden) continue;
        if (!first) try stdout.print("\n---\n\n", .{});
        first = false;
        try printSkill(allocator, io, stdout, skill, include_supplementary);
    }
}

fn printSkill(allocator: std.mem.Allocator, io: std.Io, stdout: *std.Io.Writer, skill: SkillInfo, include_supplementary: bool) !void {
    const skill_path = try std.fs.path.join(allocator, &.{ skill.dir, "SKILL.md" });
    defer allocator.free(skill_path);
    const content = try std.Io.Dir.cwd().readFileAlloc(io, skill_path, allocator, .limited(1024 * 1024));
    defer allocator.free(content);
    try stdout.writeAll(content);
    if (include_supplementary) try printSupplementaryFiles(allocator, io, stdout, skill.dir);
}

fn printSupplementaryFiles(allocator: std.mem.Allocator, io: std.Io, stdout: *std.Io.Writer, skill_dir: []const u8) !void {
    const subdirs = [_][]const u8{ "references", "templates" };
    for (subdirs) |subdir| {
        const root = try std.fs.path.join(allocator, &.{ skill_dir, subdir });
        defer allocator.free(root);
        var dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var walker = try dir.walk(allocator);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            const path = try std.fs.path.join(allocator, &.{ root, entry.path });
            defer allocator.free(path);
            const content = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024));
            defer allocator.free(content);
            try stdout.print("\n\n---\n# {s}/{s}\n\n{s}", .{ subdir, entry.path, content });
        }
    }
}

fn testTempRootAlloc(tmp: *std.testing.TmpDir) ![]u8 {
    const allocator = std.testing.allocator;
    const relative = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer allocator.free(relative);
    const real = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, relative, allocator);
    defer allocator.free(real);
    return allocator.dupe(u8, real);
}

fn testCreateDir(tmp: *std.testing.TmpDir, parts: []const []const u8) !void {
    const path = try std.fs.path.join(std.testing.allocator, parts);
    defer std.testing.allocator.free(path);
    try tmp.dir.createDirPath(std.testing.io, path);
}

fn testExpectResolved(expected: []const u8, resolved: ?[]const u8) !void {
    const root = resolved orelse return error.TestUnexpectedResult;
    defer std.testing.allocator.free(root);
    try std.testing.expectEqualStrings(expected, root);
}

test "NATIVE_SDK_SKILLS_ROOT takes precedence over NATIVE_SDK_PATH" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try testCreateDir(&tmp, &.{ "explicit", "skills" });
    try testCreateDir(&tmp, &.{ "framework", "skill-data" });

    const root = try testTempRootAlloc(&tmp);
    defer std.testing.allocator.free(root);
    const explicit = try std.fs.path.join(std.testing.allocator, &.{ root, "explicit" });
    defer std.testing.allocator.free(explicit);
    const framework = try std.fs.path.join(std.testing.allocator, &.{ root, "framework" });
    defer std.testing.allocator.free(framework);
    const executable = try std.fs.path.join(std.testing.allocator, &.{ root, "unrelated", "bin", "native" });
    defer std.testing.allocator.free(executable);

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("NATIVE_SDK_SKILLS_ROOT", explicit);
    try env.put("NATIVE_SDK_PATH", framework);

    try testExpectResolved(explicit, try findPackageRootFromExecutable(std.testing.allocator, std.testing.io, &env, executable));
}

test "invalid explicit skills root falls through to NATIVE_SDK_PATH" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try testCreateDir(&tmp, &.{ "framework", "skill-data" });

    const root = try testTempRootAlloc(&tmp);
    defer std.testing.allocator.free(root);
    const invalid = try std.fs.path.join(std.testing.allocator, &.{ root, "missing" });
    defer std.testing.allocator.free(invalid);
    const framework = try std.fs.path.join(std.testing.allocator, &.{ root, "framework" });
    defer std.testing.allocator.free(framework);
    const executable = try std.fs.path.join(std.testing.allocator, &.{ root, "unrelated", "bin", "native" });
    defer std.testing.allocator.free(executable);

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("NATIVE_SDK_SKILLS_ROOT", invalid);
    try env.put("NATIVE_SDK_PATH", framework);

    try testExpectResolved(framework, try findPackageRootFromExecutable(std.testing.allocator, std.testing.io, &env, executable));
}

test "invalid NATIVE_SDK_PATH falls through to the executable layout" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try testCreateDir(&tmp, &.{ "bundle", "skills" });
    try testCreateDir(&tmp, &.{ "bundle", "bin" });

    const root = try testTempRootAlloc(&tmp);
    defer std.testing.allocator.free(root);
    const invalid = try std.fs.path.join(std.testing.allocator, &.{ root, "framework-without-skills" });
    defer std.testing.allocator.free(invalid);
    const bundle = try std.fs.path.join(std.testing.allocator, &.{ root, "bundle" });
    defer std.testing.allocator.free(bundle);
    const executable = try std.fs.path.join(std.testing.allocator, &.{ bundle, "bin", "native" });
    defer std.testing.allocator.free(executable);

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("NATIVE_SDK_PATH", invalid);

    try testExpectResolved(bundle, try findPackageRootFromExecutable(std.testing.allocator, std.testing.io, &env, executable));
}

test "skill roots accept skills and skill-data directories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try testCreateDir(&tmp, &.{ "skills-only", "skills" });
    try testCreateDir(&tmp, &.{ "data-only", "skill-data" });

    const root = try testTempRootAlloc(&tmp);
    defer std.testing.allocator.free(root);
    const skills_only = try std.fs.path.join(std.testing.allocator, &.{ root, "skills-only" });
    defer std.testing.allocator.free(skills_only);
    const data_only = try std.fs.path.join(std.testing.allocator, &.{ root, "data-only" });
    defer std.testing.allocator.free(data_only);

    try std.testing.expect(try hasSkillDirs(std.testing.allocator, std.testing.io, skills_only));
    try std.testing.expect(try hasSkillDirs(std.testing.allocator, std.testing.io, data_only));
}

test "executable search accepts checkout and flat bundle ancestors" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try testCreateDir(&tmp, &.{ "checkout", "skills" });
    try testCreateDir(&tmp, &.{ "checkout", "zig-out", "bin" });
    try testCreateDir(&tmp, &.{ "bundle", "skill-data" });
    try testCreateDir(&tmp, &.{ "bundle", "bin" });

    const root = try testTempRootAlloc(&tmp);
    defer std.testing.allocator.free(root);
    const checkout = try std.fs.path.join(std.testing.allocator, &.{ root, "checkout" });
    defer std.testing.allocator.free(checkout);
    const checkout_executable = try std.fs.path.join(std.testing.allocator, &.{ checkout, "zig-out", "bin", "native" });
    defer std.testing.allocator.free(checkout_executable);
    const bundle = try std.fs.path.join(std.testing.allocator, &.{ root, "bundle" });
    defer std.testing.allocator.free(bundle);
    const bundle_executable = try std.fs.path.join(std.testing.allocator, &.{ bundle, "bin", "native" });
    defer std.testing.allocator.free(bundle_executable);

    try testExpectResolved(checkout, try packageRootFromExecutablePath(std.testing.allocator, std.testing.io, checkout_executable));
    try testExpectResolved(bundle, try packageRootFromExecutablePath(std.testing.allocator, std.testing.io, bundle_executable));
}

test "executable search finds hoisted sibling main package" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try testCreateDir(&tmp, &.{ "node_modules", "@native-sdk", "cli", "skills" });
    try testCreateDir(&tmp, &.{ "node_modules", "@native-sdk", "cli-linux-x64-gnu", "bin" });

    const root = try testTempRootAlloc(&tmp);
    defer std.testing.allocator.free(root);
    const main_package = try std.fs.path.join(std.testing.allocator, &.{ root, "node_modules", "@native-sdk", "cli" });
    defer std.testing.allocator.free(main_package);
    const executable = try std.fs.path.join(std.testing.allocator, &.{ root, "node_modules", "@native-sdk", "cli-linux-x64-gnu", "bin", "native" });
    defer std.testing.allocator.free(executable);

    try testExpectResolved(main_package, try packageRootFromExecutablePath(std.testing.allocator, std.testing.io, executable));
}

test "executable search reaches outer main package from nested optional dependency" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try testCreateDir(&tmp, &.{ "node_modules", "@native-sdk", "cli", "skill-data" });
    try testCreateDir(&tmp, &.{ "node_modules", "@native-sdk", "cli", "node_modules", "@native-sdk", "cli-linux-x64-gnu", "bin" });

    const root = try testTempRootAlloc(&tmp);
    defer std.testing.allocator.free(root);
    const main_package = try std.fs.path.join(std.testing.allocator, &.{ root, "node_modules", "@native-sdk", "cli" });
    defer std.testing.allocator.free(main_package);
    const executable = try std.fs.path.join(std.testing.allocator, &.{ main_package, "node_modules", "@native-sdk", "cli-linux-x64-gnu", "bin", "native" });
    defer std.testing.allocator.free(executable);

    try testExpectResolved(main_package, try packageRootFromExecutablePath(std.testing.allocator, std.testing.io, executable));
}

test "skill root resolution returns null when no candidate is valid" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try testCreateDir(&tmp, &.{ "empty", "one", "two", "three", "four", "bin" });

    const root = try testTempRootAlloc(&tmp);
    defer std.testing.allocator.free(root);
    const executable = try std.fs.path.join(std.testing.allocator, &.{ root, "empty", "one", "two", "three", "four", "bin", "native" });
    defer std.testing.allocator.free(executable);
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    const resolved = try findPackageRootFromExecutable(std.testing.allocator, std.testing.io, &env, executable);
    try std.testing.expect(resolved == null);
}
