const backend = @import("backend/select.zig").active;
const Extent2D = @import("types.zig").Extent2D;
const Input = @import("input.zig").Input;

// Native surface handles, for whoever creates a graphics surface from them.
pub const NativeHandles = union(enum) {
    wayland: struct { display: *anyopaque, surface: *anyopaque },
};

// `disabled` is pointer capture: the cursor is hidden and its position becomes
// unbounded, which is what gameplay camera control reads.
pub const CursorMode = enum { normal, disabled };

pub const InitError = error{PlatformUnavailable};
pub const CreateWindowError = error{WindowCreationFailed};
pub const CursorModeError = error{CursorModeUnavailable};

// The windowing library is process-global state, so it gets exactly one owner
// and windows are created from it. Windows must be closed before this is.
pub const Platform = struct {
    impl: backend.Platform,

    pub fn init() InitError!Platform {
        return .{ .impl = try backend.Platform.init() };
    }

    pub fn deinit(self: *Platform) void {
        self.impl.deinit();
    }

    // `preferred` is a request, not a size. The compositor decides, and the
    // decision arrives as the first SurfaceMetrics event.
    pub fn createWindow(self: *Platform, preferred: Extent2D, title: [:0]const u8) CreateWindowError!Window {
        return .{ .impl = try self.impl.createWindow(preferred, title) };
    }

    // Drains pending events into the ring. Returns without waiting.
    pub fn pollEvents(self: *Platform) void {
        self.impl.pollEvents();
    }

    // Sleeps until an event arrives. This is where "idle = sleep, never poll"
    // is actually enforced — used while minimized, where rendering is paused
    // and there is nothing to do.
    pub fn waitEvents(self: *Platform) void {
        self.impl.waitEvents();
    }

    pub fn waitEventsTimeout(self: *Platform, seconds: f64) void {
        self.impl.waitEventsTimeout(seconds);
    }
};

// A window has no size until the first SurfaceMetrics event. Create, capture
// input, pump once, then read it from the batch. The event carries extent,
// scale and generation atomically, which a separate accessor cannot.
pub const Window = struct {
    impl: backend.Window,

    pub fn deinit(self: *Window) void {
        self.impl.deinit();
    }

    pub fn shouldClose(self: *Window) bool {
        return self.impl.shouldClose();
    }

    pub fn nativeHandles(self: *Window) NativeHandles {
        return self.impl.nativeHandles();
    }

    // Routes this window's events into `input` and submits the first
    // SurfaceMetrics, so a batch is available after the first pump.
    pub fn captureInput(self: *Window, input: *Input) void {
        self.impl.captureInput(input);
    }

    pub fn releaseInput(self: *Window) void {
        self.impl.releaseInput();
    }

    // Pointer ownership is the caller's choice, never the platform's.
    pub fn setCursorMode(self: *Window, mode: CursorMode) CursorModeError!void {
        return self.impl.setCursorMode(mode);
    }
};
