//! Temporary glfw backend. It is deleted whole when the native backends land,
//! so nothing here is load-bearing for the contract.

const std = @import("std");
const glfw = @import("zglfw");
const window = @import("../window.zig");
const events = @import("../events.zig");
const Input = @import("../input.zig").Input;
const Extent2D = @import("../types.zig").Extent2D;

pub const Platform = struct {
    pub fn init() window.InitError!Platform {
        glfw.init() catch return error.PlatformUnavailable;
        return .{};
    }

    pub fn deinit(_: *Platform) void {
        glfw.terminate();
    }

    pub fn createWindow(
        _: *Platform,
        preferred: Extent2D,
        title: [:0]const u8,
    ) window.CreateWindowError!Window {
        glfw.windowHint(.client_api, .no_api);
        const handle = glfw.createWindow(
            @intCast(preferred.width),
            @intCast(preferred.height),
            title,
            null,
            null,
        ) catch return error.WindowCreationFailed;
        return .{ .handle = handle };
    }

    pub fn pollEvents(_: *Platform) void {
        glfw.pollEvents();
    }

    pub fn waitEvents(_: *Platform) void {
        glfw.waitEvents();
    }

    pub fn waitEventsTimeout(_: *Platform, seconds: f64) void {
        glfw.waitEventsTimeout(seconds);
    }
};

pub const Window = struct {
    handle: *glfw.Window,
    captured: bool = false,

    pub fn deinit(self: *Window) void {
        self.releaseInput();
        glfw.destroyWindow(self.handle);
    }

    pub fn shouldClose(self: *Window) bool {
        return glfw.windowShouldClose(self.handle);
    }

    pub fn nativeHandles(self: *Window) window.NativeHandles {
        return .{ .wayland = .{
            .display = glfw.getWaylandDisplay().?,
            .surface = glfw.getWaylandWindow(self.handle).?,
        } };
    }

    pub fn setCursorMode(self: *Window, mode: window.CursorMode) window.CursorModeError!void {
        const raw = glfw.rawMouseMotionSupported();
        switch (mode) {
            .normal => {
                if (raw) glfw.setInputMode(self.handle, .raw_mouse_motion, false) catch
                    return error.CursorModeUnavailable;
                glfw.setInputMode(self.handle, .cursor, .normal) catch
                    return error.CursorModeUnavailable;
            },
            .disabled => {
                glfw.setInputMode(self.handle, .cursor, .disabled) catch
                    return error.CursorModeUnavailable;
                if (raw) glfw.setInputMode(self.handle, .raw_mouse_motion, true) catch
                    return error.CursorModeUnavailable;
            },
        }
    }

    pub fn captureInput(self: *Window, input: *Input) void {
        if (self.captured) return;
        glfw.setWindowUserPointer(self.handle, input);
        _ = glfw.setKeyCallback(self.handle, keyCallback);
        _ = glfw.setCharCallback(self.handle, charCallback);
        _ = glfw.setCursorPosCallback(self.handle, cursorCallback);
        _ = glfw.setMouseButtonCallback(self.handle, mouseButtonCallback);
        _ = glfw.setScrollCallback(self.handle, scrollCallback);
        _ = glfw.setWindowFocusCallback(self.handle, focusCallback);
        _ = glfw.setWindowSizeCallback(self.handle, sizeCallback);
        _ = glfw.setFramebufferSizeCallback(self.handle, framebufferCallback);
        _ = glfw.setWindowContentScaleCallback(self.handle, scaleCallback);
        self.captured = true;
        submitMetrics(self.handle, input);
    }

    pub fn releaseInput(self: *Window) void {
        if (!self.captured) return;
        _ = glfw.setKeyCallback(self.handle, null);
        _ = glfw.setCharCallback(self.handle, null);
        _ = glfw.setCursorPosCallback(self.handle, null);
        _ = glfw.setMouseButtonCallback(self.handle, null);
        _ = glfw.setScrollCallback(self.handle, null);
        _ = glfw.setWindowFocusCallback(self.handle, null);
        _ = glfw.setWindowSizeCallback(self.handle, null);
        _ = glfw.setFramebufferSizeCallback(self.handle, null);
        _ = glfw.setWindowContentScaleCallback(self.handle, null);
        glfw.setWindowUserPointer(self.handle, null);
        self.captured = false;
    }
};

fn inputOf(handle: *glfw.Window) ?*Input {
    return glfw.getWindowUserPointer(handle, Input);
}

fn submitMetrics(handle: *glfw.Window, input: *Input) void {
    const logical = handle.getSize();
    const framebuffer = handle.getFramebufferSize();
    const scale = handle.getContentScale();
    if (logical[0] < 0 or logical[1] < 0 or framebuffer[0] < 0 or framebuffer[1] < 0 or
        !std.math.isFinite(scale[0]) or !std.math.isFinite(scale[1]) or
        scale[0] <= 0 or scale[1] <= 0)
    {
        std.log.err("glfw produced invalid surface metrics", .{});
        return;
    }
    input.submit(.{ .surface_metrics = .{
        .logical_size = .{ @floatFromInt(logical[0]), @floatFromInt(logical[1]) },
        .framebuffer_extent = .{
            .width = @intCast(framebuffer[0]),
            .height = @intCast(framebuffer[1]),
        },
        .scale = scale,
        .generation = input.nextMetricsGeneration(),
    } });
}

fn keyCallback(
    handle: *glfw.Window,
    key: glfw.Key,
    _: c_int,
    action: glfw.Action,
    mods: glfw.Mods,
) callconv(.c) void {
    const input = inputOf(handle) orelse return;
    input.submit(.{ .key = .{
        .physical = physicalKey(key),
        .logical = namedKey(key),
        .action = keyAction(action),
        .modifiers = modifiers(mods),
    } });
}

fn charCallback(handle: *glfw.Window, codepoint: u32) callconv(.c) void {
    const input = inputOf(handle) orelse return;
    if (codepoint > std.math.maxInt(u21)) {
        std.log.warn("glfw produced an invalid codepoint {d}; chunk dropped", .{codepoint});
        return;
    }
    var bytes: [16]u8 = @splat(0);
    const len = std.unicode.utf8Encode(@intCast(codepoint), &bytes) catch {
        std.log.warn("glfw produced a surrogate codepoint {d}; chunk dropped", .{codepoint});
        return;
    };
    input.submit(.{ .text = .{
        .transaction = input.nextTextTransaction(),
        .kind = .commit,
        .begin = true,
        .end = true,
        .len = len,
        .bytes = bytes,
    } });
}

fn cursorCallback(handle: *glfw.Window, x: f64, y: f64) callconv(.c) void {
    const input = inputOf(handle) orelse return;
    // Safe to drop: a position is absolute and idempotent, so the next finite
    // report restores the truth.
    if (!std.math.isFinite(x) or !std.math.isFinite(y)) return;
    input.last_cursor = .{ @floatCast(x), @floatCast(y) };
    input.submit(.{ .cursor = .{
        .logical_position = input.last_cursor,
        .metrics_generation = input.metrics_generation,
    } });
}

fn mouseButtonCallback(
    handle: *glfw.Window,
    button: glfw.MouseButton,
    action: glfw.Action,
    mods: glfw.Mods,
) callconv(.c) void {
    const input = inputOf(handle) orelse return;
    // Degrading to the last finite position gives consumers what they already
    // saw. Dropping the event would leave a press held forever.
    const raw = handle.getCursorPos();
    if (std.math.isFinite(raw[0]) and std.math.isFinite(raw[1]))
        input.last_cursor = .{ @floatCast(raw[0]), @floatCast(raw[1]) };
    input.submit(.{ .mouse_button = .{
        .button = mouseButton(button),
        .action = keyAction(action),
        .modifiers = modifiers(mods),
        .logical_position = input.last_cursor,
        .metrics_generation = input.metrics_generation,
    } });
}

fn scrollCallback(handle: *glfw.Window, xoffset: f64, yoffset: f64) callconv(.c) void {
    const input = inputOf(handle) orelse return;
    input.submit(.{ .scroll = .{
        .line_delta = .{ @floatCast(xoffset), @floatCast(yoffset) },
        .phase = .update,
        .source = .wheel,
    } });
}

fn focusCallback(handle: *glfw.Window, focused: glfw.Bool) callconv(.c) void {
    const input = inputOf(handle) orelse return;
    input.submit(.{ .focus = .{ .focused = focused == glfw.TRUE } });
}

fn sizeCallback(handle: *glfw.Window, _: c_int, _: c_int) callconv(.c) void {
    const input = inputOf(handle) orelse return;
    submitMetrics(handle, input);
}

fn framebufferCallback(handle: *glfw.Window, _: c_int, _: c_int) callconv(.c) void {
    const input = inputOf(handle) orelse return;
    submitMetrics(handle, input);
}

fn scaleCallback(handle: *glfw.Window, _: f32, _: f32) callconv(.c) void {
    const input = inputOf(handle) orelse return;
    submitMetrics(handle, input);
}

fn keyAction(action: glfw.Action) events.KeyAction {
    return switch (action) {
        .press => .press,
        .repeat => .repeat,
        .release => .release,
    };
}

fn mouseButton(button: glfw.MouseButton) events.MouseButton {
    return switch (button) {
        .left => .left,
        .right => .right,
        .middle => .middle,
        .four => .back,
        .five => .forward,
        else => .other,
    };
}

fn modifiers(value: glfw.Mods) events.Modifiers {
    return .{
        .shift = value.shift,
        .control = value.control,
        .alt = value.alt,
        .super = value.super,
        .caps_lock = value.caps_lock,
        .num_lock = value.num_lock,
    };
}

comptime {
    assertRun(.a, .z, .a);
    assertRun(.zero, .nine, .digit_0);
    assertRun(.F1, .F25, .f1);
    assertRun(.kp_0, .kp_9, .numpad_0);
}

// physicalKey maps these runs by index arithmetic, so both sides must be
// contiguous and equally ordered. Either @enumFromInt fails to compile on a hole.
fn assertRun(comptime first: glfw.Key, comptime last: glfw.Key, comptime target: events.PhysicalKey) void {
    const count: usize = @intCast(@intFromEnum(last) - @intFromEnum(first) + 1);
    for (0..count) |i| {
        _ = @as(glfw.Key, @enumFromInt(@intFromEnum(first) + @as(c_int, @intCast(i))));
        _ = @as(events.PhysicalKey, @enumFromInt(@intFromEnum(target) + i));
    }
}

pub fn physicalKey(key: glfw.Key) events.PhysicalKey {
    const value = @intFromEnum(key);
    if (value >= @intFromEnum(glfw.Key.a) and value <= @intFromEnum(glfw.Key.z))
        return @enumFromInt(@intFromEnum(events.PhysicalKey.a) + value - @intFromEnum(glfw.Key.a));
    if (value >= @intFromEnum(glfw.Key.zero) and value <= @intFromEnum(glfw.Key.nine))
        return @enumFromInt(@intFromEnum(events.PhysicalKey.digit_0) + value - @intFromEnum(glfw.Key.zero));
    if (value >= @intFromEnum(glfw.Key.F1) and value <= @intFromEnum(glfw.Key.F25))
        return @enumFromInt(@intFromEnum(events.PhysicalKey.f1) + value - @intFromEnum(glfw.Key.F1));
    if (value >= @intFromEnum(glfw.Key.kp_0) and value <= @intFromEnum(glfw.Key.kp_9))
        return @enumFromInt(@intFromEnum(events.PhysicalKey.numpad_0) + value - @intFromEnum(glfw.Key.kp_0));

    return switch (key) {
        .space => .space,
        .apostrophe => .apostrophe,
        .comma => .comma,
        .minus => .minus,
        .period => .period,
        .slash => .slash,
        .semicolon => .semicolon,
        .equal => .equal,
        .left_bracket => .left_bracket,
        .backslash => .backslash,
        .right_bracket => .right_bracket,
        .grave_accent => .grave,
        .escape => .escape,
        .enter => .enter,
        .tab => .tab,
        .backspace => .backspace,
        .insert => .insert,
        .delete => .delete,
        .right => .arrow_right,
        .left => .arrow_left,
        .down => .arrow_down,
        .up => .arrow_up,

        .page_up => .page_up,
        .page_down => .page_down,
        .home => .home,
        .end => .end,
        .caps_lock => .caps_lock,
        .scroll_lock => .scroll_lock,
        .num_lock => .num_lock,
        .print_screen => .print_screen,
        .pause => .pause,
        .kp_decimal => .numpad_decimal,
        .kp_divide => .numpad_divide,
        .kp_multiply => .numpad_multiply,
        .kp_subtract => .numpad_subtract,
        .kp_add => .numpad_add,
        .kp_enter => .numpad_enter,
        .kp_equal => .numpad_equal,
        .left_shift => .shift_left,
        .left_control => .control_left,
        .left_alt => .alt_left,
        .left_super => .super_left,

        .right_shift => .shift_right,
        .right_control => .control_right,
        .right_alt => .alt_right,
        .right_super => .super_right,
        .menu => .menu,
        else => .unknown,
    };
}

fn namedKey(key: glfw.Key) events.NamedKey {
    return switch (key) {
        .escape => .escape,
        .enter, .kp_enter => .enter,
        .tab => .tab,
        .backspace => .backspace,
        .insert => .insert,
        .delete => .delete,
        .right => .arrow_right,
        .left => .arrow_left,
        .down => .arrow_down,
        .up => .arrow_up,
        .page_up => .page_up,
        .page_down => .page_down,
        .home => .home,
        .end => .end,
        else => .unidentified,
    };
}
