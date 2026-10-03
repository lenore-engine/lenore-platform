const builtin = @import("builtin");

// Comptime backend selection, not a vtable: a backend the target does not use
// is never analysed, so it cannot link. Every backend here is native and fully
// implemented, and a target without one is a compile error rather than a stub
// that answers "unavailable".
pub const active = switch (builtin.os.tag) {
    .linux => @import("linux/Wayland.zig"),
    else => @compileError("lenore-platform has no backend for " ++ @tagName(builtin.os.tag)),
};
