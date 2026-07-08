const std = @import("std");
const types = @import("types.zig");
const validation = @import("validation.zig");

const ValidationError = types.ValidationError;
const max_shortcuts = types.max_shortcuts;
const max_shortcut_id_bytes = types.max_shortcut_id_bytes;
const max_shortcut_key_bytes = types.max_shortcut_key_bytes;
const max_shell_windows = types.max_shell_windows;
const max_shell_views_per_window = types.max_shell_views_per_window;
const max_view_label_bytes = types.max_view_label_bytes;
const max_view_role_bytes = types.max_view_role_bytes;
const max_view_accessibility_label_bytes = types.max_view_accessibility_label_bytes;
const max_command_id_bytes = types.max_command_id_bytes;
const max_commands = types.max_commands;
const max_command_title_bytes = types.max_command_title_bytes;
const max_menus = types.max_menus;
const max_menu_items = types.max_menu_items;
const max_menu_title_bytes = types.max_menu_title_bytes;
const max_menu_item_label_bytes = types.max_menu_item_label_bytes;
const max_menu_key_bytes = types.max_menu_key_bytes;
const max_file_associations = types.max_file_associations;
const max_file_association_extensions = types.max_file_association_extensions;
const max_file_association_mime_types = types.max_file_association_mime_types;
const max_url_schemes = types.max_url_schemes;
const Platform = types.Platform;
const PackageKind = types.PackageKind;
const WebEngine = types.WebEngine;
const CefConfig = types.CefConfig;
const IconPurpose = types.IconPurpose;
const PermissionKind = types.PermissionKind;
const Permission = types.Permission;
const CapabilityKind = types.CapabilityKind;
const Capability = types.Capability;
const AppIdentity = types.AppIdentity;
const Version = types.Version;
const Icon = types.Icon;
const PlatformSettings = types.PlatformSettings;
const BridgeCommand = types.BridgeCommand;
const BridgeConfig = types.BridgeConfig;
const ExternalLinkAction = types.ExternalLinkAction;
const ExternalLinkPolicy = types.ExternalLinkPolicy;
const NavigationPolicy = types.NavigationPolicy;
const SecurityConfig = types.SecurityConfig;
const FrontendDevConfig = types.FrontendDevConfig;
const FrontendConfig = types.FrontendConfig;
const WindowRestorePolicy = types.WindowRestorePolicy;
const Window = types.Window;
const ViewKind = types.ViewKind;
const GpuSurfaceBackend = types.GpuSurfaceBackend;
const GpuSurfacePixelFormat = types.GpuSurfacePixelFormat;
const GpuSurfacePresentMode = types.GpuSurfacePresentMode;
const GpuSurfaceAlphaMode = types.GpuSurfaceAlphaMode;
const GpuSurfaceColorSpace = types.GpuSurfaceColorSpace;
const ShellEdge = types.ShellEdge;
const ShellAxis = types.ShellAxis;
const ShellView = types.ShellView;
const ShellWindow = types.ShellWindow;
const ShellConfig = types.ShellConfig;
const ShortcutModifiers = types.ShortcutModifiers;
const Shortcut = types.Shortcut;
const Command = types.Command;
const Menu = types.Menu;
const MenuItem = types.MenuItem;
const AssociationRole = types.AssociationRole;
const FileAssociation = types.FileAssociation;
const UrlScheme = types.UrlScheme;
const PackageMetadata = types.PackageMetadata;
const UpdateConfig = types.UpdateConfig;
const Manifest = types.Manifest;
const validateManifest = validation.validateManifest;
const validateIdentity = validation.validateIdentity;
const validateVersion = validation.validateVersion;
const validateWindows = validation.validateWindows;
const validateShell = validation.validateShell;
const validateShortcuts = validation.validateShortcuts;
const validateCommands = validation.validateCommands;
const validateMenus = validation.validateMenus;
const validateFileAssociations = validation.validateFileAssociations;
const validateUrlSchemes = validation.validateUrlSchemes;
const validateShortcutsForPlatforms = validation.validateShortcutsForPlatforms;
const validateCefConfig = validation.validateCefConfig;
const AppIdMode = validation.AppIdMode;
const validateAppId = validation.validateAppId;
const validateName = validation.validateName;
const validateDescription = validation.validateDescription;
const validateUrl = validation.validateUrl;
const validateIcons = validation.validateIcons;
const validatePermissions = validation.validatePermissions;
const validateCapabilities = validation.validateCapabilities;
const validateBridge = validation.validateBridge;
const validateFrontend = validation.validateFrontend;
const validateBridgeOrigin = validation.validateBridgeOrigin;
const validateSecurity = validation.validateSecurity;
const validateUpdates = validation.validateUpdates;
const validatePlatforms = validation.validatePlatforms;
const validatePackageMetadata = validation.validatePackageMetadata;
const versionString = validation.versionString;
test "valid minimal manifest" {
    const manifest: Manifest = .{
        .identity = .{ .id = "com.example.app", .name = "example" },
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
    };

    try validateManifest(manifest);
}

test "manifest validates shell windows and views" {
    const shell_views = [_]ShellView{
        .{ .label = "toolbar", .kind = .toolbar, .edge = .top, .height = 44, .role = "toolbar" },
        .{ .label = "content", .kind = .webview, .url = "zero://app/index.html", .fill = true },
        .{ .label = "status", .kind = .statusbar, .edge = .bottom, .height = 24, .text = "Ready" },
        .{ .label = "save", .kind = .button, .parent = "toolbar", .accessibility_label = "Save document", .text = "Save", .command = "app.save" },
    };
    const shell_windows = [_]ShellWindow{.{
        .label = "main",
        .title = "Example",
        .width = 1100,
        .height = 760,
        .views = &shell_views,
    }};
    try validateManifest(.{
        .identity = .{ .id = "com.example.app", .name = "example" },
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .shell = .{ .windows = &shell_windows },
    });

    const compatibility_windows = [_]Window{.{ .label = "main" }};
    try std.testing.expectError(error.DuplicateWindow, validateManifest(.{
        .identity = .{ .id = "com.example.app", .name = "example" },
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .windows = &compatibility_windows,
        .shell = .{ .windows = &shell_windows },
    }));

    const duplicate_views = [_]ShellView{
        .{ .label = "content", .kind = .webview, .url = "zero://app/index.html" },
        .{ .label = "content", .kind = .label, .text = "Duplicate" },
    };
    const duplicate_window = [_]ShellWindow{.{ .views = &duplicate_views }};
    try std.testing.expectError(error.DuplicateView, validateManifest(.{
        .identity = .{ .id = "com.example.app", .name = "example" },
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .shell = .{ .windows = &duplicate_window },
    }));

    const missing_url_views = [_]ShellView{.{ .label = "content", .kind = .webview }};
    const missing_url_window = [_]ShellWindow{.{ .views = &missing_url_views }};
    try std.testing.expectError(error.MissingRequiredField, validateManifest(.{
        .identity = .{ .id = "com.example.app", .name = "example" },
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .shell = .{ .windows = &missing_url_window },
    }));

    const native_url_views = [_]ShellView{.{ .label = "save", .kind = .button, .url = "zero://app/save.html", .command = "app.save" }};
    const native_url_window = [_]ShellWindow{.{ .views = &native_url_views }};
    try std.testing.expectError(error.InvalidUrl, validateManifest(.{
        .identity = .{ .id = "com.example.app", .name = "example" },
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .shell = .{ .windows = &native_url_window },
    }));

    const native_gpu_options_views = [_]ShellView{.{ .label = "save", .kind = .button, .gpu_backend = .metal, .command = "app.save" }};
    const native_gpu_options_window = [_]ShellWindow{.{ .views = &native_gpu_options_views }};
    try std.testing.expectError(error.InvalidViewKind, validateManifest(.{
        .identity = .{ .id = "com.example.app", .name = "example" },
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .shell = .{ .windows = &native_gpu_options_window },
    }));

    const orphan_views = [_]ShellView{.{ .label = "save", .kind = .button, .parent = "missing", .command = "app.save" }};
    const orphan_window = [_]ShellWindow{.{ .views = &orphan_views }};
    try std.testing.expectError(error.InvalidLayout, validateManifest(.{
        .identity = .{ .id = "com.example.app", .name = "example" },
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .shell = .{ .windows = &orphan_window },
    }));

    const invalid_command_views = [_]ShellView{.{ .label = "save", .kind = .button, .command = "app\tsave" }};
    const invalid_command_window = [_]ShellWindow{.{ .views = &invalid_command_views }};
    try std.testing.expectError(error.InvalidCommand, validateManifest(.{
        .identity = .{ .id = "com.example.app", .name = "example" },
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .shell = .{ .windows = &invalid_command_window },
    }));

    const cyclic_views = [_]ShellView{
        .{ .label = "first", .kind = .stack, .parent = "second" },
        .{ .label = "second", .kind = .stack, .parent = "first" },
    };
    const cyclic_window = [_]ShellWindow{.{ .views = &cyclic_views }};
    try std.testing.expectError(error.InvalidLayout, validateManifest(.{
        .identity = .{ .id = "com.example.app", .name = "example" },
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .shell = .{ .windows = &cyclic_window },
    }));

    const too_long_label = "012345678901234567890123456789012345678901234567890123456789abcde";
    try std.testing.expectEqual(@as(usize, max_view_label_bytes + 1), too_long_label.len);
    const too_long_label_views = [_]ShellView{.{ .label = too_long_label, .kind = .label, .text = "Too long" }};
    const too_long_label_window = [_]ShellWindow{.{ .views = &too_long_label_views }};
    try std.testing.expectError(error.InvalidName, validateManifest(.{
        .identity = .{ .id = "com.example.app", .name = "example" },
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .shell = .{ .windows = &too_long_label_window },
    }));

    const invalid_constraints_views = [_]ShellView{.{ .label = "content", .kind = .webview, .url = "zero://app/index.html", .min_width = 400, .max_width = 320 }};
    const invalid_constraints_window = [_]ShellWindow{.{ .views = &invalid_constraints_views }};
    try std.testing.expectError(error.InvalidDimension, validateManifest(.{
        .identity = .{ .id = "com.example.app", .name = "example" },
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .shell = .{ .windows = &invalid_constraints_window },
    }));
}

test "manifest validates declared platform chrome" {
    // A well-formed declaration: two to max_shell_tabs tabs, unique
    // command ids, control-title labels, vocabulary icon names (bare or
    // app:-namespaced), and one optional primary action.
    const tabs = [_]types.ShellTab{
        .{ .id = "tabs.albums", .label = "Albums", .icon = "app:albums" },
        .{ .id = "tabs.songs", .label = "Songs", .icon = "music" },
    };
    try validateShell(.{ .chrome = .{
        .tabs = &tabs,
        .primary_action = .{ .id = "action.play", .label = "Play", .icon = "play" },
    } }, &.{});

    // One tab is not a choice: the platform tab-bar idiom starts at two.
    const one_tab = [_]types.ShellTab{.{ .id = "tabs.only", .label = "Only" }};
    try std.testing.expectError(error.InvalidLayout, validateShell(.{ .chrome = .{ .tabs = &one_tab } }, &.{}));

    // More destinations than a real system bar holds are refused at
    // validation, not squeezed at runtime.
    const too_many = [_]types.ShellTab{
        .{ .id = "t.a", .label = "A" }, .{ .id = "t.b", .label = "B" },
        .{ .id = "t.c", .label = "C" }, .{ .id = "t.d", .label = "D" },
        .{ .id = "t.e", .label = "E" }, .{ .id = "t.f", .label = "F" },
    };
    try std.testing.expectError(error.InvalidLayout, validateShell(.{ .chrome = .{ .tabs = &too_many } }, &.{}));

    // Every declared control dispatches through the one command path,
    // so ids must be unique across the whole declaration — tabs against
    // tabs, and the action against the tabs.
    const duplicate_tabs = [_]types.ShellTab{
        .{ .id = "tabs.same", .label = "One" },
        .{ .id = "tabs.same", .label = "Two" },
    };
    try std.testing.expectError(error.DuplicateCommand, validateShell(.{ .chrome = .{ .tabs = &duplicate_tabs } }, &.{}));
    try std.testing.expectError(error.DuplicateCommand, validateShell(.{ .chrome = .{
        .tabs = &tabs,
        .primary_action = .{ .id = "tabs.albums", .label = "Albums again" },
    } }, &.{}));

    // Labels are required control titles; icons are vocabulary NAMES
    // (never paths), with an optional app: namespace whose remainder
    // must still be a name.
    const empty_label = [_]types.ShellTab{
        .{ .id = "tabs.a", .label = "" },
        .{ .id = "tabs.b", .label = "B" },
    };
    try std.testing.expectError(error.InvalidName, validateShell(.{ .chrome = .{ .tabs = &empty_label } }, &.{}));
    const path_icon = [_]types.ShellTab{
        .{ .id = "tabs.a", .label = "A", .icon = "assets/icons/a.svg" },
        .{ .id = "tabs.b", .label = "B" },
    };
    try std.testing.expectError(error.InvalidName, validateShell(.{ .chrome = .{ .tabs = &path_icon } }, &.{}));
    const empty_namespace = [_]types.ShellTab{
        .{ .id = "tabs.a", .label = "A", .icon = "app:" },
        .{ .id = "tabs.b", .label = "B" },
    };
    try std.testing.expectError(error.InvalidName, validateShell(.{ .chrome = .{ .tabs = &empty_namespace } }, &.{}));

    // Ids are command ids, capped and charset-checked like every other.
    const bad_id = [_]types.ShellTab{
        .{ .id = "", .label = "A" },
        .{ .id = "tabs.b", .label = "B" },
    };
    try std.testing.expectError(error.InvalidCommand, validateShell(.{ .chrome = .{ .tabs = &bad_id } }, &.{}));
}

test "manifest validates keyboard shortcuts" {
    const manifest: Manifest = .{
        .identity = .{ .id = "com.example.app", .name = "example" },
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .shortcuts = &.{
            .{ .id = "command.palette", .key = "p", .modifiers = .{ .primary = true, .shift = true } },
            .{ .id = "help", .key = "f", .modifiers = .{ .primary = true } },
        },
    };

    try validateManifest(manifest);

    const duplicate: Manifest = .{
        .identity = .{ .id = "com.example.app", .name = "example" },
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .shortcuts = &.{
            .{ .id = "first", .key = "p", .modifiers = .{ .primary = true } },
            .{ .id = "second", .key = "P", .modifiers = .{ .primary = true } },
        },
    };
    try std.testing.expectError(error.DuplicateShortcut, validateManifest(duplicate));

    const windows_alias_duplicate: Manifest = .{
        .identity = .{ .id = "com.example.app", .name = "example" },
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .platforms = &.{.{ .platform = .windows }},
        .shortcuts = &.{
            .{ .id = "primary", .key = "p", .modifiers = .{ .primary = true } },
            .{ .id = "control", .key = "p", .modifiers = .{ .control = true } },
        },
    };
    try std.testing.expectError(error.DuplicateShortcut, validateManifest(windows_alias_duplicate));

    const macos_alias_duplicate: Manifest = .{
        .identity = .{ .id = "com.example.app", .name = "example" },
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .platforms = &.{.{ .platform = .macos }},
        .shortcuts = &.{
            .{ .id = "primary", .key = "p", .modifiers = .{ .primary = true } },
            .{ .id = "command", .key = "p", .modifiers = .{ .command = true } },
        },
    };
    try std.testing.expectError(error.DuplicateShortcut, validateManifest(macos_alias_duplicate));

    const macos_control_distinct: Manifest = .{
        .identity = .{ .id = "com.example.app", .name = "example" },
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .platforms = &.{.{ .platform = .macos }},
        .shortcuts = &.{
            .{ .id = "primary", .key = "p", .modifiers = .{ .primary = true } },
            .{ .id = "control", .key = "p", .modifiers = .{ .control = true } },
        },
    };
    try validateManifest(macos_control_distinct);

    const invalid_key: Manifest = .{
        .identity = .{ .id = "com.example.app", .name = "example" },
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .shortcuts = &.{
            .{ .id = "invalid", .key = "@", .modifiers = .{ .primary = true } },
        },
    };
    try std.testing.expectError(error.InvalidShortcut, validateManifest(invalid_key));

    const unmodified_text_key: Manifest = .{
        .identity = .{ .id = "com.example.app", .name = "example" },
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .shortcuts = &.{
            .{ .id = "text-entry", .key = "p" },
        },
    };
    try std.testing.expectError(error.InvalidShortcut, validateManifest(unmodified_text_key));

    const too_many = [_]Shortcut{.{ .id = "duplicate-ok-for-limit-check", .key = "p" }} ** (max_shortcuts + 1);
    const too_many_manifest: Manifest = .{
        .identity = .{ .id = "com.example.app", .name = "example" },
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .shortcuts = &too_many,
    };
    try std.testing.expectError(error.InvalidShortcut, validateManifest(too_many_manifest));

    const long_id = [_]u8{'x'} ** (max_shortcut_id_bytes + 1);
    const long_id_manifest: Manifest = .{
        .identity = .{ .id = "com.example.app", .name = "example" },
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .shortcuts = &.{.{ .id = long_id[0..], .key = "p" }},
    };
    try std.testing.expectError(error.InvalidShortcut, validateManifest(long_id_manifest));
}

test "manifest validates command metadata" {
    const commands = [_]Command{
        .{ .id = "app.refresh", .title = "Refresh" },
        .{ .id = "app.sidebar.toggle", .title = "Sidebar", .checked = true },
        .{ .id = "app.disabled", .enabled = false },
    };

    try validateManifest(.{
        .identity = .{ .id = "com.example.app", .name = "example" },
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .commands = &commands,
    });

    const duplicate_commands = [_]Command{
        .{ .id = "app.refresh" },
        .{ .id = "app.refresh" },
    };
    try std.testing.expectError(error.DuplicateCommand, validateManifest(.{
        .identity = .{ .id = "com.example.app", .name = "example" },
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .commands = &duplicate_commands,
    }));

    const invalid_id_commands = [_]Command{.{ .id = "bad/name" }};
    try std.testing.expectError(error.InvalidName, validateManifest(.{
        .identity = .{ .id = "com.example.app", .name = "example" },
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .commands = &invalid_id_commands,
    }));

    const invalid_control_commands = [_]Command{.{ .id = "app\nrefresh" }};
    try std.testing.expectError(error.InvalidCommand, validateManifest(.{
        .identity = .{ .id = "com.example.app", .name = "example" },
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .commands = &invalid_control_commands,
    }));

    const long_title = [_]u8{'x'} ** (max_command_title_bytes + 1);
    const long_title_commands = [_]Command{.{ .id = "app.long-title", .title = long_title[0..] }};
    try std.testing.expectError(error.InvalidName, validateManifest(.{
        .identity = .{ .id = "com.example.app", .name = "example" },
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .commands = &long_title_commands,
    }));
}

test "manifest validates native menus" {
    const view_items = [_]MenuItem{
        .{ .label = "Refresh", .command = "app.refresh", .key = "r", .modifiers = .{ .primary = true } },
        .{ .separator = true },
        .{ .label = "Sidebar", .command = "app.sidebar.toggle", .checked = true },
    };
    const menus = [_]Menu{.{ .title = "View", .items = &view_items }};

    try validateManifest(.{
        .identity = .{ .id = "com.example.app", .name = "example" },
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .menus = &menus,
    });

    const missing_command_items = [_]MenuItem{.{ .label = "Refresh" }};
    const missing_command_menus = [_]Menu{.{ .title = "View", .items = &missing_command_items }};
    try std.testing.expectError(error.InvalidCommand, validateManifest(.{
        .identity = .{ .id = "com.example.app", .name = "example" },
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .menus = &missing_command_menus,
    }));

    const invalid_command_items = [_]MenuItem{.{ .label = "Refresh", .command = "app\rrefresh" }};
    const invalid_command_menus = [_]Menu{.{ .title = "View", .items = &invalid_command_items }};
    try std.testing.expectError(error.InvalidCommand, validateManifest(.{
        .identity = .{ .id = "com.example.app", .name = "example" },
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .menus = &invalid_command_menus,
    }));

    const invalid_key_items = [_]MenuItem{.{ .label = "Refresh", .command = "app.refresh", .key = "r" }};
    const invalid_key_menus = [_]Menu{.{ .title = "View", .items = &invalid_key_items }};
    try std.testing.expectError(error.InvalidShortcut, validateManifest(.{
        .identity = .{ .id = "com.example.app", .name = "example" },
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .menus = &invalid_key_menus,
    }));

    const too_many = [_]Menu{.{ .title = "View" }} ** (max_menus + 1);
    try std.testing.expectError(error.InvalidLayout, validateManifest(.{
        .identity = .{ .id = "com.example.app", .name = "example" },
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .menus = &too_many,
    }));
}

test "manifest validates file associations and URL schemes" {
    const doc_extensions = [_][]const u8{ "md", ".markdown" };
    const doc_mime_types = [_][]const u8{ "text/markdown", "application/vnd.native-sdk.note+json" };
    const file_associations = [_]FileAssociation{.{
        .name = "Markdown Document",
        .extensions = &doc_extensions,
        .mime_types = &doc_mime_types,
        .icon = "assets/markdown.icns",
    }};
    const url_schemes = [_]UrlScheme{.{ .scheme = "native-sdk" }};

    try validateManifest(.{
        .identity = .{ .id = "com.example.app", .name = "example" },
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .file_associations = &file_associations,
        .url_schemes = &url_schemes,
    });

    const duplicate_associations = [_]FileAssociation{
        .{ .name = "Markdown", .extensions = &.{"md"} },
        .{ .name = "Other Markdown", .extensions = &.{"MD"} },
    };
    try std.testing.expectError(error.DuplicateFileAssociation, validateManifest(.{
        .identity = .{ .id = "com.example.app", .name = "example" },
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .file_associations = &duplicate_associations,
    }));

    const missing_match = [_]FileAssociation{.{ .name = "Empty" }};
    try std.testing.expectError(error.MissingRequiredField, validateManifest(.{
        .identity = .{ .id = "com.example.app", .name = "example" },
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .file_associations = &missing_match,
    }));

    const separator_mime_types = [_][]const u8{"text/plain;x-scheme-handler/zero"};
    const separator_mime_associations = [_]FileAssociation{.{ .name = "Bad MIME", .mime_types = &separator_mime_types }};
    try std.testing.expectError(error.InvalidPath, validateManifest(.{
        .identity = .{ .id = "com.example.app", .name = "example" },
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .file_associations = &separator_mime_associations,
    }));

    const parameter_mime_types = [_][]const u8{"text/plain;charset=utf-8"};
    const parameter_mime_associations = [_]FileAssociation{.{ .name = "Bad MIME Parameter", .mime_types = &parameter_mime_types }};
    try std.testing.expectError(error.InvalidPath, validateManifest(.{
        .identity = .{ .id = "com.example.app", .name = "example" },
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .file_associations = &parameter_mime_associations,
    }));

    const reserved_schemes = [_]UrlScheme{.{ .scheme = "https" }};
    try std.testing.expectError(error.InvalidUrl, validateManifest(.{
        .identity = .{ .id = "com.example.app", .name = "example" },
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .url_schemes = &reserved_schemes,
    }));

    const duplicate_schemes = [_]UrlScheme{
        .{ .scheme = "acme" },
        .{ .scheme = "acme" },
    };
    try std.testing.expectError(error.DuplicateUrlScheme, validateManifest(.{
        .identity = .{ .id = "com.example.app", .name = "example" },
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .url_schemes = &duplicate_schemes,
    }));
}

test "frontend validation accepts managed dev server config" {
    const command = [_][]const u8{ "npm", "run", "dev", "--", "--host", "127.0.0.1" };
    try validateFrontend(.{
        .dist = "dist",
        .entry = "index.html",
        .spa_fallback = true,
        .dev = .{
            .url = "http://127.0.0.1:5173/",
            .command = &command,
            .ready_path = "/",
            .timeout_ms = 30_000,
        },
    });
}

test "frontend validation rejects unsafe paths and incomplete dev config" {
    try std.testing.expectError(error.InvalidPath, validateFrontend(.{ .dist = "../dist" }));
    try std.testing.expectError(error.InvalidPath, validateFrontend(.{ .entry = "/index.html" }));
    try std.testing.expectError(error.MissingRequiredField, validateFrontend(.{ .dev = .{ .url = "http://127.0.0.1:5173/" } }));
    const command = [_][]const u8{"npm"};
    try std.testing.expectError(error.InvalidUrl, validateFrontend(.{ .dev = .{ .url = "ws://127.0.0.1:5173/", .command = &command } }));
    try std.testing.expectError(error.InvalidTimeout, validateFrontend(.{ .dev = .{ .url = "http://127.0.0.1:5173/", .command = &command, .timeout_ms = 0 } }));
}

test "valid rich manifest" {
    const icons = [_]Icon{
        .{ .asset = "icons/app-128", .size = 128, .scale = 1, .purpose = .any },
        .{ .asset = "icons/app-256", .size = 256, .scale = 1, .purpose = .maskable },
    };
    const permissions = [_]Permission{ .network, .clipboard, .window, .command, .view, .dialog, .credentials, .{ .custom = "com.example.custom" } };
    const bridge_permissions = [_]Permission{.clipboard};
    const bridge_origins = [_][]const u8{ "zero://inline", "https://example.com" };
    const bridge_commands = [_]BridgeCommand{.{ .name = "native.ping", .permissions = &bridge_permissions, .origins = &bridge_origins }};
    const platform_permissions = [_]Permission{.notifications};
    const platforms = [_]PlatformSettings{
        .{
            .platform = .macos,
            .id_override = "com.example.app.macos",
            .min_os_version = "14.0",
            .permissions = &platform_permissions,
            .category = "productivity",
            .entitlements = "macos.entitlements",
        },
        .{ .platform = .linux },
    };
    const authors = [_][]const u8{"Example Team"};
    const keywords = [_][]const u8{ "native", "zig" };
    const manifest: Manifest = .{
        .identity = .{
            .id = "com.example.app",
            .name = "example",
            .display_name = "Example App",
            .description = "An example app exercising every manifest field.",
            .organization = "Example",
            .homepage = "https://example.com/app",
        },
        .version = .{ .major = 1, .minor = 2, .patch = 3, .pre = "beta.1", .build = "20260506" },
        .icons = &icons,
        .permissions = &permissions,
        .bridge = .{ .commands = &bridge_commands },
        .security = .{
            .navigation = .{
                .allowed_origins = &.{ "zero://app", "http://127.0.0.1:5173" },
                .external_links = .{
                    .action = .open_system_browser,
                    .allowed_urls = &.{"https://example.com/*"},
                },
            },
        },
        .platforms = &platforms,
        .package = .{
            .kind = .app,
            .license = "Apache-2.0",
            .authors = &authors,
            .repository = "https://example.com/repo",
            .keywords = &keywords,
        },
    };

    try validateManifest(manifest);
}

test "app id validation" {
    try validateAppId("com.example.app", .reverse_dns);
    try validateAppId("my-tool", .simple);

    try std.testing.expectError(error.InvalidId, validateAppId("", .reverse_dns));
    try std.testing.expectError(error.InvalidId, validateAppId("example", .reverse_dns));
    try std.testing.expectError(error.InvalidId, validateAppId("Com.example.app", .reverse_dns));
    try std.testing.expectError(error.InvalidId, validateAppId("com/example/app", .reverse_dns));
    try std.testing.expectError(error.InvalidId, validateAppId("com..example", .reverse_dns));
    try std.testing.expectError(error.InvalidId, validateAppId(".com.example", .reverse_dns));
    try std.testing.expectError(error.InvalidId, validateAppId("com.example.", .reverse_dns));
    try std.testing.expectError(error.InvalidId, validateAppId("com.example.app!", .reverse_dns));
}

test "name validation" {
    try validateName("Example App");
    try validateName("Apache-2.0");

    try std.testing.expectError(error.InvalidName, validateName(""));
    try std.testing.expectError(error.InvalidName, validateName("."));
    try std.testing.expectError(error.InvalidName, validateName(".."));
    try std.testing.expectError(error.InvalidName, validateName("bad/name"));
    try std.testing.expectError(error.InvalidName, validateName("bad\\name"));
    try std.testing.expectError(error.InvalidName, validateName("bad\x00name"));
}

test "description validation" {
    try validateDescription("A one-line app description.");

    try std.testing.expectError(error.InvalidDescription, validateDescription(""));
    try std.testing.expectError(error.InvalidDescription, validateDescription("two\nlines"));
    try std.testing.expectError(error.InvalidDescription, validateDescription("tab\tcharacter"));
    try std.testing.expectError(error.InvalidDescription, validateDescription("x" ** 257));
}

test "version validation and formatting" {
    var buffer: [64]u8 = undefined;

    try validateVersion(.{ .major = 1, .minor = 2, .patch = 3 });
    try std.testing.expectEqualStrings("1.2.3", try versionString(.{ .major = 1, .minor = 2, .patch = 3 }, &buffer));
    try std.testing.expectEqualStrings("1.2.3-beta.1", try versionString(.{ .major = 1, .minor = 2, .patch = 3, .pre = "beta.1" }, &buffer));
    try std.testing.expectEqualStrings("1.2.3+20260506", try versionString(.{ .major = 1, .minor = 2, .patch = 3, .build = "20260506" }, &buffer));
    try std.testing.expectEqualStrings("1.2.3-beta.1+20260506", try versionString(.{ .major = 1, .minor = 2, .patch = 3, .pre = "beta.1", .build = "20260506" }, &buffer));
    try std.testing.expectError(error.InvalidVersion, validateVersion(.{ .major = 1, .minor = 2, .patch = 3, .pre = "" }));
    try std.testing.expectError(error.InvalidVersion, validateVersion(.{ .major = 1, .minor = 2, .patch = 3, .build = "bad!" }));
    try std.testing.expectError(error.NoSpaceLeft, versionString(.{ .major = 123, .minor = 456, .patch = 789 }, buffer[0..4]));
}

test "url validation" {
    try validateUrl("https://example.com");
    try validateUrl("http://example.com/path");

    try std.testing.expectError(error.InvalidUrl, validateUrl("ftp://example.com"));
    try std.testing.expectError(error.InvalidUrl, validateUrl("https://"));
    try std.testing.expectError(error.InvalidUrl, validateUrl("https:///path"));
    try std.testing.expectError(error.InvalidUrl, validateUrl("https://bad host"));
}

test "icon validation catches zero values and duplicates" {
    try validateIcons(&.{.{ .asset = "icons/app", .size = 128, .scale = 1, .purpose = .any }});

    try std.testing.expectError(error.MissingRequiredField, validateIcons(&.{.{ .asset = "", .size = 128 }}));
    try std.testing.expectError(error.InvalidVersion, validateIcons(&.{.{ .asset = "icons/app", .size = 0 }}));
    try std.testing.expectError(error.InvalidVersion, validateIcons(&.{.{ .asset = "icons/app", .size = 128, .scale = 0 }}));
    try std.testing.expectError(error.DuplicateIcon, validateIcons(&.{
        .{ .asset = "icons/a", .size = 128, .scale = 1, .purpose = .any },
        .{ .asset = "icons/b", .size = 128, .scale = 1, .purpose = .any },
    }));
}

test "permission validation catches duplicates" {
    try validatePermissions(&.{ .network, .clipboard, .command, .view, .dialog, .credentials, .{ .custom = "com.example.custom" } });
    try std.testing.expectError(error.DuplicatePermission, validatePermissions(&.{ .network, .network }));
    try std.testing.expectError(error.DuplicatePermission, validatePermissions(&.{ .{ .custom = "com.example.custom" }, .{ .custom = "com.example.custom" } }));
    try std.testing.expectError(error.InvalidName, validatePermissions(&.{.{ .custom = "bad/name" }}));
}

test "platform validation catches duplicates and invalid overrides" {
    try validatePlatforms(&.{ .{ .platform = .macos, .id_override = "com.example.app.macos" }, .{ .platform = .linux } });

    try std.testing.expectError(error.DuplicatePlatform, validatePlatforms(&.{ .{ .platform = .macos }, .{ .platform = .macos } }));
    try std.testing.expectError(error.MissingRequiredField, validatePlatforms(&.{.{ .platform = .unknown }}));
    try std.testing.expectError(error.InvalidId, validatePlatforms(&.{.{ .platform = .windows, .id_override = "Example.App" }}));
    try std.testing.expectError(error.InvalidVersion, validatePlatforms(&.{.{ .platform = .ios, .min_os_version = "bad!" }}));
}

test "capability validation catches duplicates and invalid custom names" {
    try validateCapabilities(&.{
        .native_module,
        .webview,
        .native_views,
        .menus,
        .shortcuts,
        .tray,
        .notifications,
        .dialog,
        .credentials,
        .open_url,
        .reveal_path,
        .recent_documents,
        .file_drops,
        .app_activation_events,
        .file_associations,
        .url_schemes,
        .{ .custom = "com.example.native-camera" },
    });
    try std.testing.expectError(error.DuplicateCapability, validateCapabilities(&.{ .webview, .webview }));
    try std.testing.expectError(error.DuplicateCapability, validateCapabilities(&.{ .{ .custom = "custom" }, .{ .custom = "custom" } }));
    try std.testing.expectError(error.InvalidName, validateCapabilities(&.{.{ .custom = "bad/name" }}));
}

test "bridge validation catches duplicate commands and invalid origins" {
    try validateBridge(.{ .commands = &.{.{ .name = "native.ping", .origins = &.{"zero://inline"} }} });
    try std.testing.expectError(error.DuplicateBridgeCommand, validateBridge(.{ .commands = &.{ .{ .name = "native.ping" }, .{ .name = "native.ping" } } }));
    try std.testing.expectError(error.InvalidUrl, validateBridge(.{ .commands = &.{.{ .name = "native.ping", .origins = &.{"bad origin"} }} }));
    try std.testing.expectError(error.InvalidName, validateBridge(.{ .commands = &.{.{ .name = "" }} }));
}

test "security validation catches invalid navigation and external policies" {
    try validateSecurity(.{ .navigation = .{
        .allowed_origins = &.{ "zero://app", "https://example.com" },
        .external_links = .{ .action = .open_system_browser, .allowed_urls = &.{"https://example.com/*"} },
    } });

    try std.testing.expectError(error.InvalidUrl, validateSecurity(.{ .navigation = .{ .allowed_origins = &.{"bad origin"} } }));
    try std.testing.expectError(error.InvalidUrl, validateSecurity(.{ .navigation = .{ .external_links = .{ .allowed_urls = &.{"ssh://example.com"} } } }));
    try std.testing.expectError(error.InvalidUrl, validateSecurity(.{ .navigation = .{ .external_links = .{ .allowed_urls = &.{"https://example.com*"} } } }));
}

test "package metadata validation catches empty authors and invalid keywords" {
    try validatePackageMetadata(.{
        .kind = .cli,
        .license = "Apache-2.0",
        .authors = &.{"Example"},
        .repository = "https://example.com/repo",
        .keywords = &.{ "zig", "native-apps" },
    });

    try std.testing.expectError(error.MissingRequiredField, validatePackageMetadata(.{ .authors = &.{""} }));
    try std.testing.expectError(error.InvalidKeyword, validatePackageMetadata(.{ .keywords = &.{""} }));
    try std.testing.expectError(error.InvalidKeyword, validatePackageMetadata(.{ .keywords = &.{"Bad"} }));
    try std.testing.expectError(error.InvalidUrl, validatePackageMetadata(.{ .repository = "ssh://example.com/repo" }));
}
