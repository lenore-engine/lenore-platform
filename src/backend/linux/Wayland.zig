const std = @import("std");
const window = @import("../../window.zig");
const Input = @import("../../input.zig").Input;
const Extent2D = @import("../../types.zig").Extent2D;

const client = @import("wl/client.zig");
const wl = @import("wl/protocol/wayland.zig");
const xdg = @import("wl/protocol/xdg_shell.zig");
const zxdg = @import("wl/protocol/xdg_decoration_unstable_v1.zig");
const wp_viewporter = @import("wl/protocol/viewporter.zig");
const wp_fractional_scale = @import("wl/protocol/fractional_scale_v1.zig");
const zwp_constraints = @import("wl/protocol/pointer_constraints_unstable_v1.zig");
const zwp_relative = @import("wl/protocol/relative_pointer_unstable_v1.zig");
const wp_cursor = @import("wl/protocol/cursor_shape_v1.zig");
const seat_module = @import("wl/seat.zig");
const wl_posix = @import("wl/posix.zig");

// Native Wayland backend.
//
// A connection, its toplevels, and one seat. The configure sequence turns into
// SurfaceMetrics here; everything a person operates lives in wl/seat.zig, which
// routes by surface back into the window that owns it.
//
// Two lifetimes decide the shape of everything below, and both come from the
// contract in window.zig rather than from Wayland.
//
// Platform is returned by value from init, so nothing created there may hold a
// pointer to it. The connection therefore lives in one allocation that the
// handle points at, and every listener registered at startup is given that
// pointer.
//
// Window is returned by value too, and copied into wherever the caller keeps
// it. Its listeners are registered in captureInput instead, which the contract
// already defines as the point where a window starts producing events and which
// receives the window at the address it will keep. The invariant that buys is
// that a Window must not be moved after captureInput: libwayland holds the
// address until the proxies are destroyed.

// Fractional scale arrives as the numerator of a fraction over 120
// (fractional-scale-v1.xml, wp_fractional_scale_v1.preferred_scale). Integer
// buffer scale is stored in the same unit so that one field answers both paths.
const scale_denominator = 120;

// Two things here outlive the call that makes them: the connection, for the
// reason above, and the clipboard's copy of whatever this program last offered,
// because the compositor asks for the bytes long afterwards.
const allocator = std.heap.c_allocator;

// The compositor answers the first commit on a surface that has a role with a
// configure, so one round trip is what this costs in practice. The second is
// slack; past it the window runs at the size the caller asked for and says so.
const configure_round_trips = 2;

pub const Connection = struct {
    display: *wl.Display,
    registry: *wl.Registry,

    compositor: ?*wl.Compositor = null,
    wm_base: ?*xdg.WmBase = null,
    viewporter: ?*wp_viewporter.Viewporter = null,
    fractional_scales: ?*wp_fractional_scale.FractionalScaleManagerV1 = null,
    decorations: ?*zxdg.DecorationManagerV1 = null,
    constraints: ?*zwp_constraints.PointerConstraintsV1 = null,
    relative_pointers: ?*zwp_relative.RelativePointerManagerV1 = null,
    cursor_shapes: ?*wp_cursor.CursorShapeManagerV1 = null,
    data_devices: ?*wl.DataDeviceManager = null,

    // Bound during the registry sweep, then made into the seat below. The two
    // are separate because a seat listener needs the address the seat will keep
    // and that address is inside this allocation.
    seat_proxy: ?*wl.Seat = null,
    seat: ?seat_module.Seat = null,

    // Every window that has captured input, in no particular order. The seat
    // routes by wl_surface and this is what turns one back into a window.
    windows: ?*Window = null,

    // Latched on the first failed dispatch. Every later pump returns without
    // touching the socket and every window reports that it should close, which
    // is how a compositor going away ends the frame loop instead of spinning.
    lost: bool = false,

    fn bindGlobal(
        self: *Connection,
        comptime T: type,
        slot: *?*T,
        name: u32,
        interface: []const u8,
        advertised: u32,
    ) void {
        if (slot.* != null) return;
        if (!std.mem.eql(u8, interface, std.mem.span(T.interface.name))) return;

        // The lower of what the compositor offers and what these bindings were
        // generated from. Asking for more than either side knows is a protocol
        // error on the first request that needs the difference.
        const version = @min(advertised, T.generated_version);
        slot.* = self.registry.bind(name, T, version) catch |err| {
            std.log.warn("wayland: cannot bind {s} version {d}: {t}", .{ interface, version, err });
            return;
        };
    }

    pub fn windowOf(self: *Connection, surface: ?*wl.Surface) ?*Window {
        const target = surface orelse return null;
        var current = self.windows;
        while (current) |candidate| : (current = candidate.next) {
            if (candidate.surface == target) return candidate;
        }
        return null;
    }

    fn register(self: *Connection, target: *Window) void {
        if (self.windowOf(target.surface) != null) return;
        target.next = self.windows;
        self.windows = target;
    }

    fn unregister(self: *Connection, target: *Window) void {
        if (self.seat) |*seat| seat.forget(target);

        var link = &self.windows;
        while (link.*) |candidate| {
            if (candidate == target) {
                link.* = candidate.next;
                target.next = null;
                return;
            }
            link = &candidate.next;
        }
    }

    fn fail(self: *Connection) void {
        if (self.lost) return;
        self.lost = true;
        const why = client.failure(self.display);
        std.log.err(
            "wayland: connection lost (errno {d}); protocol error {d} on {?s} id {d}",
            .{ why.code, why.protocol_code, why.interface, why.object_id },
        );
    }
};

fn onRegistry(_: *wl.Registry, event: wl.Registry.Event, connection: *Connection) void {
    switch (event) {
        .global => |global| {
            const interface = std.mem.span(global.interface);
            connection.bindGlobal(wl.Compositor, &connection.compositor, global.name, interface, global.version);
            connection.bindGlobal(xdg.WmBase, &connection.wm_base, global.name, interface, global.version);
            connection.bindGlobal(wp_viewporter.Viewporter, &connection.viewporter, global.name, interface, global.version);
            connection.bindGlobal(
                wp_fractional_scale.FractionalScaleManagerV1,
                &connection.fractional_scales,
                global.name,
                interface,
                global.version,
            );
            connection.bindGlobal(zxdg.DecorationManagerV1, &connection.decorations, global.name, interface, global.version);
            connection.bindGlobal(wl.Seat, &connection.seat_proxy, global.name, interface, global.version);
            connection.bindGlobal(
                zwp_constraints.PointerConstraintsV1,
                &connection.constraints,
                global.name,
                interface,
                global.version,
            );
            connection.bindGlobal(
                zwp_relative.RelativePointerManagerV1,
                &connection.relative_pointers,
                global.name,
                interface,
                global.version,
            );
            connection.bindGlobal(
                wp_cursor.CursorShapeManagerV1,
                &connection.cursor_shapes,
                global.name,
                interface,
                global.version,
            );
            connection.bindGlobal(
                wl.DataDeviceManager,
                &connection.data_devices,
                global.name,
                interface,
                global.version,
            );
        },
        // Nothing bound here is ever removed by a compositor in practice, and
        // reacting would mean tearing down a live window. A global that goes
        // away is noticed as the protocol error on the next request.
        .global_remove => {},
    }
}

// The compositor pings to check the client is alive and kills it if the pong
// does not come (xdg-shell.xml, xdg_wm_base.ping).
fn onWmBase(wm_base: *xdg.WmBase, event: xdg.WmBase.Event, _: *Connection) void {
    switch (event) {
        .ping => |ping| wm_base.pong(ping.serial),
    }
}

pub const Platform = struct {
    connection: *Connection,

    pub fn init() window.InitError!Platform {
        // Before any pipe exists: a clipboard write whose reader closed early
        // would otherwise end the process rather than answer EPIPE.
        wl_posix.ignoreBrokenPipe();

        const display = client.connect(null) orelse {
            std.log.err("wayland: no compositor on $WAYLAND_DISPLAY", .{});
            return error.PlatformUnavailable;
        };
        errdefer client.disconnect(display);

        const connection = allocator.create(Connection) catch return error.PlatformUnavailable;
        errdefer allocator.destroy(connection);

        const registry = display.getRegistry() catch return error.PlatformUnavailable;
        connection.* = .{ .display = display, .registry = registry };
        registry.setListener(*Connection, onRegistry, connection);

        // One round trip: the globals are advertised and bound inside it, and
        // nothing here waits on an event from a bound object.
        _ = client.roundtrip(display) catch return error.PlatformUnavailable;

        const wm_base = connection.wm_base orelse {
            std.log.err("wayland: the compositor advertises no xdg_wm_base", .{});
            return error.PlatformUnavailable;
        };
        if (connection.compositor == null) {
            std.log.err("wayland: the compositor advertises no wl_compositor", .{});
            return error.PlatformUnavailable;
        }
        wm_base.setListener(*Connection, onWmBase, connection);

        if (connection.seat_proxy) |proxy| {
            connection.seat = .init(connection, proxy);
            seat_module.listen(&connection.seat.?, allocator);

            // A second round trip: the capabilities that say whether there is a
            // keyboard and a pointer are an event from the object the first one
            // bound, so they cannot have arrived in it.
            _ = client.roundtrip(display) catch return error.PlatformUnavailable;
        } else {
            std.log.warn("wayland: the compositor advertises no wl_seat; there is no input", .{});
        }

        if (connection.fractional_scales == null or connection.viewporter == null) {
            // Both or neither: a fractional scale is only exact when a viewport
            // maps the pixel buffer back onto the logical rectangle.
            connection.fractional_scales = null;
            connection.viewporter = null;
            std.log.info(
                "wayland: no fractional scale support; falling back to integer buffer scale",
                .{},
            );
        }
        return .{ .connection = connection };
    }

    pub fn deinit(self: *Platform) void {
        const connection = self.connection;
        if (connection.seat) |*seat| seat.deinit();
        if (connection.cursor_shapes) |shapes| shapes.destroy();
        if (connection.relative_pointers) |relative| relative.destroy();
        if (connection.constraints) |constraints| constraints.destroy();
        if (connection.decorations) |decorations| decorations.destroy();
        if (connection.fractional_scales) |scales| scales.destroy();
        if (connection.viewporter) |viewporter| viewporter.destroy();
        if (connection.wm_base) |wm_base| wm_base.destroy();
        // A destructor request is itself versioned, and wl_compositor.release
        // only exists from version 7. Below it there is nothing to tell the
        // compositor and the proxy is simply dropped.
        if (connection.compositor) |compositor| {
            if (compositor.proxy().version() >= wl.Compositor.since.release)
                compositor.release()
            else
                compositor.proxy().destroy();
        }
        connection.registry.proxy().destroy();
        client.disconnect(connection.display);
        allocator.destroy(connection);
        self.* = undefined;
    }

    pub fn nativeDisplay(self: *Platform) window.NativeDisplay {
        return .{ .wayland = .{ .display = @ptrCast(self.connection.display) } };
    }

    pub fn createWindow(self: *Platform, options: window.WindowOptions) window.CreateWindowError!Window {
        const preferred = options.preferred;
        const connection = self.connection;
        const compositor = connection.compositor orelse return error.WindowCreationFailed;
        const wm_base = connection.wm_base orelse return error.WindowCreationFailed;

        const surface = compositor.createSurface() catch return error.WindowCreationFailed;
        errdefer surface.destroy();

        const xdg_surface = wm_base.getXdgSurface(surface) catch return error.WindowCreationFailed;
        errdefer xdg_surface.destroy();

        const toplevel = xdg_surface.getToplevel() catch return error.WindowCreationFailed;
        errdefer toplevel.destroy();

        toplevel.setTitle(options.title);
        toplevel.setAppId(options.app_id);

        const decoration = decorate(connection, toplevel);
        errdefer if (decoration) |d| d.destroy();

        // Created together or not at all, which init already guaranteed.
        const fractional_scale = if (connection.fractional_scales) |manager|
            manager.getFractionalScale(surface) catch null
        else
            null;
        errdefer if (fractional_scale) |scale| scale.destroy();

        const viewport = if (fractional_scale != null)
            if (connection.viewporter) |viewporter| viewporter.getViewport(surface) catch null else null
        else
            null;

        return .{
            .connection = connection,
            .surface = surface,
            .xdg_surface = xdg_surface,
            .toplevel = toplevel,
            .decoration = decoration,
            .viewport = viewport,
            .fractional_scale = fractional_scale,
            .preferred = preferred,
            .logical = preferred,
            .pending_logical = preferred,
        };
    }

    pub fn pollEvents(self: *Platform) void {
        self.pump(.{ .timeout = 0 });
    }

    pub fn waitEvents(self: *Platform) void {
        self.pump(.blocking);
    }

    pub fn waitEventsTimeout(self: *Platform, seconds: f64) void {
        // A non-positive or non-finite request is a drain, not a wait. NaN
        // compares false against everything and lands here too.
        if (!(seconds > 0)) return self.pollEvents();

        const requested = seconds * std.time.ns_per_s;
        const ceiling: f64 = @floatFromInt(std.time.ns_per_hour);
        self.pump(.{ .timeout = @intFromFloat(@min(requested, ceiling)) });
    }

    const Pump = union(enum) { blocking, timeout: u64 };

    fn pump(self: *Platform, mode: Pump) void {
        const connection = self.connection;
        if (connection.lost) return;

        // Requests are buffered until something sends them, and a dispatch that
        // blocks on an unsent commit would be waiting for an answer to a
        // question the compositor has not been asked.
        client.flush(connection.display) catch |err| switch (err) {
            // The compositor has not drained the socket. The requests stay
            // queued and the next flush sends them.
            error.WouldBlock => {},
            error.ConnectionLost => return connection.fail(),
        };

        // A key repeat is the one thing here that comes from the clock rather
        // than from the socket, so a wait that ignored it would swallow the
        // repeat for as long as the wait lasted.
        var wait: ?u64 = switch (mode) {
            .blocking => null,
            .timeout => |ns| ns,
        };
        if (connection.seat) |*seat| {
            if (seat.repeatWait()) |remaining| {
                wait = if (wait) |requested| @min(requested, remaining) else remaining;
            }
        }

        _ = (if (wait) |ns|
            client.dispatchTimeout(connection.display, ns)
        else
            client.dispatch(connection.display)) catch return connection.fail();

        if (connection.seat) |*seat| seat.deliverRepeats();
    }
};

fn decorate(connection: *Connection, toplevel: *xdg.Toplevel) ?*zxdg.ToplevelDecorationV1 {
    const manager = connection.decorations orelse {
        // Without the protocol the compositor expects the client to draw its
        // own frame. Nothing here draws one, so the window appears undecorated.
        return null;
    };
    const decoration = manager.getToplevelDecoration(toplevel) catch |err| {
        std.log.warn("wayland: cannot request a server-side decoration: {t}", .{err});
        return null;
    };
    decoration.setMode(.server_side);
    return decoration;
}

pub const Window = struct {
    connection: *Connection,

    surface: *wl.Surface,
    xdg_surface: *xdg.Surface,
    toplevel: *xdg.Toplevel,
    decoration: ?*zxdg.ToplevelDecorationV1,
    viewport: ?*wp_viewporter.Viewport,
    fractional_scale: ?*wp_fractional_scale.FractionalScaleV1,

    // Null until captureInput and again after releaseInput. Routing is switched
    // here rather than by detaching, because libwayland takes a proxy's
    // dispatcher once and there is no request to take it back.
    input: ?*Input = null,
    listening: bool = false,

    // Next window in the connection's list. Linked by captureInput, which is
    // also where this window's address stops moving.
    next: ?*Window = null,

    // What the caller asked for. A configure is free to leave the size to the
    // client, and this is the answer given when it does.
    preferred: Extent2D,

    // A configure sequence is a set of events that the xdg_surface.configure
    // closes, and the whole set is meant to be applied at once (xdg-shell.xml,
    // xdg_surface.configure). These accumulate it; the fields below hold what
    // was applied.
    pending_logical: Extent2D,
    pending_scale: u32 = scale_denominator,

    logical: Extent2D,
    scale: u32 = scale_denominator,

    configured: bool = false,
    closed: bool = false,

    pub fn deinit(self: *Window) void {
        self.connection.unregister(self);
        self.input = null;
        if (self.fractional_scale) |scale| scale.destroy();
        if (self.viewport) |viewport| viewport.destroy();
        if (self.decoration) |decoration| decoration.destroy();
        self.toplevel.destroy();
        self.xdg_surface.destroy();
        self.surface.destroy();
        self.* = undefined;
    }

    pub fn shouldClose(self: *Window) bool {
        return self.closed or self.connection.lost;
    }

    pub fn nativeHandles(self: *Window) window.NativeHandles {
        return .{ .wayland = .{
            .display = @ptrCast(self.connection.display),
            .surface = @ptrCast(self.surface),
        } };
    }

    pub fn captureInput(self: *Window, input: *Input) void {
        self.input = input;

        self.connection.register(self);

        if (!self.listening) {
            self.surface.setListener(*Window, onSurface, self);
            self.xdg_surface.setListener(*Window, onXdgSurface, self);
            self.toplevel.setListener(*Window, onToplevel, self);
            if (self.fractional_scale) |scale| scale.setListener(*Window, onFractionalScale, self);
            self.listening = true;

            // A surface with a role is configured in answer to a commit, and
            // this is the only commit this backend sends: everything after it
            // rides on the commit that presents a frame, so that a new size and
            // the buffer drawn for it are applied together.
            self.surface.commit();
            self.awaitConfigure();
        }

        self.submitMetrics();
    }

    pub fn releaseInput(self: *Window) void {
        self.input = null;
    }

    pub fn setCursorMode(self: *Window, mode: window.CursorMode) window.CursorModeError!void {
        const seat = if (self.connection.seat) |*value| value else return error.CursorModeUnavailable;
        return seat.setCursorMode(self, mode);
    }

    pub fn clipboardText(self: *Window, buffer: []u8) window.ClipboardError![]const u8 {
        const seat = if (self.connection.seat) |*value| value else return error.ClipboardUnavailable;
        return seat.clipboardText(buffer);
    }

    pub fn setClipboardText(self: *Window, text: [:0]const u8) void {
        const seat = if (self.connection.seat) |*value| value else return;
        seat.setClipboardText(text);
    }

    // The buffer the caller should render into. Rounded to the nearest pixel
    // and never zero: a swapchain cannot be made for an empty extent, and a
    // compositor is free to configure a size that scales down to nothing.
    fn framebufferExtent(self: *const Window) Extent2D {
        return .{
            .width = scalePixels(self.logical.width, self.scale),
            .height = scalePixels(self.logical.height, self.scale),
        };
    }

    fn submitMetrics(self: *Window) void {
        const input = self.input orelse return;
        const scale: f32 = @as(f32, @floatFromInt(self.scale)) / scale_denominator;
        input.submit(.{ .surface_metrics = .{
            .logical_size = .{
                @floatFromInt(self.logical.width),
                @floatFromInt(self.logical.height),
            },
            .framebuffer_extent = self.framebufferExtent(),
            .scale = .{ scale, scale },
            .generation = input.nextMetricsGeneration(),
        } });
    }

    fn awaitConfigure(self: *Window) void {
        var attempts: u32 = 0;
        while (!self.configured and !self.connection.lost and attempts < configure_round_trips) {
            attempts += 1;
            _ = client.roundtrip(self.connection.display) catch return self.connection.fail();
        }
        if (!self.configured and !self.connection.lost) {
            std.log.warn(
                "wayland: no configure after {d} round trips; using the requested {d}x{d}",
                .{ configure_round_trips, self.preferred.width, self.preferred.height },
            );
        }
    }

    // Latches what the configure sequence accumulated.
    //
    // `serial` is the xdg_surface.configure that closed the sequence, and is
    // absent when a scale arrived on its own. Nothing in the protocols promises
    // a configure after a scale change, so waiting for one would leave the
    // buffer at the old scale for as long as the window kept its size.
    fn applyPending(self: *Window, serial: ?u32) void {
        const changed = self.logical.width != self.pending_logical.width or
            self.logical.height != self.pending_logical.height or
            self.scale != self.pending_scale;

        self.logical = self.pending_logical;
        self.scale = self.pending_scale;

        // The viewport is what makes a fractional scale exact: the buffer is
        // whole pixels, and this maps it onto the logical rectangle the
        // compositor asked for. Double-buffered like the buffer it describes,
        // so it takes effect with the commit that presents the next frame.
        if (self.viewport) |viewport| viewport.setDestination(
            @intCast(self.logical.width),
            @intCast(self.logical.height),
        );

        if (serial) |configure| {
            self.xdg_surface.ackConfigure(configure);
            self.configured = true;
        }
        if (changed) self.submitMetrics();
    }
};

fn scalePixels(logical: u32, scale: u32) u32 {
    const scaled = (@as(u64, logical) * scale + scale_denominator / 2) / scale_denominator;
    return @intCast(@max(1, @min(scaled, std.math.maxInt(u32))));
}

fn onXdgSurface(_: *xdg.Surface, event: xdg.Surface.Event, self: *Window) void {
    switch (event) {
        .configure => |configure| self.applyPending(configure.serial),
    }
}

fn onToplevel(_: *xdg.Toplevel, event: xdg.Toplevel.Event, self: *Window) void {
    switch (event) {
        .configure => |configure| {
            // Zero means the compositor has no opinion and the client picks
            // (xdg-shell.xml, xdg_toplevel.configure). A negative width is not
            // in the protocol, and is read the same way rather than cast.
            self.pending_logical = .{
                .width = if (configure.width > 0) @intCast(configure.width) else self.preferred.width,
                .height = if (configure.height > 0) @intCast(configure.height) else self.preferred.height,
            };
        },
        .close => self.closed = true,
        // A size ceiling and the set of state changes the compositor supports.
        // Neither is acted on: nothing here asks to be maximized or fullscreen,
        // and the configure above is already the size that has to be honoured.
        .configure_bounds, .wm_capabilities => {},
    }
}

fn onFractionalScale(
    _: *wp_fractional_scale.FractionalScaleV1,
    event: wp_fractional_scale.FractionalScaleV1.Event,
    self: *Window,
) void {
    switch (event) {
        .preferred_scale => |preferred| {
            if (preferred.scale == 0) {
                std.log.warn("wayland: the compositor sent a zero fractional scale; ignored", .{});
                return;
            }
            self.pending_scale = preferred.scale;

            // Before the first configure there is one on the way to latch this
            // with whatever size comes alongside it. After it, this is the only
            // event that will say so.
            if (self.configured) self.applyPending(null);
        },
    }
}

fn onSurface(_: *wl.Surface, event: wl.Surface.Event, self: *Window) void {
    switch (event) {
        .preferred_buffer_scale => |preferred| {
            // The integer path. When a fractional scale is in use it is the
            // more precise answer to the same question, and this one is the
            // compositor rounding it for clients that cannot do better.
            if (self.fractional_scale != null) return;
            if (preferred.factor <= 0) return;

            self.pending_scale = @as(u32, @intCast(preferred.factor)) * scale_denominator;

            // Without a viewport this is what tells the compositor how many
            // pixels of buffer cover one logical unit. Surface state like the
            // viewport destination, so it lands with the next presented frame.
            self.surface.setBufferScale(preferred.factor);
            if (self.configured) self.applyPending(null);
        },
        // Which outputs the surface is shown on, and how one of them is
        // rotated. The engine renders unrotated into whatever extent the
        // configure asked for, and picks no output of its own.
        .enter, .leave, .preferred_buffer_transform => {},
    }
}
