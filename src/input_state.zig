const std = @import("std");
const events = @import("events.zig");

const key_count = @typeInfo(events.PhysicalKey).@"enum".fields.len;
const button_count = @typeInfo(events.MouseButton).@"enum".fields.len;

// Polled state folded from the same payloads the ring carries.
pub const InputState = struct {
    keys_down: std.StaticBitSet(key_count) = .initEmpty(),
    buttons_down: std.StaticBitSet(button_count) = .initEmpty(),
    cursor_logical: [2]f32 = .{ 0, 0 },
    cursor_metrics_generation: u32 = 0,
    // Focused until told otherwise: a backend that never sends focus events
    // must still deliver input. The opposite default is the obvious "fix".
    focused: bool = true,
    metrics: ?events.SurfaceMetrics = null,

    pub fn apply(self: *InputState, payload: events.Payload) void {
        switch (payload) {
            .key => |event| {
                if (event.physical == .unknown) return;
                self.keys_down.setValue(@intFromEnum(event.physical), event.action != .release);
            },
            .mouse_button => |event| {
                self.buttons_down.setValue(@intFromEnum(event.button), event.action != .release);
            },
            .cursor => |event| {
                self.cursor_logical = event.logical_position;
                self.cursor_metrics_generation = event.metrics_generation;
            },

            .focus => |event| {
                self.focused = event.focused;
                // Fail-safe: a key held across focus loss never gets its release.
                if (!event.focused) {
                    self.keys_down = .initEmpty();
                    self.buttons_down = .initEmpty();
                }
            },
            .surface_metrics => |metrics| self.metrics = metrics,
            .text, .scroll => {},
        }
    }

    pub fn keyDown(self: *const InputState, key: events.PhysicalKey) bool {
        return self.keys_down.isSet(@intFromEnum(key));
    }

    pub fn buttonDown(self: *const InputState, button: events.MouseButton) bool {
        return self.buttons_down.isSet(@intFromEnum(button));
    }

    // Converts the logical pointer using the exact metrics generation it was
    // delivered under.
    pub fn cursorFramebuffer(self: *const InputState) ?[2]f32 {
        const metrics = self.metrics orelse return null;
        if (metrics.generation != self.cursor_metrics_generation) return null;
        if (!std.math.isFinite(self.cursor_logical[0]) or
            !std.math.isFinite(self.cursor_logical[1])) return null;
        if (metrics.logical_size[0] <= 0 or metrics.logical_size[1] <= 0) return null;

        return .{
            self.cursor_logical[0] / metrics.logical_size[0] *
                @as(f32, @floatFromInt(metrics.framebuffer_extent.width)),
            self.cursor_logical[1] / metrics.logical_size[1] *
                @as(f32, @floatFromInt(metrics.framebuffer_extent.height)),
        };
    }
};
