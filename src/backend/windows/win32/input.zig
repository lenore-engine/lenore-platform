const std = @import("std");
const windows = std.os.windows;
const events = @import("../../../events.zig");
const window_contract = @import("../../../window.zig");
const Input = @import("../../../input.zig").Input;

const api = @import("api.zig");
const scancodes = @import("scancodes.zig");

// Everything a person operates, for one window.
//
// Win32 delivers keyboard and mouse input to the window that has focus or
// capture, as messages through that window's procedure, so this state belongs
// to the window rather than to the platform. Wayland's seat is the opposite
// shape because its events arrive on one object for the whole connection.
//
// `handle` is called by the window procedure for every message. It answers the
// messages that are input and returns null for the rest, which the procedure
// then leaves to DefWindowProcW.

pub const Seat = struct {
    // The first half of a character outside the Basic Multilingual Plane.
    // WM_CHAR carries one UTF-16 code unit, so such a character arrives as two
    // messages (winuser.h, WM_CHAR).
    high_surrogate: ?u16 = null,

    // Mouse buttons held, one bit per MouseButton. Capture is taken with the
    // first and released with the last, so that a drag that leaves the window
    // still reports its release.
    buttons: u8 = 0,

    mode: window_contract.CursorMode = .normal,
    focused: bool = false,

    // The previous position of an absolute raw mouse, in virtual-desktop
    // pixels. A remote desktop session or a virtual machine reports the mouse
    // as positions rather than motion, and the difference between two of them
    // is the motion.
    absolute: ?[2]i32 = null,

    pub fn handle(
        self: *Seat,
        hwnd: api.HWND,
        input: ?*Input,
        dpi: u32,
        message: api.UINT,
        wparam: api.WPARAM,
        lparam: api.LPARAM,
    ) ?api.LRESULT {
        switch (message) {
            api.WM_KEYDOWN, api.WM_KEYUP => {
                if (input) |target| self.key(target, message, wparam, lparam);
                return 0;
            },
            // The system variants are keys pressed with Alt, and F10. They are
            // reported, then left to DefWindowProcW as well, which is what turns
            // Alt+F4 into WM_CLOSE.
            api.WM_SYSKEYDOWN, api.WM_SYSKEYUP => {
                if (input) |target| self.key(target, message, wparam, lparam);
                return null;
            },
            api.WM_CHAR => {
                if (input) |target| self.character(target, @truncate(wparam));
                return 0;
            },
            // A character typed with Alt held. It is a menu accelerator rather
            // than text, and DefWindowProcW would beep for the menu it cannot
            // find.
            api.WM_SYSCHAR => return 0,
            api.WM_SYSCOMMAND => {
                // Alt or F10 alone opens the window menu and the next key goes
                // to it, which in a game swallows the key after every Alt. The
                // low four bits of the command are the system's own (winuser.h,
                // WM_SYSCOMMAND).
                if (wparam & 0xfff0 == api.SC_KEYMENU) return 0;
                return null;
            },

            api.WM_MOUSEMOVE => {
                // A disabled cursor reports motion through WM_INPUT. The
                // position here is wherever the clipped, hidden cursor sits.
                if (self.mode == .disabled) return 0;
                if (input) |target| cursor(target, lparam, dpi);
                return 0;
            },
            api.WM_LBUTTONDOWN, api.WM_LBUTTONUP => {
                self.button(hwnd, input, .left, message == api.WM_LBUTTONDOWN);
                return 0;
            },
            api.WM_RBUTTONDOWN, api.WM_RBUTTONUP => {
                self.button(hwnd, input, .right, message == api.WM_RBUTTONDOWN);
                return 0;
            },
            api.WM_MBUTTONDOWN, api.WM_MBUTTONUP => {
                self.button(hwnd, input, .middle, message == api.WM_MBUTTONDOWN);
                return 0;
            },
            api.WM_XBUTTONDOWN, api.WM_XBUTTONUP => {
                const which: u16 = @truncate(wparam >> 16);
                const pressed = message == api.WM_XBUTTONDOWN;
                switch (which) {
                    api.XBUTTON1 => self.button(hwnd, input, .back, pressed),
                    api.XBUTTON2 => self.button(hwnd, input, .forward, pressed),
                    else => self.button(hwnd, input, .other, pressed),
                }
                // These two are the mouse messages that are answered with TRUE
                // (winuser.h, WM_XBUTTONDOWN).
                return 1;
            },
            api.WM_CAPTURECHANGED => {
                // Capture taken away by the system or another window. The
                // buttons are released by the focus loss that comes with it.
                self.buttons = 0;
                return 0;
            },
            api.WM_MOUSEWHEEL, api.WM_MOUSEHWHEEL => {
                if (input) |target| wheel(target, message, wparam);
                return 0;
            },

            api.WM_SETFOCUS => {
                self.focused = true;
                if (self.mode == .disabled) clip(hwnd);
                if (input) |target| target.submit(.{ .focus = .{ .focused = true } });
                return null;
            },
            api.WM_KILLFOCUS => {
                self.focused = false;
                self.high_surrogate = null;
                // A cursor confined to a window nobody is looking at would trap
                // the person's pointer on the rest of the desktop.
                if (self.mode == .disabled) _ = api.ClipCursor(null);
                if (input) |target| target.submit(.{ .focus = .{ .focused = false } });
                return null;
            },
            api.WM_MOVE => {
                self.reclip(hwnd);
                return null;
            },
            api.WM_SETCURSOR => {
                // The low word of lParam is the hit-test result. Over the
                // client area of a disabled cursor there is no cursor; over the
                // frame the system draws its own.
                const hit: u16 = @truncate(@as(usize, @bitCast(lparam)));
                if (self.mode == .disabled and hit == api.HTCLIENT) {
                    _ = api.SetCursor(null);
                    return 1;
                }
                return null;
            },
            api.WM_INPUT => {
                if (input) |target| self.raw(target, wparam, lparam);
                // Whatever was read, DefWindowProcW is what releases the raw
                // input buffer (winuser.h, WM_INPUT).
                return null;
            },
            else => return null,
        }
    }

    // Pointer capture. The cursor is hidden over the client area, confined to
    // it while the window has focus, and motion is read from Raw Input, which
    // reports the mouse's own counts before pointer acceleration, as Wayland's
    // relative pointer reports dx_unaccel. Those counts are device units, not
    // pixels, and like Wayland's they are not scaled by the display.
    pub fn setCursorMode(
        self: *Seat,
        hwnd: api.HWND,
        mode: window_contract.CursorMode,
    ) window_contract.CursorModeError!void {
        if (mode == self.mode) return;

        switch (mode) {
            .disabled => {
                const device: api.RAWINPUTDEVICE = .{
                    .usUsagePage = api.HID_USAGE_PAGE_GENERIC,
                    .usUsage = api.HID_USAGE_GENERIC_MOUSE,
                    .dwFlags = 0,
                    .hwndTarget = hwnd,
                };
                if (!api.RegisterRawInputDevices(@ptrCast(&device), 1, @sizeOf(api.RAWINPUTDEVICE)).toBool()) {
                    std.log.warn("win32: cannot register for raw mouse input: {t}", .{windows.GetLastError()});
                    return error.CursorModeUnavailable;
                }
                self.mode = .disabled;
                self.absolute = null;
                if (self.focused) {
                    clip(hwnd);
                    _ = api.SetCursor(null);
                }
            },
            .normal => {
                const device: api.RAWINPUTDEVICE = .{
                    .usUsagePage = api.HID_USAGE_PAGE_GENERIC,
                    .usUsage = api.HID_USAGE_GENERIC_MOUSE,
                    .dwFlags = api.RIDEV_REMOVE,
                    .hwndTarget = null,
                };
                if (!api.RegisterRawInputDevices(@ptrCast(&device), 1, @sizeOf(api.RAWINPUTDEVICE)).toBool())
                    std.log.warn("win32: cannot unregister raw mouse input: {t}", .{windows.GetLastError()});
                self.mode = .normal;
                _ = api.ClipCursor(null);
                _ = api.SetCursor(api.LoadCursorW(null, api.IDC_ARROW));
            },
        }
    }

    // Follows a window that moved or changed size with the confinement
    // rectangle, which is in screen coordinates and does not move by itself.
    pub fn reclip(self: *Seat, hwnd: api.HWND) void {
        if (self.mode == .disabled and self.focused) clip(hwnd);
    }

    // Gives back what this window took from the desktop, before it is
    // destroyed: the confinement, the raw input registration and the capture.
    pub fn release(self: *Seat, hwnd: api.HWND) void {
        self.setCursorMode(hwnd, .normal) catch {};
        if (self.buttons != 0) _ = api.ReleaseCapture();
        self.buttons = 0;
    }

    // Keyboard
    // ========

    fn key(self: *Seat, input: *Input, message: api.UINT, wparam: api.WPARAM, lparam: api.LPARAM) void {
        _ = self;
        const bits: usize = @bitCast(lparam);
        const extended = bits & (1 << 24) != 0;
        const released = message == api.WM_KEYUP or message == api.WM_SYSKEYUP;

        if (wparam == api.VK_CONTROL and !extended and isAltGrControl(message)) return;

        var physical = scancodes.physicalKey(lparam);
        if (bits & 0x00ff0000 == 0) {
            // A key with no scan code was synthesized by software that named
            // only the virtual key. The system's map gives the scan code a
            // keyboard would have sent, with 0xE0 in the high byte for an
            // extended key (winuser.h, MAPVK_VK_TO_VSC_EX).
            const code = api.MapVirtualKeyW(@intCast(wparam & 0xff), api.MAPVK_VK_TO_VSC_EX);
            const extended_flag: usize = if (code >> 8 == 0xe0) 1 << 24 else 0;
            physical = scancodes.physicalKey(@bitCast(((@as(usize, code) & 0xff) << 16) | extended_flag));
        }

        // Bit 30 is the key's state before this message: set on a down
        // message, it is the system's autorepeat.
        const action: events.KeyAction = if (released)
            .release
        else if (bits & (1 << 30) != 0)
            .repeat
        else
            .press;

        // Print Screen's press is taken by the system for the screenshot and
        // only its release reaches a window. The press is reported with it so
        // that the key is seen at all.
        if (physical == .print_screen and action == .release and !input.keyDown(.print_screen))
            submitKey(input, physical, .press);

        submitKey(input, physical, action);

        // With both Shifts held, releasing one reports a release for the
        // virtual key VK_SHIFT and the other Shift's release never comes. Any
        // Shift the state still holds and the system no longer does is
        // released here.
        if (released and wparam == api.VK_SHIFT) {
            if (input.keyDown(.shift_left) and !isDown(api.VK_LSHIFT)) submitKey(input, .shift_left, .release);
            if (input.keyDown(.shift_right) and !isDown(api.VK_RSHIFT)) submitKey(input, .shift_right, .release);
        }
    }

    fn character(self: *Seat, input: *Input, unit: u16) void {
        const codepoint: u21 = switch (unit) {
            0xd800...0xdbff => {
                self.high_surrogate = unit;
                return;
            },
            0xdc00...0xdfff => codepoint: {
                const high = self.high_surrogate orelse return;
                self.high_surrogate = null;
                break :codepoint 0x10000 + (@as(u21, high - 0xd800) << 10) + (unit - 0xdc00);
            },
            else => codepoint: {
                self.high_surrogate = null;
                break :codepoint unit;
            },
        };

        // Control characters are not text. Backspace, Tab, Return and Escape
        // and every Ctrl+letter arrive here as their C0 codes, and they reach a
        // consumer as key events instead, as on Wayland.
        if (codepoint < 0x20 or codepoint == 0x7f) return;

        var chunk: events.TextChunk = .{
            .transaction = input.nextTextTransaction(),
            .kind = .commit,
            .begin = true,
            .end = true,
            .len = 0,
            .bytes = @splat(0),
        };
        chunk.len = std.unicode.utf8Encode(codepoint, &chunk.bytes) catch return;
        input.submit(.{ .text = chunk });
    }

    // Pointer
    // =======

    fn button(self: *Seat, hwnd: api.HWND, input: ?*Input, which: events.MouseButton, pressed: bool) void {
        const bit = @as(u8, 1) << @intCast(@backingInt(which));
        if (pressed) {
            if (self.buttons == 0) _ = api.SetCapture(hwnd);
            self.buttons |= bit;
        } else {
            self.buttons &= ~bit;
            if (self.buttons == 0) _ = api.ReleaseCapture();
        }

        const target = input orelse return;
        target.submit(.{ .mouse_button = .{
            .button = which,
            .action = if (pressed) .press else .release,
            .modifiers = modifiers(),
            .logical_position = target.last_cursor,
            .metrics_generation = target.metrics_generation,
        } });
    }

    fn raw(self: *Seat, input: *Input, wparam: api.WPARAM, lparam: api.LPARAM) void {
        if (self.mode != .disabled) return;
        // Input that arrived while the window was in the background. Not
        // registered for, but a registration another part of the process made
        // could deliver it.
        if (wparam & 0xff != api.RIM_INPUT) return;

        var data: api.RAWINPUT_MOUSE = undefined;
        var size: api.UINT = @sizeOf(api.RAWINPUT_MOUSE);
        const handle_bits: usize = @bitCast(lparam);
        const read = api.GetRawInputData(
            @ptrFromInt(handle_bits),
            api.RID_INPUT,
            &data,
            &size,
            @sizeOf(api.RAWINPUTHEADER),
        );
        if (read == std.math.maxInt(api.UINT) or data.header.dwType != api.RIM_TYPEMOUSE) return;

        const mouse = data.mouse;
        var delta: [2]i32 = .{ mouse.lLastX, mouse.lLastY };
        if (mouse.usFlags & api.MOUSE_MOVE_ABSOLUTE != 0) {
            // Absolute positions are normalized to 0..65535 across the primary
            // monitor, or across the virtual desktop when the flag says so
            // (winuser.h, RAWMOUSE).
            const virtual = mouse.usFlags & api.MOUSE_VIRTUAL_DESKTOP != 0;
            const width = api.GetSystemMetrics(if (virtual) api.SM_CXVIRTUALSCREEN else api.SM_CXSCREEN);
            const height = api.GetSystemMetrics(if (virtual) api.SM_CYVIRTUALSCREEN else api.SM_CYSCREEN);
            const left = if (virtual) api.GetSystemMetrics(api.SM_XVIRTUALSCREEN) else 0;
            const top = if (virtual) api.GetSystemMetrics(api.SM_YVIRTUALSCREEN) else 0;
            const position: [2]i32 = .{
                left + @divTrunc(mouse.lLastX * width, 65535),
                top + @divTrunc(mouse.lLastY * height, 65535),
            };
            const previous = self.absolute orelse position;
            self.absolute = position;
            delta = .{ position[0] - previous[0], position[1] - previous[1] };
        } else {
            self.absolute = null;
        }
        if (delta[0] == 0 and delta[1] == 0) return;

        // The position is deliberately unbounded, as on Wayland: a disabled
        // cursor is pointer capture, and a consumer reads the difference
        // between frames rather than the value.
        input.last_cursor = .{
            input.last_cursor[0] + @as(f32, @floatFromInt(delta[0])),
            input.last_cursor[1] + @as(f32, @floatFromInt(delta[1])),
        };
        input.submit(.{ .cursor = .{
            .logical_position = input.last_cursor,
            .metrics_generation = input.metrics_generation,
        } });
    }
};

fn submitKey(input: *Input, physical: events.PhysicalKey, action: events.KeyAction) void {
    input.submit(.{ .key = .{
        .physical = physical,
        .logical = .of(physical),
        .action = action,
        .modifiers = modifiers(),
    } });
}

// The client-area position in lParam, in pixels and signed: a captured drag
// reports positions outside the window, to the left and above it as negative
// (winuser.h, GET_X_LPARAM).
fn cursor(input: *Input, lparam: api.LPARAM, dpi: u32) void {
    const bits: usize = @bitCast(lparam);
    const x: i16 = @bitCast(@as(u16, @truncate(bits)));
    const y: i16 = @bitCast(@as(u16, @truncate(bits >> 16)));
    const scale = @as(f32, @floatFromInt(dpi)) / api.USER_DEFAULT_SCREEN_DPI;
    input.last_cursor = .{ @as(f32, @floatFromInt(x)) / scale, @as(f32, @floatFromInt(y)) / scale };
    input.submit(.{ .cursor = .{
        .logical_position = input.last_cursor,
        .metrics_generation = input.metrics_generation,
    } });
}

// The high word of wParam is the rotation in multiples of WHEEL_DELTA, and a
// fine-grained wheel or a touchpad sends fractions of one. Positive is away
// from the user for the vertical wheel, which is already ScrollEvent's
// positive y, and to the right for the horizontal one, which is the opposite
// of ScrollEvent's positive x.
fn wheel(input: *Input, message: api.UINT, wparam: api.WPARAM) void {
    const rotation: i16 = @bitCast(@as(u16, @truncate(wparam >> 16)));
    const steps = @as(f32, @floatFromInt(rotation)) / api.WHEEL_DELTA;
    input.submit(.{ .scroll = .{
        .line_delta = if (message == api.WM_MOUSEHWHEEL) .{ -steps, 0 } else .{ 0, steps },
        .source = .wheel,
    } });
}

// AltGr is delivered as a left Control press immediately followed by a right
// Alt press with the same message time, and the Control was never pressed. The
// pair is recognised by looking at the next message without removing it, which
// is how GLFW tells them apart (src/win32_window.c, the WM_KEYDOWN case).
fn isAltGrControl(message: api.UINT) bool {
    var next: api.MSG = undefined;
    if (!api.PeekMessageW(&next, null, 0, 0, api.PM_NOREMOVE).toBool()) return false;

    const same_direction = switch (message) {
        api.WM_KEYDOWN, api.WM_SYSKEYDOWN => next.message == api.WM_KEYDOWN or next.message == api.WM_SYSKEYDOWN,
        else => next.message == api.WM_KEYUP or next.message == api.WM_SYSKEYUP,
    };
    const next_bits: usize = @bitCast(next.lParam);
    return same_direction and
        next.wParam == api.VK_MENU and
        next_bits & (1 << 24) != 0 and
        next.time == @as(api.DWORD, @bitCast(api.GetMessageTime()));
}

fn isDown(virtual_key: c_int) bool {
    return api.GetKeyState(virtual_key) < 0;
}

// Modifier state as of the message being handled, not as of now: GetKeyState
// answers from the input state the thread has processed up to this message.
fn modifiers() events.Modifiers {
    return .{
        .shift = isDown(api.VK_SHIFT),
        .control = isDown(api.VK_CONTROL),
        .alt = isDown(api.VK_MENU),
        .super = isDown(api.VK_LWIN) or isDown(api.VK_RWIN),
        .caps_lock = api.GetKeyState(api.VK_CAPITAL) & 1 != 0,
        .num_lock = api.GetKeyState(api.VK_NUMLOCK) & 1 != 0,
    };
}

// Confines the cursor to the client area, in screen coordinates.
fn clip(hwnd: api.HWND) void {
    var rect: api.RECT = undefined;
    if (!api.GetClientRect(hwnd, &rect).toBool()) return;
    _ = api.MapWindowPoints(hwnd, null, @ptrCast(&rect), 2);
    if (!api.ClipCursor(&rect).toBool())
        std.log.warn("win32: cannot confine the cursor: {t}", .{windows.GetLastError()});
}
