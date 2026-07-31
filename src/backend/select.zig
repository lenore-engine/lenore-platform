const builtin = @import("builtin");
const options = @import("build_options");

// Comptime backend selection, not vtable: dead backends cannot link. glfw is
// the only cross-OS backend; native backends must be fully implemented.
pub const active = if (options.force_glfw) @import("glfw.zig") else switch (builtin.os.tag) {
    .linux => @import("linux/Wayland.zig"),
    .windows => @import("windows/Win32.zig"),
    .macos => @import("macos/Cacao.zig"),
    else => @compileError("lenore-platform has no backend for " ++ @tagName(builtin.os.tag)),
};
