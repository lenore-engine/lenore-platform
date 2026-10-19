const std = @import("std");
const windows = std.os.windows;
const window = @import("../../window.zig");
const Input = @import("../../input.zig").Input;
const Extent2D = @import("../../types.zig").Extent2D;

const api = @import("win32/api.zig");
const seat_module = @import("win32/input.zig");
const clipboard = @import("win32/clipboard.zig");

// Native Win32 backend.
//
// One window class registered by the platform, and windows created from it.
// Everything a window reports reaches it through the window procedure, which
// the system calls from inside DispatchMessageW during a pump, so the pump is
// the only place events are produced, as on every other backend.
//
// The lifetimes follow window.zig. Platform is returned by value and nothing
// the system holds points into it: the class is identified by name and the
// timer by handle. Window is returned by value too, and its address is handed
// to the system in captureInput, through GWLP_USERDATA, which is what the
// window procedure reads to find it. The invariant that buys is the same as on
// Wayland: a Window must not be moved after captureInput.
//
// Sizes. A per-monitor-aware process sees every coordinate in physical pixels,
// so the client rectangle is the framebuffer extent as it stands and the
// logical size is derived from it by the window's DPI over 96, the DPI that
// Windows calls a scale of one (winuser.h, USER_DEFAULT_SCREEN_DPI). That is
// the opposite direction from Wayland, where the logical size is what the
// compositor sends and the buffer is scaled from it.
//
// What this backend does not do. Dragging or resizing a window runs the
// system's own modal loop inside DispatchMessageW, and the caller's frame loop
// does not run until the user lets go: the window keeps its last frame and
// stretches it. Drawing during that loop needs a timer or a second thread
// feeding frames, and neither is here.

// The name the class is registered under. Class names are per process, and the
// contract allows one Platform per process, so one fixed name cannot collide.
const class_name = std.unicode.utf8ToUtf16LeStringLiteral("Lenore");

// The UTF-16 copy of a window title is made once per window and released before
// createWindow returns, so it needs nothing faster than this.
const allocator = std.heap.page_allocator;

pub const Platform = struct {
    instance: api.HINSTANCE,

    // A high-resolution waitable timer, which is what lets waitEventsTimeout
    // end on time. The timeout parameter of MsgWaitForMultipleObjectsEx is in
    // milliseconds and expires on the system's timer tick, about 15.6 ms unless
    // something raised the resolution, which at 120 Hz is two frames late.
    // CREATE_WAITABLE_TIMER_HIGH_RESOLUTION has no such tick (Windows 10, 1803
    // and later). Null where the flag is refused, and the wait falls back to
    // the millisecond timeout and its granularity.
    timer: ?api.HANDLE,

    pub fn init() window.InitError!Platform {
        // The module the process was started from. Its base address is the
        // HINSTANCE a class is registered against, and the PEB already holds
        // it, so no call is needed to ask.
        const instance: api.HINSTANCE = @ptrCast(windows.peb().ImageBaseAddress);

        // Per-monitor v2: coordinates in physical pixels, a WM_DPICHANGED when
        // the window moves to a monitor with another scale, and non-client
        // areas scaled by the system. Every other mode has the system scale a
        // bitmap of the window, which blurs it. A process whose manifest has
        // already chosen a mode gets ACCESS_DENIED, and the manifest stands.
        if (!api.SetProcessDpiAwarenessContext(api.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2).toBool()) {
            switch (windows.GetLastError()) {
                .ACCESS_DENIED => std.log.info("win32: DPI awareness already set for this process", .{}),
                else => |err| std.log.warn("win32: cannot set per-monitor DPI awareness: {t}", .{err}),
            }
        }

        const class: api.WNDCLASSEXW = .{
            // No class styles. CS_HREDRAW and CS_VREDRAW repaint through GDI on
            // a resize, and CS_OWNDC keeps a GDI context, and nothing here
            // draws through GDI.
            .style = 0,
            .lpfnWndProc = windowProcedure,
            .hInstance = instance,
            .hCursor = api.LoadCursorW(null, api.IDC_ARROW),
            .lpszClassName = class_name,
        };
        if (api.RegisterClassExW(&class) == 0) {
            std.log.err("win32: cannot register the window class: {t}", .{windows.GetLastError()});
            return error.PlatformUnavailable;
        }

        const timer = api.CreateWaitableTimerExW(
            null,
            null,
            api.CREATE_WAITABLE_TIMER_HIGH_RESOLUTION,
            api.TIMER_MODIFY_STATE | api.SYNCHRONIZE,
        );
        if (timer == null) std.log.info(
            "win32: no high-resolution timer ({t}); timed waits round to the system tick",
            .{windows.GetLastError()},
        );

        return .{ .instance = instance, .timer = timer };
    }

    pub fn deinit(self: *Platform) void {
        if (self.timer) |timer| windows.CloseHandle(timer);
        // Fails while a window of the class still exists, which the contract
        // forbids at this point. Logged rather than asserted: the process is
        // tearing down and the class goes with it.
        if (!api.UnregisterClassW(class_name, self.instance).toBool())
            std.log.warn("win32: cannot unregister the window class: {t}", .{windows.GetLastError()});
        self.* = undefined;
    }

    pub fn nativeDisplay(_: *Platform) window.NativeDisplay {
        return .{ .win32 = .{} };
    }

    pub fn createWindow(self: *Platform, options: window.WindowOptions) window.CreateWindowError!Window {
        const title = std.unicode.utf8ToUtf16LeAllocZ(allocator, options.title) catch |err| {
            std.log.err("win32: cannot convert the window title: {t}", .{err});
            return error.WindowCreationFailed;
        };
        defer allocator.free(title);

        // app_id has no counterpart on a Win32 window. The taskbar groups a
        // window by the executable that created it unless the process names an
        // AppUserModelID, which is per process and set through shell32, so the
        // grouping app_id asks for is already the default for one executable.
        const style = api.WS_OVERLAPPEDWINDOW;
        const ex_style = api.WS_EX_APPWINDOW;

        // Created at the system's default size and position, hidden, then
        // sized. The DPI that turns the requested logical size into pixels is
        // the DPI of the monitor the window lands on, and the window has to
        // exist before that monitor is known.
        const hwnd = api.CreateWindowExW(
            ex_style,
            class_name,
            title.ptr,
            style,
            api.CW_USEDEFAULT,
            api.CW_USEDEFAULT,
            api.CW_USEDEFAULT,
            api.CW_USEDEFAULT,
            null,
            null,
            self.instance,
            null,
        ) orelse {
            std.log.err("win32: cannot create a window: {t}", .{windows.GetLastError()});
            return error.WindowCreationFailed;
        };
        errdefer _ = api.DestroyWindow(hwnd);

        const dpi = api.GetDpiForWindow(hwnd);
        var frame: api.RECT = .{
            .left = 0,
            .top = 0,
            .right = @intCast(toPixels(options.preferred.width, dpi)),
            .bottom = @intCast(toPixels(options.preferred.height, dpi)),
        };
        // The requested size is the client area. The frame around it is the
        // system's, and its thickness depends on the DPI as well.
        if (!api.AdjustWindowRectExForDpi(&frame, style, .FALSE, ex_style, dpi).toBool())
            std.log.warn("win32: cannot measure the window frame: {t}", .{windows.GetLastError()});
        if (!api.SetWindowPos(
            hwnd,
            null,
            0,
            0,
            frame.right - frame.left,
            frame.bottom - frame.top,
            api.SWP_NOMOVE | api.SWP_NOZORDER | api.SWP_NOACTIVATE,
        ).toBool())
            std.log.warn("win32: cannot size the window: {t}", .{windows.GetLastError()});

        return .{
            .instance = self.instance,
            .hwnd = hwnd,
            .dpi = dpi,
        };
    }

    pub fn pollEvents(_: *Platform) void {
        drain();
    }

    pub fn waitEvents(_: *Platform) void {
        wait(0, null, api.INFINITE);
        drain();
    }

    pub fn waitEventsTimeout(self: *Platform, seconds: f64) void {
        // A non-positive or non-finite request is a drain, not a wait. NaN
        // compares false against everything and lands here too.
        if (!(seconds > 0)) return drain();
        const bounded = @min(seconds, @as(f64, std.time.s_per_hour));

        if (self.timer) |timer| {
            // Negative is relative, in 100 ns units (synchapi.h,
            // SetWaitableTimer). Rounded up so the wait never ends early.
            const due: api.LARGE_INTEGER = -@as(i64, @intFromFloat(@ceil(bounded * 1e7)));
            if (api.SetWaitableTimer(timer, &due, 0, null, null, .FALSE).toBool()) {
                const handles = [_]api.HANDLE{timer};
                wait(handles.len, &handles, api.INFINITE);
                return drain();
            }
            std.log.warn("win32: cannot arm the wait timer: {t}", .{windows.GetLastError()});
        }

        const milliseconds: api.DWORD = @intFromFloat(@ceil(bounded * std.time.ms_per_s));
        wait(0, null, milliseconds);
        drain();
    }
};

// Sleeps until a message arrives, a handle is signalled or the timeout expires.
//
// MWMO_INPUTAVAILABLE makes the wait return for input that is already queued
// and has been seen. Without it, a message that a PeekMessageW call looked at
// without removing counts as old and the wait sleeps over it.
fn wait(count: api.DWORD, handles: ?[*]const api.HANDLE, milliseconds: api.DWORD) void {
    const result = api.MsgWaitForMultipleObjectsEx(
        count,
        handles,
        milliseconds,
        api.QS_ALLINPUT,
        api.MWMO_INPUTAVAILABLE,
    );
    if (result == api.WAIT_FAILED)
        std.log.err("win32: waiting for messages failed: {t}", .{windows.GetLastError()});
}

// Dispatches every message queued for this thread, which is where the window
// procedure runs. Returns without waiting.
fn drain() void {
    var message: api.MSG = undefined;
    while (api.PeekMessageW(&message, null, 0, 0, api.PM_REMOVE).toBool()) {
        // Posts the character messages a key press produces, which is how text
        // input reaches the window procedure.
        _ = api.TranslateMessage(&message);
        _ = api.DispatchMessageW(&message);
    }
}

pub const Window = struct {
    instance: api.HINSTANCE,
    hwnd: api.HWND,

    // Null until captureInput and again after releaseInput.
    input: ?*Input = null,

    // Set in captureInput, the first point where this address stops moving.
    // Until then the window procedure cannot find the window and leaves every
    // message to DefWindowProcW.
    attached: bool = false,
    shown: bool = false,

    // The client rectangle in pixels and the DPI it was measured at, as last
    // reported. Zero while minimized.
    pixels: Extent2D = .{ .width = 0, .height = 0 },
    dpi: u32,

    closed: bool = false,

    fullscreen: bool = false,
    // Where the window was before it went fullscreen. Meaningful only while
    // `fullscreen` is set.
    windowed: api.WINDOWPLACEMENT = .{},

    seat: seat_module.Seat = .{},

    pub fn deinit(self: *Window) void {
        self.seat.release(self.hwnd);
        // Detached first: DestroyWindow sends WM_DESTROY and WM_NCDESTROY to
        // the procedure, and this memory is about to stop being a Window.
        if (self.attached) _ = api.SetWindowLongPtrW(self.hwnd, api.GWLP_USERDATA, 0);
        if (!api.DestroyWindow(self.hwnd).toBool())
            std.log.warn("win32: cannot destroy a window: {t}", .{windows.GetLastError()});
        self.* = undefined;
    }

    pub fn shouldClose(self: *Window) bool {
        return self.closed;
    }

    pub fn nativeHandles(self: *Window) window.NativeHandles {
        return .{ .win32 = .{
            .hinstance = @ptrCast(self.instance),
            .hwnd = @ptrCast(self.hwnd),
        } };
    }

    pub fn captureInput(self: *Window, input: *Input) void {
        self.input = input;

        if (!self.attached) {
            _ = api.SetWindowLongPtrW(self.hwnd, api.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
            self.attached = true;
        }

        // Shown here rather than at creation, for the reason Wayland commits
        // here: the window appears when there is someone to report its size
        // to. Showing sends WM_SIZE, which now reaches this window.
        if (!self.shown) {
            _ = api.ShowWindow(self.hwnd, api.SW_SHOWNORMAL);
            self.shown = true;
        }

        self.measure();
        self.submitMetrics();
    }

    pub fn releaseInput(self: *Window) void {
        self.input = null;
    }

    pub fn setCursorMode(self: *Window, mode: window.CursorMode) window.CursorModeError!void {
        return self.seat.setCursorMode(self.hwnd, mode);
    }

    pub fn clipboardText(self: *Window, buffer: []u8) window.ClipboardError![]const u8 {
        return clipboard.text(self.hwnd, buffer);
    }

    pub fn setClipboardText(self: *Window, text: [:0]const u8) void {
        clipboard.setText(self.hwnd, text);
    }

    // Borderless fullscreen: the frame styles are taken off and the window is
    // sized to its monitor, which is Raymond Chen's recipe (The Old New Thing,
    // "How do I switch a window between normal and fullscreen?", 2010-04-12).
    // No display mode is changed. A window that exactly covers its monitor is
    // what lets the compositor hand the swapchain's images straight to the
    // display instead of composing them, so this is also the mode in which
    // presentation timing is the driver's rather than the desktop's.
    //
    // The windowed placement is saved on the way in and restored on the way
    // out, which brings back a maximized state as well as the position.
    pub fn setFullscreen(self: *Window, fullscreen: bool) void {
        if (fullscreen == self.fullscreen) return;

        const style: usize = @bitCast(api.GetWindowLongPtrW(self.hwnd, api.GWL_STYLE));
        if (fullscreen) {
            const monitor = api.MonitorFromWindow(self.hwnd, api.MONITOR_DEFAULTTONEAREST) orelse return;
            var info: api.MONITORINFO = .{};
            if (!api.GetMonitorInfoW(monitor, &info).toBool()) {
                std.log.warn("win32: cannot read the monitor's rectangle: {t}", .{windows.GetLastError()});
                return;
            }
            if (!api.GetWindowPlacement(self.hwnd, &self.windowed).toBool()) {
                std.log.warn("win32: cannot save the window placement: {t}", .{windows.GetLastError()});
                return;
            }

            _ = api.SetWindowLongPtrW(self.hwnd, api.GWL_STYLE, @bitCast(style & ~@as(usize, api.WS_OVERLAPPEDWINDOW)));
            const rect = info.rcMonitor;
            _ = api.SetWindowPos(
                self.hwnd,
                null,
                rect.left,
                rect.top,
                rect.right - rect.left,
                rect.bottom - rect.top,
                api.SWP_NOOWNERZORDER | api.SWP_FRAMECHANGED,
            );
        } else {
            _ = api.SetWindowLongPtrW(self.hwnd, api.GWL_STYLE, @bitCast(style | api.WS_OVERLAPPEDWINDOW));
            _ = api.SetWindowPlacement(self.hwnd, &self.windowed);
            // The style change takes effect on the frame only once the window
            // is told its frame changed.
            _ = api.SetWindowPos(
                self.hwnd,
                null,
                0,
                0,
                0,
                0,
                api.SWP_NOMOVE | api.SWP_NOSIZE | api.SWP_NOZORDER | api.SWP_NOOWNERZORDER | api.SWP_FRAMECHANGED,
            );
        }
        self.fullscreen = fullscreen;
    }

    // Reads the client rectangle and the DPI as they stand now, for the first
    // capture, which no message reports.
    fn measure(self: *Window) void {
        var client: api.RECT = undefined;
        if (!api.GetClientRect(self.hwnd, &client).toBool()) {
            std.log.warn("win32: cannot read the client area: {t}", .{windows.GetLastError()});
            return;
        }
        self.pixels = .{
            .width = @intCast(@max(0, client.right - client.left)),
            .height = @intCast(@max(0, client.bottom - client.top)),
        };
        self.dpi = api.GetDpiForWindow(self.hwnd);
    }

    fn update(self: *Window, pixels: Extent2D, dpi: u32) void {
        const changed = self.pixels.width != pixels.width or
            self.pixels.height != pixels.height or
            self.dpi != dpi;
        self.pixels = pixels;
        self.dpi = dpi;
        if (changed) self.submitMetrics();
    }

    // A minimized window reports a zero extent, and so does a client area the
    // user has dragged down to nothing. The engine reads zero as "nothing to
    // present to" and waits on events instead of drawing.
    fn submitMetrics(self: *Window) void {
        const input = self.input orelse return;
        const scale: f32 = @as(f32, @floatFromInt(self.dpi)) / api.USER_DEFAULT_SCREEN_DPI;
        input.submit(.{ .surface_metrics = .{
            .logical_size = .{
                @as(f32, @floatFromInt(self.pixels.width)) / scale,
                @as(f32, @floatFromInt(self.pixels.height)) / scale,
            },
            .framebuffer_extent = self.pixels,
            .scale = .{ scale, scale },
            .generation = input.nextMetricsGeneration(),
        } });
    }
};

// A logical length at `dpi`, in pixels, rounded to the nearest and never zero:
// a window asked for at some size should not come out as nothing.
fn toPixels(logical: u32, dpi: u32) u32 {
    const half = api.USER_DEFAULT_SCREEN_DPI / 2;
    const scaled = (@as(u64, logical) * dpi + half) / api.USER_DEFAULT_SCREEN_DPI;
    return @intCast(@max(1, @min(scaled, std.math.maxInt(i32))));
}

fn windowOf(hwnd: api.HWND) ?*Window {
    const address: usize = @bitCast(api.GetWindowLongPtrW(hwnd, api.GWLP_USERDATA));
    return @ptrFromInt(address);
}

fn windowProcedure(
    hwnd: api.HWND,
    message: api.UINT,
    wparam: api.WPARAM,
    lparam: api.LPARAM,
) callconv(.winapi) api.LRESULT {
    const self = windowOf(hwnd) orelse return api.DefWindowProcW(hwnd, message, wparam, lparam);

    if (self.seat.handle(hwnd, self.input, self.dpi, message, wparam, lparam)) |result| return result;

    switch (message) {
        api.WM_CLOSE => {
            // The window is not destroyed here. Closing is the caller's
            // decision, made by reading shouldClose; DefWindowProcW would
            // destroy the window under it.
            self.closed = true;
            return 0;
        },
        api.WM_ERASEBKGND => {
            // Nonzero says the background is erased. The swapchain covers the
            // whole client area, and a GDI fill underneath would show through
            // as a flash on every resize.
            return 1;
        },
        api.WM_SIZE => {
            // The new client size in the low and high words of lParam
            // (winuser.h, WM_SIZE), and zero by zero when minimized.
            const bits: usize = @bitCast(lparam);
            const pixels: Extent2D = if (wparam == api.SIZE_MINIMIZED)
                .{ .width = 0, .height = 0 }
            else
                .{ .width = @as(u16, @truncate(bits)), .height = @as(u16, @truncate(bits >> 16)) };
            self.update(pixels, self.dpi);
            self.seat.reclip(hwnd);
            return 0;
        },
        api.WM_DPICHANGED => {
            // The new DPI is in both words of wParam, and lParam points at the
            // window rectangle the system suggests for it, which keeps the
            // window's logical size (winuser.h, WM_DPICHANGED).
            //
            // The DPI is stored first so that the WM_SIZE the move sends
            // reports the new scale with the new size. A move that leaves the
            // pixel size alone sends no size change, and the scale is then
            // reported here instead.
            const suggested: *const api.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            const before = self.pixels;
            self.dpi = @as(u16, @truncate(wparam));
            if (!api.SetWindowPos(
                hwnd,
                null,
                suggested.left,
                suggested.top,
                suggested.right - suggested.left,
                suggested.bottom - suggested.top,
                api.SWP_NOZORDER | api.SWP_NOACTIVATE,
            ).toBool())
                std.log.warn("win32: cannot follow a DPI change: {t}", .{windows.GetLastError()});
            if (self.pixels.width == before.width and self.pixels.height == before.height)
                self.submitMetrics();
            return 0;
        },
        else => return api.DefWindowProcW(hwnd, message, wparam, lparam),
    }
}
