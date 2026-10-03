const backend = @import("backend/select.zig").active;
const Extent2D = @import("types.zig").Extent2D;
const Input = @import("input.zig").Input;

// Native surface handles, for whoever creates a graphics surface from them.
// Opaque pointers rather than the OS types: the consumer knows which arm it
// asked for and casts.
//
// Every arm is declared on every target. Which one can occur is the backend's
// property and `backend/select.zig` already settles it, so narrowing the union
// as well would put that decision in two places.
pub const NativeHandles = union(enum) {
    wayland: struct { display: *anyopaque, surface: *anyopaque },
};

// The display connection alone, which exists before the first window does.
//
// A graphics backend has to pick a device that can present, and the query that
// answers that without a surface takes a queue family and the connection:
// `vkGetPhysicalDeviceWaylandPresentationSupportKHR` takes a `wl_display`
// (vk.xml, registry 1.4.350). So each arm carries what its command takes and
// nothing more.
//
// The Wayland pointer repeats what `NativeHandles` already carries per window,
// and that repetition is the point. One union whose arm pairs a display with
// its surface cannot be handed a surface belonging to another connection; two
// values arriving separately can, and nothing in the types would say so.
pub const NativeDisplay = union(enum) {
    wayland: struct { display: *anyopaque },
};

// What a window is opened with.
//
// A struct rather than three parameters because two of them are strings, and
// a title and an app id passed in the wrong order compile.
pub const WindowOptions = struct {
    // A request, not a size. The compositor decides, and the decision arrives
    // as the first SurfaceMetrics event.
    preferred: Extent2D,
    // What a person reads in a title bar or a task list.
    title: [:0]const u8,
    // Which application this window belongs to. A compositor may group windows
    // by it and use it to decide how to launch the application, and the
    // suggested value is the basename of the application's desktop file, such
    // as "org.freedesktop.FooViewer" (xdg-shell.xml, xdg_toplevel.set_app_id).
    app_id: [:0]const u8,
};

// `disabled` is pointer capture: the cursor is hidden and its position becomes
// unbounded, which is what gameplay camera control reads.
pub const CursorMode = enum { normal, disabled };

pub const InitError = error{PlatformUnavailable};
pub const CreateWindowError = error{WindowCreationFailed};
pub const CursorModeError = error{CursorModeUnavailable};

pub const ClipboardError = error{
    // Nothing on the clipboard, or nothing on it that is text. An ordinary
    // answer rather than a fault: pasting from an empty clipboard is a thing
    // users do.
    ClipboardUnavailable,

    // More text than the buffer takes. Copied whole or not at all, because
    // half a paste is not a smaller one.
    ClipboardTooLarge,
};

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

    // The connection every window of this process shares.
    //
    // On the platform rather than on a window because that is what makes it
    // useful: a graphics backend chooses its device from this, once, before any
    // window exists, and every surface opened afterwards presents on that same
    // device. Taking it from the first window instead would let whichever
    // window happened to open first decide for the rest.
    pub fn nativeDisplay(self: *Platform) NativeDisplay {
        return self.impl.nativeDisplay();
    }

    pub fn createWindow(self: *Platform, options: WindowOptions) CreateWindowError!Window {
        return .{ .impl = try self.impl.createWindow(options) };
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

    // The clipboard's text, copied into `buffer`.
    //
    // Copied and not borrowed. On Wayland the program that owns the selection
    // writes it into a pipe and the reader takes it until end of file
    // (wayland.xml, wl_data_offer.receive), and the backend reads it straight
    // into the buffer the caller sized.
    //
    // A window's method because a selection belongs to a seat, and the window
    // is what a backend has that names one.
    pub fn clipboardText(self: *Window, buffer: []u8) ClipboardError![]const u8 {
        return self.impl.clipboardText(buffer);
    }

    // Puts `text` on the clipboard, and cannot report whether anybody took it:
    // a selection is offered rather than handed over, and the offer is all the
    // owner ever knows about.
    //
    // The sentinel is the C boundary's, which takes a `const char*`. It is the
    // caller's to provide because this module allocates nothing.
    pub fn setClipboardText(self: *Window, text: [:0]const u8) void {
        self.impl.setClipboardText(text);
    }
};
