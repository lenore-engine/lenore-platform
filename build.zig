const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Temporary zglfw module
    const zglfw = b.dependency("zglfw", .{ .target = target, .optimize = optimize, .x11 = false, .wayland = true });
    const mod = b.addModule("lenore-platform", .{
        .root_source_file = b.path("src/root.zig"),
        .imports = &.{.{ .name = "zglfw", .module = zglfw.module("root") }},
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(zglfw.artifact("glfw"));

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/root.zig"),
            .imports = &.{.{ .name = "lenore-platform", .module = mod }},
            .target = target,
            .optimize = optimize,
        }),
    });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);
}
