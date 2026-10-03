const platform = @import("lenore-platform");

// What the compiler would otherwise never look at.
//
// A test reaches only what it calls, and this module's surface begins at a
// window, which a test cannot open: a suite that tried would need a compositor.
// Referencing a function compiles its body, so this is what keeps
// `zig build test` a check on the window layer rather than only on the ring and
// the clock beside it.
//
// Anything here that gains a test which really calls it should lose its line.

test "the window-facing surface is compiled" {
    _ = &platform.Platform.init;
    _ = &platform.Platform.deinit;
    _ = &platform.Platform.nativeDisplay;
    _ = &platform.Platform.createWindow;
    _ = &platform.Platform.pollEvents;
    _ = &platform.Platform.waitEvents;
    _ = &platform.Platform.waitEventsTimeout;

    _ = &platform.Window.deinit;
    _ = &platform.Window.shouldClose;
    _ = &platform.Window.nativeHandles;
    _ = &platform.Window.captureInput;
    _ = &platform.Window.releaseInput;
    _ = &platform.Window.setCursorMode;
    _ = &platform.Window.clipboardText;
    _ = &platform.Window.setClipboardText;
}
