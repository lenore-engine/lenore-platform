const std = @import("std");
const events = @import("events.zig");

const key_count = @typeInfo(events.PhysicalKey).@"enum".field_names.len;
const button_count = @typeInfo(events.MouseButton).@"enum".field_names.len;

// Where a logical position delivered under `generation` lands in framebuffer
// pixels, or null when it cannot be placed.
//
// The generation has to match: a position measured against an earlier surface
// configuration describes a window of a different size, and scaling it by the
// current ratio puts it somewhere the pointer never was.
//
// The framebuffer/logical ratio and not `metrics.scale`, because a fractional
// content scale has already been rounded into the integer framebuffer extent,
// and the ratio is what the raster is.
//
// This is the one place the conversion is written. Every consumer of a
// position an event carries goes through it, so the rule above cannot exist in
// a second copy that disagrees.
pub fn framebufferPosition(
    metrics: events.SurfaceMetrics,
    logical: [2]f32,
    generation: u32,
) ?[2]f32 {
    if (metrics.generation != generation) return null;
    if (!std.math.isFinite(logical[0]) or !std.math.isFinite(logical[1])) return null;
    if (metrics.logical_size[0] <= 0 or metrics.logical_size[1] <= 0) return null;

    const position: [2]f32 = .{
        logical[0] / metrics.logical_size[0] *
            @as(f32, @floatFromInt(metrics.framebuffer_extent.width)),
        logical[1] / metrics.logical_size[1] *
            @as(f32, @floatFromInt(metrics.framebuffer_extent.height)),
    };
    // Finite operands are not enough: a logical size small enough to be
    // subnormal takes a finite position to infinity. The result is what leaves
    // this module, so it is what is checked.
    if (!std.math.isFinite(position[0]) or !std.math.isFinite(position[1])) return null;
    return position;
}

// Polled state folded from the same payloads the ring carries.
pub const InputState = struct {
    keys_down: std.bit_set.Static(key_count) = .empty,
    buttons_down: std.bit_set.Static(button_count) = .empty,
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
                self.keys_down.setValue(@backingInt(event.physical), event.action != .release);
            },
            .mouse_button => |event| {
                self.buttons_down.setValue(@backingInt(event.button), event.action != .release);
            },
            .cursor => |event| {
                self.cursor_logical = event.logical_position;
                self.cursor_metrics_generation = event.metrics_generation;
            },

            .focus => |event| {
                self.focused = event.focused;
                // Fail-safe: a key held across focus loss never gets its release.
                if (!event.focused) {
                    self.keys_down = .empty;
                    self.buttons_down = .empty;
                }
            },
            .surface_metrics => |metrics| self.metrics = metrics,
            .text, .scroll => {},
        }
    }

    pub fn keyDown(self: *const InputState, key: events.PhysicalKey) bool {
        return self.keys_down.isSet(@backingInt(key));
    }

    pub fn buttonDown(self: *const InputState, button: events.MouseButton) bool {
        return self.buttons_down.isSet(@backingInt(button));
    }

    // The polled pointer, converted under the metrics it was delivered with.
    pub fn cursorFramebuffer(self: *const InputState) ?[2]f32 {
        const metrics = self.metrics orelse return null;
        return framebufferPosition(metrics, self.cursor_logical, self.cursor_metrics_generation);
    }
};
