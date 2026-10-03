const std = @import("std");

// The few libc calls this backend needs that std 0.16 does not expose.
//
// std.posix kept read, poll, mmap and munmap and moved the rest behind std.Io,
// which takes an Io this backend does not have: these descriptors come from the
// compositor over the protocol and never become an Io.File. std.c has them but
// keeps close and write private.

pub extern fn close(fd: i32) c_int;
pub extern fn write(fd: i32, buffer: [*]const u8, count: usize) isize;
pub extern fn pipe2(fds: *[2]i32, flags: c_uint) c_int;

// O_CLOEXEC, taken from std's own description of the flag word rather than
// written out: a clipboard pipe must not survive into a child process.
pub const cloexec: c_uint = @as(u32, @bitCast(std.posix.O{ .CLOEXEC = true }));

// Ignores SIGPIPE unless the program has already said what it wants.
//
// Writing a selection into a pipe whose reader closed early raises SIGPIPE,
// whose default action is to end the process. The write has to answer EPIPE
// instead, and there is no per-call way to ask for that on a pipe: MSG_NOSIGNAL
// is a socket flag.
//
// The current disposition is read first, so a program that installed its own
// handler keeps it.
pub fn ignoreBrokenPipe() void {
    var current: std.posix.Sigaction = undefined;
    std.posix.sigaction(.PIPE, null, &current);
    if (current.handler.handler != std.posix.SIG.DFL) return;

    const ignore: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.mem.zeroes(std.posix.sigset_t),
        .flags = 0,
    };
    std.posix.sigaction(.PIPE, &ignore, null);
}
