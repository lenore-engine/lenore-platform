const std = @import("std");

// The OS clock lives behind std.Io; Io.Threaded is the clock_gettime /
// RtlQueryPerformanceCounter dispatch we would otherwise write three times.
// Injection falls out of the same design: a test passes a fake Io and drives
// time by hand, which is what makes the ring's ordering assertable offline.
pub const Clock = struct {
    io: std.Io,
    // Origin for the u64 timestamps below. Io.Timestamp is an i96 count from an
    // unspecified point; events carry u64 nanoseconds from here instead — 584
    // years of range, and zero is valid at initialization.
    origin: std.Io.Timestamp,

    // .awake is CLOCK_MONOTONIC on Linux (std/Io.zig, Clock.awake). Backends
    // timestamp submitted events through this clock, so event and frame
    // timestamps share one domain.
    const source: std.Io.Clock = .awake;

    pub fn init(io: std.Io) Clock {
        return .{ .io = io, .origin = source.now(io) };
    }

    // Nanoseconds since init. Monotonic, so consecutive calls may return equal
    // values. Only a fake clock can hand back a negative interval, and those
    // exist only in tests.
    pub fn now(self: Clock) u64 {
        const elapsed = self.origin.durationTo(source.now(self.io));
        return @intCast(elapsed.nanoseconds);
    }

    // Waits until deadline_ns unless canceled. The deadline uses the same
    // timebase as now(), so work performed before the wait shortens the
    // remaining sleep instead of shifting the frame boundary.
    pub fn sleepUntil(self: Clock, deadline_ns: u64) std.Io.Cancelable!void {
        // A missed deadline is not an error. Measured locally on Linux: the
        // clock check costs about 22 ns against 13 us for an already-expired wait.
        if (self.now() >= deadline_ns) return;
        const deadline: std.Io.Clock.Timestamp = .{
            .clock = source,
            .raw = self.origin.addDuration(.{ .nanoseconds = deadline_ns }),
        };
        return deadline.wait(self.io);
    }
};
