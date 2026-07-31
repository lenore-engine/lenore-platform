const std = @import("std");
const platform = @import("lenore-platform");

const testing = std.testing;

fn button(value: platform.MouseButton, action: platform.KeyAction) platform.Payload {
    return .{ .mouse_button = .{
        .button = value,
        .action = action,
        .logical_position = .{ 0, 0 },
        .metrics_generation = 0,
    } };
}

fn metrics(logical_size: [2]f32, generation: u32) platform.Payload {
    return .{ .surface_metrics = .{
        .logical_size = logical_size,
        .framebuffer_extent = .{ .width = 1501, .height = 1051 },
        .scale = .{ 1.5, 1.5 },
        .generation = generation,
    } };
}

fn cursor(position: [2]f32, generation: u32) platform.Payload {
    return .{ .cursor = .{
        .logical_position = position,
        .metrics_generation = generation,
    } };
}
test "key and button state follows transitions" {
    var state: platform.InputState = .{};
    try testing.expect(state.focused);

    state.apply(.{ .key = .{ .physical = .unknown, .action = .press } });
    try testing.expect(!state.keyDown(.unknown));

    state.apply(.{ .key = .{ .physical = .a, .action = .press } });
    try testing.expect(state.keyDown(.a));
    state.apply(.{ .key = .{ .physical = .a, .action = .repeat } });
    try testing.expect(state.keyDown(.a));
    state.apply(.{ .key = .{ .physical = .a, .action = .release } });
    try testing.expect(!state.keyDown(.a));

    state.apply(button(.left, .press));
    try testing.expect(state.buttonDown(.left));
    state.apply(button(.left, .release));
    try testing.expect(!state.buttonDown(.left));
}
test "focus loss clears held input" {
    var state: platform.InputState = .{};
    state.apply(.{ .key = .{ .physical = .a, .action = .press } });
    state.apply(.{ .key = .{ .physical = .shift_left, .action = .press } });
    state.apply(button(.left, .press));
    state.apply(button(.forward, .press));

    state.apply(.{ .focus = .{ .focused = false } });
    try testing.expect(!state.focused);
    try testing.expect(!state.keyDown(.a));
    try testing.expect(!state.keyDown(.shift_left));
    try testing.expect(!state.buttonDown(.left));
    try testing.expect(!state.buttonDown(.forward));
}
test "cursor conversion requires matching valid metrics" {
    var state: platform.InputState = .{};
    try testing.expectEqual(null, state.cursorFramebuffer());

    state.apply(metrics(.{ 1000, 700 }, 7));
    state.apply(cursor(.{ 500, 350 }, 6));
    try testing.expectEqual(null, state.cursorFramebuffer());

    state.apply(cursor(.{ 500, 350 }, 7));
    try testing.expectEqual(
        @as([2]f32, .{ 750.5, 525.5 }),
        state.cursorFramebuffer().?,
    );

    state.apply(cursor(.{ std.math.nan(f32), 350 }, 7));
    try testing.expectEqual(null, state.cursorFramebuffer());

    state.apply(metrics(.{ 0, 700 }, 8));
    state.apply(cursor(.{ 0, 350 }, 8));
    try testing.expectEqual(null, state.cursorFramebuffer());

    state.apply(metrics(.{ 1000, -1 }, 9));
    state.apply(cursor(.{ 500, 0 }, 9));
    try testing.expectEqual(null, state.cursorFramebuffer());
}
