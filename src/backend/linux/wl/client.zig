const std = @import("std");
const wl = @import("protocol/wayland.zig");

// libwayland-client, bound by hand. Transcribed from wayland-util.h and
// wayland-client-core.h of wayland 1.26.0; re-check with
// `pkg-config --modversion wayland-client`.
//
// The C headers are not translated because there is almost nothing in them to
// translate: every request wrapper is `static inline` and so has no symbol to
// call, and the interface tables are the generator's job. What remains is the
// handful of entry points declared below.
//
// Two sections, and they are different kinds of thing. The first is the ABI the
// generated protocol bindings are written against: argument encoding, the
// static tables, and the proxy entry points. The second is the connection,
// which no protocol file describes because it is the transport the protocol
// travels over.

// Argument encoding and static tables
// ===================================

// 24.8 signed fixed point (wayland-util.h, wl_fixed_t). Pointer coordinates and
// scroll deltas arrive in it; nothing else in the protocols this module speaks
// uses it.
pub const Fixed = enum(i32) {
    _,

    pub fn toFloat(self: Fixed) f32 {
        return @as(f32, @floatFromInt(@backingInt(self))) / 256.0;
    }

    pub fn fromFloat(value: f32) Fixed {
        // @intFromFloat is undefined rather than trapping in the shipping
        // build, so the domain is narrowed here instead of being assumed. The
        // 24.8 range is about +-8.4e6, which a surface coordinate cannot reach,
        // but a non-finite value can arrive from any float arithmetic.
        if (!std.math.isFinite(value)) return @fromBackingInt(@intCast(0));
        const scaled = std.math.clamp(
            @round(value * 256.0),
            @as(f32, @floatFromInt(std.math.minInt(i32))),
            @as(f32, @floatFromInt(std.math.maxInt(i32))),
        );
        return @fromBackingInt(@intCast(@as(i32, @intFromFloat(scaled))));
    }
};

// wl_array (wayland-util.h). Only ever received, never sent: xdg_toplevel
// carries the window states in one and wl_keyboard.enter the pressed keys, and
// both are arrays of u32.
pub const Array = extern struct {
    size: usize,
    alloc: usize,
    data: ?*anyopaque,

    // Borrows libwayland's bytes, which live only for the duration of the event
    // handler the array was delivered to.
    //
    // The alignment is the wire format's: an array's payload is padded to a
    // 32-bit boundary (wayland.xml, "Wire Format"), which is what a u32 needs.
    pub fn u32Slice(self: *const Array) []const u32 {
        const data = self.data orelse return &.{};
        const items: [*]const u32 = @ptrCast(@alignCast(data));
        return items[0 .. self.size / @sizeOf(u32)];
    }
};

pub const Argument = extern union {
    i: i32,
    u: u32,
    f: Fixed,
    s: ?[*:0]const u8,
    o: ?*Proxy,
    n: u32,
    a: ?*Array,
    h: i32,
};

pub const Message = extern struct {
    name: [*:0]const u8,
    // Argument types, one character each, optionally preceded by the decimal
    // version the message was introduced in and each optionally preceded by `?`
    // when the argument may be null.
    signature: [*:0]const u8,
    // One entry per argument, null for everything that is not an object or a
    // new_id. Generated, and wrong entries here corrupt libwayland rather than
    // failing to compile, which is why the generator's output is diffed against
    // wayland-scanner's.
    types: [*]const ?*const Interface,
};

pub const Interface = extern struct {
    name: [*:0]const u8,
    version: c_int,
    method_count: c_int,
    methods: ?[*]const Message,
    event_count: c_int,
    events: ?[*]const Message,
};

// Dispatched events are decoded by one function per interface rather than by a
// table of per-event callbacks. wayland-util.h says why, at wl_dispatcher_func_t:
// the callback table is invoked through libffi, and a dispatcher is called
// directly.
pub const DispatcherFn = *const fn (
    implementation: ?*const anyopaque,
    target: *anyopaque,
    opcode: u32,
    message: *const Message,
    args: [*]Argument,
) callconv(.c) c_int;

// wl_proxy_marshal_array_flags answers null when it could not create the object
// a request asked for: out of memory, or a connection that has already failed.
pub const CreateError = error{ProxyCreationFailed};

pub const Proxy = opaque {
    // WL_MARSHAL_FLAG_DESTROY (wayland-client-core.h). Set on a request the
    // protocol marks as a destructor, which frees the proxy after sending.
    const flag_destroy: u32 = 1 << 0;

    pub fn destroy(self: *Proxy) void {
        wl_proxy_destroy(self);
    }

    pub fn version(self: *Proxy) u32 {
        return wl_proxy_get_version(self);
    }

    pub fn id(self: *Proxy) u32 {
        return wl_proxy_get_id(self);
    }

    pub fn marshal(self: *Proxy, opcode: u32, args: ?[*]Argument) void {
        _ = wl_proxy_marshal_array_flags(self, opcode, null, self.version(), 0, args);
    }

    pub fn marshalDestructor(self: *Proxy, opcode: u32, args: ?[*]Argument) void {
        _ = wl_proxy_marshal_array_flags(self, opcode, null, self.version(), flag_destroy, args);
    }

    // A created object inherits its parent's version. That is the protocol's
    // rule and what wayland-scanner emits for every constructor but
    // wl_registry.bind, which is the one request whose new_id names no
    // interface and so has to be told both.
    pub fn marshalConstructor(
        self: *Proxy,
        opcode: u32,
        child: *const Interface,
        args: [*]Argument,
    ) ?*Proxy {
        return wl_proxy_marshal_array_flags(self, opcode, child, self.version(), 0, args);
    }

    pub fn marshalConstructorVersioned(
        self: *Proxy,
        opcode: u32,
        child: *const Interface,
        child_version: u32,
        args: [*]Argument,
    ) ?*Proxy {
        return wl_proxy_marshal_array_flags(self, opcode, child, child_version, 0, args);
    }
};

// Routes `object`'s events to `handler`.
//
// `data` travels as the dispatcher's implementation pointer rather than as the
// proxy's user data, which stays free for whoever owns the object. It must
// outlive the object: libwayland hands it back on every event until the proxy
// is destroyed.
//
// The generated bindings supply `decode`, which is the only part that knows how
// an opcode maps onto the event union.
pub fn addListener(
    comptime Object: type,
    comptime Event: type,
    comptime decode: fn (u32, [*]Argument) Event,
    comptime T: type,
    comptime handler: fn (*Object, Event, T) void,
    object: *Object,
    data: T,
) void {
    comptime {
        const info = @typeInfo(T);
        if (info != .pointer or info.pointer.size != .one)
            @compileError("listener data must be a single-item pointer, got " ++ @typeName(T));
    }

    const trampoline = struct {
        fn dispatch(
            implementation: ?*const anyopaque,
            target: *anyopaque,
            opcode: u32,
            _: *const Message,
            args: [*]Argument,
        ) callconv(.c) c_int {
            // The opcode was checked against this object's own event count by
            // libwayland before the event was queued, so `decode` is total over
            // what can arrive here.
            handler(
                @ptrCast(target),
                decode(opcode, args),
                @ptrCast(@alignCast(@constCast(implementation))),
            );
            return 0;
        }
    };

    const proxy: *Proxy = @ptrCast(object);
    _ = wl_proxy_add_dispatcher(proxy, trampoline.dispatch, data, null);
}

extern fn wl_proxy_destroy(proxy: *Proxy) void;
extern fn wl_proxy_get_version(proxy: *Proxy) u32;
extern fn wl_proxy_get_id(proxy: *Proxy) u32;
extern fn wl_proxy_marshal_array_flags(
    proxy: *Proxy,
    opcode: u32,
    interface: ?*const Interface,
    version: u32,
    flags: u32,
    args: ?[*]Argument,
) ?*Proxy;
extern fn wl_proxy_add_dispatcher(
    proxy: *Proxy,
    dispatcher: DispatcherFn,
    implementation: ?*const anyopaque,
    data: ?*anyopaque,
) c_int;

// The connection
// ==============

// Every one of these means the compositor is gone or the protocol was misused,
// and neither is recoverable: a protocol error has already put the connection
// into a state where every later request is discarded.
pub const ConnectionError = error{ConnectionLost};

// Connects to $WAYLAND_DISPLAY, or to `name` when it is given. Null means there
// is no compositor to talk to, which is the one ordinary failure here.
pub fn connect(name: ?[*:0]const u8) ?*wl.Display {
    return wl_display_connect(name);
}

pub fn disconnect(display: *wl.Display) void {
    wl_display_disconnect(display);
}

// Sends everything queued. A full socket is reported as `error.WouldBlock`
// rather than as a lost connection: it means the compositor has not drained us
// yet, and the requests stay queued for the next flush.
pub fn flush(display: *wl.Display) (ConnectionError || error{WouldBlock})!void {
    const rc = wl_display_flush(display);
    if (rc >= 0) return;
    return switch (std.posix.errno(rc)) {
        .AGAIN => error.WouldBlock,
        else => error.ConnectionLost,
    };
}

// Blocks until at least one event has been dispatched. Returns the number
// dispatched.
pub fn dispatch(display: *wl.Display) ConnectionError!u32 {
    const count = wl_display_dispatch(display);
    if (count < 0) return error.ConnectionLost;
    return @intCast(count);
}

// Dispatches what has already been read, without touching the socket.
pub fn dispatchPending(display: *wl.Display) ConnectionError!u32 {
    const count = wl_display_dispatch_pending(display);
    if (count < 0) return error.ConnectionLost;
    return @intCast(count);
}

// Dispatches for at most `timeout_ns`. The timeout is a duration, not a
// deadline: measured against wayland 1.26.0, a 250 ms timeout on an idle
// connection returns after 250 ms, and a zero timeout returns immediately after
// draining whatever was readable.
pub fn dispatchTimeout(display: *wl.Display, timeout_ns: u64) ConnectionError!u32 {
    const timeout: std.c.timespec = .{
        .sec = @intCast(timeout_ns / std.time.ns_per_s),
        .nsec = @intCast(timeout_ns % std.time.ns_per_s),
    };
    const count = wl_display_dispatch_timeout(display, &timeout);
    if (count < 0) return error.ConnectionLost;
    return @intCast(count);
}

// Sends everything queued and blocks until the compositor has answered all of
// it. The startup handshake is built out of this and nothing else should be:
// it is a stall by construction.
pub fn roundtrip(display: *wl.Display) ConnectionError!u32 {
    const count = wl_display_roundtrip(display);
    if (count < 0) return error.ConnectionLost;
    return @intCast(count);
}

// What went wrong, for the log line that accompanies a lost connection.
//
// Reported rather than interpreted: everything here is passed straight to the
// log, so nothing depends on how libwayland chooses to encode which kind of
// failure it was. A non-null `interface` means the compositor rejected a
// request and named the object it arrived on, which is a bug in this backend.
pub const Failure = struct {
    // errno as libwayland last recorded it, 0 while the connection is healthy.
    // Kept as a number: it comes from a library, and @enumFromInt onto
    // std.posix.E is undefined for a value that is not a member of it.
    code: c_int,
    interface: ?[*:0]const u8,
    object_id: u32,
    protocol_code: u32,
};

pub fn failure(display: *wl.Display) Failure {
    var interface: ?*const Interface = null;
    var object_id: u32 = 0;
    const protocol_code = wl_display_get_protocol_error(display, &interface, &object_id);
    return .{
        .code = wl_display_get_error(display),
        .interface = if (interface) |named| named.name else null,
        .object_id = object_id,
        .protocol_code = protocol_code,
    };
}

extern fn wl_display_connect(name: ?[*:0]const u8) ?*wl.Display;
extern fn wl_display_disconnect(display: *wl.Display) void;
extern fn wl_display_flush(display: *wl.Display) c_int;
extern fn wl_display_dispatch(display: *wl.Display) c_int;
extern fn wl_display_dispatch_pending(display: *wl.Display) c_int;
extern fn wl_display_dispatch_timeout(display: *wl.Display, timeout: *const std.c.timespec) c_int;
extern fn wl_display_roundtrip(display: *wl.Display) c_int;
extern fn wl_display_get_error(display: *wl.Display) c_int;
extern fn wl_display_get_protocol_error(
    display: *wl.Display,
    interface: *?*const Interface,
    id: *u32,
) u32;
