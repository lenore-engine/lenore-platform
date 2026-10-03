const std = @import("std");
const events = @import("../../../events.zig");
const window_contract = @import("../../../window.zig");
const Input = @import("../../../input.zig").Input;

const client = @import("client.zig");
const wl = @import("protocol/wayland.zig");
const zwp_constraints = @import("protocol/pointer_constraints_unstable_v1.zig");
const zwp_relative = @import("protocol/relative_pointer_unstable_v1.zig");
const wp_cursor = @import("protocol/cursor_shape_v1.zig");
const clipboard_module = @import("clipboard.zig");
const keycodes = @import("keycodes.zig");
const posix = @import("posix.zig");
const xkb = @import("xkb.zig");
const Wayland = @import("../Wayland.zig");

// The seat: everything a person operates.
//
// One seat is bound. The protocol allows several, and a second would be a
// second keyboard focus and a second pointer sharing one event queue, which the
// Input contract has no room for: its events carry a DeviceId but the polled
// state behind them is single. Binding one is the honest shape of that.
//
// Events are routed by surface. A seat belongs to the connection rather than to
// a window, and the focus events are what say which window's Input a key or a
// motion belongs to.

// wl_pointer.axis is in the coordinate space of motion events (wayland.xml,
// wl_pointer.axis), where y grows downwards. ScrollEvent is signed the other
// way round, so both axes are negated here.
const scroll_sign = -1.0;

// Wheel steps arrive as 120ths of a step (wayland.xml,
// wl_pointer.axis_value120).
const clicks_per_unit = 120.0;

pub const Seat = struct {
    connection: *Wayland.Connection,
    seat: *wl.Seat,

    keyboard: ?*wl.Keyboard = null,
    pointer: ?*wl.Pointer = null,
    cursor_shape: ?*wp_cursor.CursorShapeDeviceV1 = null,

    xkb: ?xkb.Keyboard = null,
    modifiers: events.Modifiers = .{},

    keyboard_focus: ?*Wayland.Window = null,
    pointer_focus: ?*Wayland.Window = null,

    // The last serial the compositor attached to a pointer enter. Every request
    // that changes the cursor has to quote one, so it is kept rather than
    // recomputed.
    enter_serial: u32 = 0,

    clipboard: ?clipboard_module.Clipboard = null,

    // The most recent serial the compositor attached to any input event on this
    // seat. Taking the selection requires one: it is how a compositor tells a
    // program the user was working in from one that was not.
    input_serial: u32 = 0,

    frame: Frame = .{},
    repeat: Repeat = .{},

    mode: window_contract.CursorMode = .normal,
    locked: ?*zwp_constraints.LockedPointerV1 = null,
    relative: ?*zwp_relative.RelativePointerV1 = null,

    pub fn init(connection: *Wayland.Connection, seat: *wl.Seat) Seat {
        return .{ .connection = connection, .seat = seat };
    }

    pub fn deinit(self: *Seat) void {
        if (self.clipboard) |*clipboard| clipboard.deinit();
        self.releaseConstraint();
        if (self.cursor_shape) |shape| shape.destroy();
        if (self.pointer) |pointer| release(pointer, wl.Pointer.since.release);
        if (self.keyboard) |keyboard| release(keyboard, wl.Keyboard.since.release);
        if (self.xkb) |*keyboard| keyboard.deinit();
        release(self.seat, wl.Seat.since.release);
        self.* = undefined;
    }

    // Called when a window goes away, so that focus never names freed memory.
    pub fn forget(self: *Seat, target: *Wayland.Window) void {
        if (self.keyboard_focus == target) self.keyboard_focus = null;
        if (self.pointer_focus == target) {
            self.pointer_focus = null;
            self.releaseConstraint();
            self.mode = .normal;
        }
        if (self.repeat.window == target) self.repeat.armed = false;
    }

    pub fn setCursorMode(
        self: *Seat,
        target: *Wayland.Window,
        mode: window_contract.CursorMode,
    ) window_contract.CursorModeError!void {
        const pointer = self.pointer orelse return error.CursorModeUnavailable;

        if (mode == .normal) {
            self.releaseConstraint();
            self.mode = .normal;
            self.applyCursor();
            return;
        }

        const constraints = self.connection.constraints orelse return error.CursorModeUnavailable;
        const relative_pointers = self.connection.relative_pointers orelse
            return error.CursorModeUnavailable;
        if (self.mode == .disabled) return;

        // Persistent rather than oneshot: a lock that ended the first time the
        // compositor took focus away would hand the cursor back mid-game and
        // never take it again.
        const locked = constraints.lockPointer(
            target.surface,
            pointer,
            null,
            .persistent,
        ) catch return error.CursorModeUnavailable;
        const relative = relative_pointers.getRelativePointer(pointer) catch {
            locked.destroy();
            return error.CursorModeUnavailable;
        };
        relative.setListener(*Seat, onRelativePointer, self);

        self.locked = locked;
        self.relative = relative;
        self.mode = .disabled;
        self.applyCursor();
    }

    pub fn clipboardText(
        self: *Seat,
        buffer: []u8,
    ) window_contract.ClipboardError![]const u8 {
        const clipboard = if (self.clipboard) |*value| value else return error.ClipboardUnavailable;
        return clipboard.text(buffer);
    }

    pub fn setClipboardText(self: *Seat, text: [:0]const u8) void {
        const clipboard = if (self.clipboard) |*value| value else return;
        clipboard.setText(text, self.input_serial);
    }

    fn releaseConstraint(self: *Seat) void {
        if (self.relative) |relative| relative.proxy().destroy();
        if (self.locked) |locked| locked.destroy();
        self.relative = null;
        self.locked = null;
    }

    // Draws the cursor the current mode asks for. A hidden cursor is an empty
    // surface rather than a shape, which is the only way the protocol has of
    // saying "none" (wayland.xml, wl_pointer.set_cursor).
    fn applyCursor(self: *Seat) void {
        const pointer = self.pointer orelse return;
        if (self.pointer_focus == null) return;

        if (self.mode == .disabled) {
            pointer.setCursor(self.enter_serial, null, 0, 0);
            return;
        }
        if (self.cursor_shape) |shape| shape.setShape(self.enter_serial, .default);
    }

    fn inputOf(target: ?*Wayland.Window) ?*Input {
        const found = target orelse return null;
        return found.input;
    }

    // Capabilities
    // ============

    fn onSeat(_: *wl.Seat, event: wl.Seat.Event, self: *Seat) void {
        switch (event) {
            .capabilities => |capabilities| self.applyCapabilities(capabilities.capabilities),
            // A human-readable seat name. Nothing routes by it.
            .name => {},
        }
    }

    fn applyCapabilities(self: *Seat, capabilities: u32) void {
        const has_pointer = capabilities & @backingInt(wl.Seat.Capability.pointer) != 0;
        const has_keyboard = capabilities & @backingInt(wl.Seat.Capability.keyboard) != 0;

        if (has_pointer and self.pointer == null) self.openPointer();
        if (!has_pointer and self.pointer != null) self.closePointer();
        if (has_keyboard and self.keyboard == null) self.openKeyboard();
        if (!has_keyboard and self.keyboard != null) self.closeKeyboard();

        // Capabilities change while the program runs, so this is not an
        // initialization line. It is the first thing to look at when input does
        // not arrive, which is why it says what the seat ended up with rather
        // than what it was told.
        std.log.info("wayland: seat has pointer {}, keyboard {}, cursor shapes {}", .{
            self.pointer != null,
            self.keyboard != null,
            self.cursor_shape != null,
        });
    }

    fn openPointer(self: *Seat) void {
        const pointer = self.seat.getPointer() catch |err| {
            std.log.warn("wayland: cannot open the seat's pointer: {t}", .{err});
            return;
        };
        pointer.setListener(*Seat, onPointer, self);
        self.pointer = pointer;

        // Without this protocol the client would have to draw a cursor from a
        // theme through wl_shm. Nothing here does, so the compositor keeps
        // whatever cursor it had when the pointer entered.
        if (self.connection.cursor_shapes) |manager| {
            self.cursor_shape = manager.getPointer(pointer) catch |err| {
                std.log.warn("wayland: cannot request a cursor shape: {t}", .{err});
                return;
            };
        }
    }

    fn closePointer(self: *Seat) void {
        self.releaseConstraint();
        self.mode = .normal;
        if (self.cursor_shape) |shape| shape.destroy();
        if (self.pointer) |pointer| release(pointer, wl.Pointer.since.release);
        self.cursor_shape = null;
        self.pointer = null;
        self.pointer_focus = null;
    }

    fn openKeyboard(self: *Seat) void {
        const keyboard = self.seat.getKeyboard() catch |err| {
            std.log.warn("wayland: cannot open the seat's keyboard: {t}", .{err});
            return;
        };
        keyboard.setListener(*Seat, onKeyboard, self);
        self.keyboard = keyboard;
        self.xkb = xkb.Keyboard.init();
    }

    fn closeKeyboard(self: *Seat) void {
        self.repeat.armed = false;
        if (self.keyboard) |keyboard| release(keyboard, wl.Keyboard.since.release);
        if (self.xkb) |*keyboard| keyboard.deinit();
        self.keyboard = null;
        self.xkb = null;
        self.keyboard_focus = null;
    }

    // Pointer
    // =======

    const Frame = struct {
        pixel: [2]f32 = .{ 0, 0 },
        line: [2]f32 = .{ 0, 0 },
        source: events.ScrollSource = .unknown,
        phase: events.ScrollPhase = .update,
        pending: bool = false,

        fn clear(self: *Frame) void {
            self.* = .{};
        }
    };

    fn onPointer(pointer: *wl.Pointer, event: wl.Pointer.Event, self: *Seat) void {
        switch (event) {
            .enter => |enter| {
                self.enter_serial = enter.serial;
                self.input_serial = enter.serial;
                self.pointer_focus = self.connection.windowOf(enter.surface);
                self.applyCursor();
                self.reportCursor(enter.surface_x, enter.surface_y);
            },
            .leave => {
                self.pointer_focus = null;
                self.frame.clear();
            },
            .motion => |motion| {
                // A locked pointer reports nothing here: the position does not
                // move, and the relative pointer is what carries the movement.
                if (self.mode == .disabled) return;
                self.reportCursor(motion.surface_x, motion.surface_y);
            },
            .button => |button| {
                self.input_serial = button.serial;
                self.reportButton(button.button, button.state);
            },
            .axis => |axis| {
                self.accumulate(axis.axis, axis.value.toFloat() * scroll_sign, null);
                // wl_pointer.frame groups an axis with the events that qualify
                // it, and only exists from version 5. Below that each axis is
                // its own scroll.
                if (pointer.proxy().version() < 5) self.flushFrame();
            },
            .axis_value120 => |axis| self.accumulate(
                axis.axis,
                null,
                @as(f32, @floatFromInt(axis.value120)) / clicks_per_unit * scroll_sign,
            ),
            .axis_source => |source| self.frame.source = scrollSource(source.axis_source),
            .axis_stop => {
                self.frame.phase = .end;
                self.frame.pending = true;
            },
            .frame => self.flushFrame(),
            // axis_discrete is what axis_value120 replaced, and a compositor
            // that sends the new one must not send the old. warp and
            // axis_relative_direction describe movement the value already
            // reflects.
            .axis_discrete, .axis_relative_direction, .warp => {},
        }
    }

    fn reportCursor(self: *Seat, x: client.Fixed, y: client.Fixed) void {
        const input = inputOf(self.pointer_focus) orelse return;
        input.last_cursor = .{ x.toFloat(), y.toFloat() };
        input.submit(.{ .cursor = .{
            .logical_position = input.last_cursor,
            .metrics_generation = input.metrics_generation,
        } });
    }

    fn reportButton(self: *Seat, code: u32, state: u32) void {
        const input = inputOf(self.pointer_focus) orelse return;
        input.submit(.{ .mouse_button = .{
            .button = keycodes.mouseButton(code),
            .action = if (state == @backingInt(wl.Pointer.ButtonState.pressed))
                .press
            else
                .release,
            .modifiers = self.modifiers,
            .logical_position = input.last_cursor,
            .metrics_generation = input.metrics_generation,
        } });
    }

    fn accumulate(self: *Seat, axis: u32, pixels: ?f32, lines: ?f32) void {
        const index: usize = if (axis == @backingInt(wl.Pointer.Axis.horizontal_scroll)) 0 else 1;
        if (pixels) |value| self.frame.pixel[index] += value;
        if (lines) |value| self.frame.line[index] += value;
        self.frame.pending = true;
    }

    fn flushFrame(self: *Seat) void {
        defer self.frame.clear();
        if (!self.frame.pending) return;

        const input = inputOf(self.pointer_focus) orelse return;
        input.submit(.{ .scroll = .{
            .pixel_delta = self.frame.pixel,
            .line_delta = self.frame.line,
            .phase = self.frame.phase,
            .source = self.frame.source,
        } });
    }

    fn onRelativePointer(
        _: *zwp_relative.RelativePointerV1,
        event: zwp_relative.RelativePointerV1.Event,
        self: *Seat,
    ) void {
        switch (event) {
            .relative_motion => |motion| {
                const input = inputOf(self.pointer_focus) orelse return;

                // Unaccelerated: the delta before the compositor applies its
                // device- and configuration-specific acceleration
                // (relative-pointer-unstable-v1.xml, relative_motion), so a
                // camera turns with the hand rather than with the desktop's
                // pointer settings.
                //
                // The position is deliberately unbounded here. A disabled
                // cursor is pointer capture, and a consumer reads the
                // difference between frames rather than the value.
                input.last_cursor = .{
                    input.last_cursor[0] + motion.dx_unaccel.toFloat(),
                    input.last_cursor[1] + motion.dy_unaccel.toFloat(),
                };
                input.submit(.{ .cursor = .{
                    .logical_position = input.last_cursor,
                    .metrics_generation = input.metrics_generation,
                } });
            },
        }
    }

    // Keyboard
    // ========

    const Repeat = struct {
        // Zero disables repetition altogether, which is also how a compositor
        // says it will send the repeats itself (wayland.xml,
        // wl_keyboard.key_state.repeated).
        interval_ns: u64 = 0,
        delay_ns: u64 = 0,

        key: u32 = 0,
        physical: events.PhysicalKey = .unknown,
        window: ?*Wayland.Window = null,
        due_ns: u64 = 0,
        armed: bool = false,
    };

    // How long a caller may wait for events before a repeat comes due. Null
    // means nothing is waiting on the clock and the wait can be as long as it
    // likes.
    pub fn repeatWait(self: *const Seat) ?u64 {
        if (!self.repeat.armed) return null;
        const target = self.repeat.window orelse return null;
        const input = target.input orelse return null;

        const now = input.clock.now();
        return if (now >= self.repeat.due_ns) 0 else self.repeat.due_ns - now;
    }

    // Emits every repeat that has come due. Called after a pump, so that a
    // repeat is delivered in the same batch as the events around it.
    pub fn deliverRepeats(self: *Seat) void {
        if (!self.repeat.armed) return;
        const target = self.repeat.window orelse return;
        const input = target.input orelse return;

        var now = input.clock.now();
        while (now >= self.repeat.due_ns) {
            self.submitKey(input, self.repeat.key, self.repeat.physical, .repeat);

            // Stepping by the interval rather than from now keeps the rate
            // steady across a late wake-up, and the max stops a long stall from
            // producing a burst of every repeat it slept through.
            self.repeat.due_ns = @max(self.repeat.due_ns + self.repeat.interval_ns, now);
            now = input.clock.now();
        }
    }

    fn onKeyboard(_: *wl.Keyboard, event: wl.Keyboard.Event, self: *Seat) void {
        switch (event) {
            .keymap => |keymap| self.loadKeymap(keymap.format, keymap.fd, keymap.size),
            .enter => |enter| {
                self.input_serial = enter.serial;
                self.keyboard_focus = self.connection.windowOf(enter.surface);
                if (inputOf(self.keyboard_focus)) |input|
                    input.submit(.{ .focus = .{ .focused = true } });
            },
            .leave => {
                // Held keys are not released one by one: InputState clears the
                // pressed sets when focus is lost.
                if (inputOf(self.keyboard_focus)) |input|
                    input.submit(.{ .focus = .{ .focused = false } });
                self.keyboard_focus = null;
                self.repeat.armed = false;
            },
            .key => |key| {
                self.input_serial = key.serial;
                self.reportKey(key.key, key.state);
            },
            .modifiers => |modifiers| {
                const keyboard = if (self.xkb) |*value| value else return;
                keyboard.updateModifiers(
                    modifiers.mods_depressed,
                    modifiers.mods_latched,
                    modifiers.mods_locked,
                    modifiers.group,
                );
                self.modifiers = keyboard.modifiers();
            },
            .repeat_info => |info| {
                // Negative values are illegal in the protocol and are read as
                // "no repetition" rather than trusted into the arithmetic below.
                if (info.rate <= 0 or info.delay < 0) {
                    self.repeat.interval_ns = 0;
                    self.repeat.armed = false;
                    return;
                }
                self.repeat.interval_ns = std.time.ns_per_s / @as(u64, @intCast(info.rate));
                self.repeat.delay_ns = @as(u64, @intCast(info.delay)) * std.time.ns_per_ms;
            },
        }
    }

    fn loadKeymap(self: *Seat, format: u32, fd: i32, size: u32) void {
        const keyboard = if (self.xkb) |*value| value else {
            _ = posix.close(fd);
            return;
        };
        if (format != @backingInt(wl.Keyboard.KeymapFormat.xkb_v1)) {
            std.log.err("wayland: the compositor sent keymap format {d}, not xkb_v1", .{format});
            _ = posix.close(fd);
            return;
        }

        _ = keyboard.setKeymapFd(fd, size);
        self.modifiers = keyboard.modifiers();
    }

    fn reportKey(self: *Seat, key: u32, state: u32) void {
        const input = inputOf(self.keyboard_focus) orelse return;
        const physical = keycodes.physicalKey(key);

        const action: events.KeyAction = switch (state) {
            @backingInt(wl.Keyboard.KeyState.released) => .release,
            @backingInt(wl.Keyboard.KeyState.repeated) => .repeat,
            else => .press,
        };

        self.submitKey(input, key, physical, action);

        switch (action) {
            .press => self.arm(key, physical),
            .release => if (self.repeat.armed and self.repeat.key == key) {
                self.repeat.armed = false;
            },
            // A compositor sending its own repeats is one that asked for no
            // client-side repetition, so there is no timer to disturb.
            .repeat => {},
        }
    }

    fn submitKey(
        self: *Seat,
        input: *Input,
        key: u32,
        physical: events.PhysicalKey,
        action: events.KeyAction,
    ) void {
        input.submit(.{ .key = .{
            .physical = physical,
            .logical = keycodes.namedKey(physical),
            .action = action,
            .modifiers = self.modifiers,
        } });
        if (action == .release) return;

        const keyboard = if (self.xkb) |*value| value else return;
        var buffer: [32]u8 = undefined;
        const utf8 = keyboard.text(xkb.Keyboard.keycode(key), &buffer);
        if (utf8.len == 0) return;

        // TextChunk carries 16 bytes. Anything longer is a compose sequence
        // that produced more than one grapheme cluster, which this contract has
        // no way to deliver and drops whole rather than in half.
        if (utf8.len > @typeInfo(@FieldType(events.TextChunk, "bytes")).array.len) {
            std.log.warn("wayland: dropped {d} bytes of composed text", .{utf8.len});
            return;
        }

        var chunk: events.TextChunk = .{
            .transaction = input.nextTextTransaction(),
            .kind = .commit,
            .begin = true,
            .end = true,
            .len = @intCast(utf8.len),
            .bytes = @splat(0),
        };
        @memcpy(chunk.bytes[0..utf8.len], utf8);
        input.submit(.{ .text = chunk });
    }

    fn arm(self: *Seat, key: u32, physical: events.PhysicalKey) void {
        self.repeat.armed = false;
        if (self.repeat.interval_ns == 0) return;

        const keyboard = if (self.xkb) |*value| value else return;
        if (!keyboard.repeats(xkb.Keyboard.keycode(key))) return;

        const target = self.keyboard_focus orelse return;
        const input = target.input orelse return;

        self.repeat = .{
            .interval_ns = self.repeat.interval_ns,
            .delay_ns = self.repeat.delay_ns,
            .key = key,
            .physical = physical,
            .window = target,
            .due_ns = input.clock.now() + self.repeat.delay_ns,
            .armed = true,
        };
    }
};

// Attaches the listeners that need the seat at the address it will keep, which
// is inside the connection. Separate from init for exactly that reason.
pub fn listen(self: *Seat, allocator: std.mem.Allocator) void {
    self.seat.setListener(*Seat, Seat.onSeat, self);

    const manager = self.connection.data_devices orelse {
        std.log.info("wayland: the compositor advertises no wl_data_device_manager; " ++
            "there is no clipboard", .{});
        return;
    };
    self.clipboard = .init(self.connection.display, manager, self.seat, allocator);
    if (self.clipboard) |*clipboard| clipboard.listen();
}

// Releases an input object, or drops it when the bound version has no such
// request. wl_seat.release arrived in version 5 and the two device releases in
// version 3, so a compositor offering less than that gets no notice.
fn release(object: anytype, comptime since: u32) void {
    const proxy = object.proxy();
    if (proxy.version() >= since) object.release() else proxy.destroy();
}

fn scrollSource(source: u32) events.ScrollSource {
    return switch (source) {
        @backingInt(wl.Pointer.AxisSource.wheel) => .wheel,
        @backingInt(wl.Pointer.AxisSource.finger) => .finger,
        @backingInt(wl.Pointer.AxisSource.continuous) => .continuous,
        // wheel_tilt is a wheel pushed sideways, which reaches the contract as
        // a horizontal wheel and has no source of its own.
        @backingInt(wl.Pointer.AxisSource.wheel_tilt) => .wheel,
        else => .unknown,
    };
}
