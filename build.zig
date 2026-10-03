const std = @import("std");

// Inputs to the protocol generator, in the order the bindings are generated in.
// Listed rather than globbed: adding one is a decision, and the order decides
// nothing but keeps a regeneration from producing a diff.
const protocol_inputs = [_][]const u8{
    "wayland.xml",
    "xdg-shell.xml",
    "viewporter.xml",
    "cursor-shape-v1.xml",
    "fractional-scale-v1.xml",
    "xdg-decoration-unstable-v1.xml",
    "pointer-constraints-unstable-v1.xml",
    "relative-pointer-unstable-v1.xml",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("lenore-platform", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // The Wayland backend talks to libwayland-client rather than reimplementing
    // the wire protocol, because it cannot do otherwise: the wl_display handed
    // to vkCreateWaylandSurfaceKHR has to be one the driver can drive, and the
    // RADV build on this host lists libwayland-client.so.0 in its own
    // DT_NEEDED. Building it needs the library's development symlink, from
    // `wayland-devel` on Chimera.
    if (target.result.os.tag == .linux) {
        mod.link_libc = true;
        mod.linkSystemLibrary("wayland-client", .{});
        // The compositor sends a keymap and a modifier mask, and the client is
        // what turns a keycode into a character. xkbcommon is that rule set.
        mod.linkSystemLibrary("xkbcommon", .{});
    }

    // Regenerates the Zig protocol bindings from the vendored XML. Not part of
    // an ordinary build: the output is committed, so a build compiles ordinary
    // files and an editor resolves them. Run it after revendoring a protocol.
    //
    // The tables it writes are diffed against wayland-scanner's by
    // tools/verify-tables.py, which is the check that the signatures and type
    // arrays are right; a wrong one corrupts libwayland instead of failing to
    // compile.
    const scanner = b.addExecutable(.{
        .name = "wayland-scanner-zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/scanner.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const scan = b.addRunArtifact(scanner);
    scan.setCwd(b.path("."));
    scan.has_side_effects = true;
    scan.addArg("src/backend/linux/wl/protocol");
    for (protocol_inputs) |name| scan.addArg(b.pathJoin(&.{ "protocols", name }));

    const format = b.addSystemCommand(&.{ b.graph.zig_exe, "fmt", "src/backend/linux/wl/protocol" });
    format.setCwd(b.path("."));
    format.has_side_effects = true;
    format.step.dependOn(&scan.step);

    const protocols_step = b.step("protocols", "Regenerate the Wayland protocol bindings");
    protocols_step.dependOn(&format.step);

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = testRoot(b, "tests"),
            .imports = &.{.{ .name = "lenore-platform", .module = mod }},
            .target = target,
            .optimize = optimize,
        }),
    });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    // addTest collects test blocks from the root module of its compilation only.
    // The suite above imports lenore-platform rather than being it, so a `test`
    // written beside the code in src/ would never run and would stay green
    // forever. This second binary is that module.
    const module_tests = b.addTest(.{ .root_module = mod });
    test_step.dependOn(&b.addRunArtifact(module_tests).step);
}

// Sorted names of the `.zig` files directly in `dir_path`, or nothing if the
// directory does not exist.
//
// Directory order is not stable across filesystems, and the generated test root
// below is part of a cache key, so the order is pinned here rather than left to
// the reader of either caller.
fn zigFilesIn(b: *std.Build, dir_path: []const u8) [][]const u8 {
    var names: std.ArrayList([]const u8) = .empty;

    // The filesystem is behind std.Io in 0.16, and the build graph carries the
    // Io the rest of the build already uses.
    const io = b.graph.io;
    var dir = b.build_root.handle.openDir(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        // A module without the directory yet is normal. Anything else is a
        // broken checkout or wrong permissions, and silently building nothing
        // would look like a suite that passes.
        error.FileNotFound => return names.items,
        else => std.debug.panic("cannot open {s}/: {t}", .{ dir_path, err }),
    };
    defer dir.close(io);

    var walker = dir.iterate();
    while (walker.next(io) catch @panic("cannot list the directory")) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
        names.append(b.allocator, b.dupe(entry.name)) catch @panic("OOM");
    }

    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b_: []const u8) bool {
            return std.mem.order(u8, a, b_) == .lt;
        }
    }.lessThan);
    return names.items;
}

// Generates the test root by listing `dir_path`, so a new test file is picked
// up by existing.
//
// This cannot be done at comptime: `@import` takes a string literal and there
// is no filesystem at comptime. The build script is the earliest place that can
// see the directory, so the root is generated here rather than maintained by
// hand. Zig analyses lazily, and a test file nobody imports is silently not
// run, so a forgotten registration is a suite that goes green without it.
fn testRoot(b: *std.Build, dir_path: []const u8) std.Build.LazyPath {
    var source: std.ArrayList(u8) = .empty;
    source.appendSlice(b.allocator, "// Generated by build.zig from the test directory. Do not edit.\ntest {\n") catch @panic("OOM");
    for (zigFilesIn(b, dir_path)) |name| {
        source.print(b.allocator, "    _ = @import(\"{s}/{s}\");\n", .{ dir_path, name }) catch @panic("OOM");
    }
    source.appendSlice(b.allocator, "}\n") catch @panic("OOM");

    // The generated root sits beside a copy of the directory, so its imports
    // resolve relative to itself.
    const wf = b.addWriteFiles();
    _ = wf.addCopyDirectory(b.path(dir_path), dir_path, .{});
    return wf.add("test_root.zig", source.items);
}
