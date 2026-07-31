const std = @import("std");
const platform = @import("lenore-platform");

const testing = std.testing;

const FakeIo = struct {
    now_ns: i96,
    last_timeout: ?std.Io.Timeout = null,
    vtable: std.Io.VTable,

    fn init(now_ns: i96) FakeIo {
        return .{
            .now_ns = now_ns,
            .vtable = std.Io.failing.vtable.*,
        };
    }

    fn io(self: *FakeIo) std.Io {
        self.vtable.now = now;
        self.vtable.sleep = sleep;
        return .{ .userdata = self, .vtable = &self.vtable };
    }

    fn now(userdata: ?*anyopaque, _: std.Io.Clock) std.Io.Timestamp {
        const self: *FakeIo = @ptrCast(@alignCast(userdata.?));
        return .{ .nanoseconds = self.now_ns };
    }

    fn sleep(userdata: ?*anyopaque, timeout: std.Io.Timeout) std.Io.Cancelable!void {
        const self: *FakeIo = @ptrCast(@alignCast(userdata.?));
        self.last_timeout = timeout;
    }
};
test "clock rebases injected time" {
    var fake: FakeIo = .init(10_000);
    const clock: platform.Clock = .init(fake.io());

    try testing.expectEqual(0, clock.now());
    fake.now_ns = 10_450;
    try testing.expectEqual(450, clock.now());
    fake.now_ns = 11_000;
    try testing.expectEqual(1000, clock.now());
}
test "sleepUntil uses an absolute deadline" {
    var fake: FakeIo = .init(10_000);
    const clock: platform.Clock = .init(fake.io());
    fake.now_ns = 10_400;

    fake.last_timeout = null;
    try clock.sleepUntil(1000);
    switch (fake.last_timeout.?) {
        .deadline => |deadline| {
            try testing.expectEqual(std.Io.Clock.awake, deadline.clock);
            try testing.expectEqual(11_000, deadline.raw.nanoseconds);
        },
        else => return error.ExpectedDeadline,
    }

    fake.now_ns = 11_001;
    fake.last_timeout = null;
    try clock.sleepUntil(1000);
    try testing.expectEqual(null, fake.last_timeout);
}
test "host clock is monotonic" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const clock: platform.Clock = .init(threaded.io());

    const first = clock.now();
    const second = clock.now();
    try testing.expect(second >= first);
}
