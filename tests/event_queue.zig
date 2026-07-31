const std = @import("std");
const platform = @import("lenore-platform");

const testing = std.testing;

fn cursor(x: f32, y: f32, generation: u32) platform.Payload {
    return .{ .cursor = .{
        .logical_position = .{ x, y },
        .metrics_generation = generation,
    } };
}

fn key(physical: platform.PhysicalKey, action: platform.KeyAction) platform.Payload {
    return .{ .key = .{ .physical = physical, .action = action } };
}

fn metrics(width: u32, generation: u32) platform.Payload {
    return .{ .surface_metrics = .{
        .logical_size = .{ 800, 600 },
        .framebuffer_extent = .{ .width = width, .height = 900 },
        .scale = .{ 1.5, 1.5 },
        .generation = generation,
    } };
}
test "absolute payloads replace with the newest event" {
    var queue = try platform.EventQueue.initCapacity(testing.allocator, 1, 8);
    defer queue.deinit(testing.allocator);

    try testing.expect(queue.submit(testing.allocator, 10, cursor(1, 2, 1)));
    try testing.expect(queue.submit(testing.allocator, 20, cursor(3, 4, 1)));
    try testing.expect(queue.submit(testing.allocator, 30, metrics(1200, 1)));
    try testing.expect(queue.submit(testing.allocator, 40, metrics(1201, 2)));

    const batch = try queue.takeBatch();
    defer queue.releaseBatch();
    try testing.expectEqual(2, batch.len);
    try testing.expectEqual(2, batch[0].sequence);
    try testing.expectEqual(20, batch[0].timestamp_ns);
    try testing.expectEqual(@as([2]f32, .{ 3, 4 }), batch[0].payload.cursor.logical_position);
    try testing.expectEqual(4, batch[1].sequence);
    try testing.expectEqual(40, batch[1].timestamp_ns);
    try testing.expectEqual(1201, batch[1].payload.surface_metrics.framebuffer_extent.width);
    try testing.expectEqual(2, batch[1].payload.surface_metrics.generation);
}
test "relative payloads accumulate only while adjacent and compatible" {
    var queue = try platform.EventQueue.initCapacity(testing.allocator, 1, 8);
    defer queue.deinit(testing.allocator);

    try testing.expect(queue.submit(testing.allocator, 10, .{ .scroll = .{
        .pixel_delta = .{ 1, 2 },
        .line_delta = .{ 3, 4 },
        .source = .wheel,
    } }));
    try testing.expect(queue.submit(testing.allocator, 20, .{ .scroll = .{
        .pixel_delta = .{ 5, 6 },
        .line_delta = .{ 7, 8 },
        .source = .wheel,
    } }));
    try testing.expect(queue.submit(testing.allocator, 30, .{ .scroll = .{
        .line_delta = .{ 1, 1 },
        .source = .finger,
    } }));

    const batch = try queue.takeBatch();
    defer queue.releaseBatch();
    try testing.expectEqual(2, batch.len);
    try testing.expectEqual(@as([2]f32, .{ 6, 8 }), batch[0].payload.scroll.pixel_delta);
    try testing.expectEqual(@as([2]f32, .{ 10, 12 }), batch[0].payload.scroll.line_delta);
    try testing.expectEqual(2, batch[0].sequence);
    try testing.expectEqual(20, batch[0].timestamp_ns);
    try testing.expectEqual(platform.ScrollSource.finger, batch[1].payload.scroll.source);
}
test "non-coalescible payloads are barriers" {
    var queue = try platform.EventQueue.initCapacity(testing.allocator, 3, 3);
    defer queue.deinit(testing.allocator);

    try testing.expect(queue.submit(testing.allocator, 10, cursor(1, 2, 1)));
    try testing.expect(queue.submit(testing.allocator, 20, key(.a, .press)));
    try testing.expect(queue.submit(testing.allocator, 30, cursor(3, 4, 1)));

    const batch = try queue.takeBatch();
    defer queue.releaseBatch();
    try testing.expectEqual(3, batch.len);
    try testing.expectEqual(1, batch[0].sequence);
    try testing.expectEqual(2, batch[1].sequence);
    try testing.expectEqual(3, batch[2].sequence);
    try testing.expect(batch[0].payload == .cursor);
    try testing.expect(batch[1].payload == .key);
    try testing.expect(batch[2].payload == .cursor);
}
test "overflow discards once and leaves a sequence gap" {
    var queue = try platform.EventQueue.initCapacity(testing.allocator, 1, 2);
    defer queue.deinit(testing.allocator);

    try testing.expect(queue.submit(testing.allocator, 10, key(.a, .press)));
    try testing.expect(queue.submit(testing.allocator, 20, key(.a, .release)));
    try testing.expect(!queue.submit(testing.allocator, 30, key(.b, .press)));
    try testing.expect(!queue.submit(testing.allocator, 40, key(.b, .release)));
    try testing.expectEqual(1, queue.overflow_count);
    try testing.expectError(error.InputEventOverflow, queue.takeBatch());

    const empty = try queue.takeBatch();
    try testing.expectEqual(0, empty.len);
    queue.releaseBatch();

    try testing.expect(queue.submit(testing.allocator, 50, key(.c, .press)));
    const batch = try queue.takeBatch();
    defer queue.releaseBatch();
    try testing.expectEqual(1, batch.len);
    try testing.expectEqual(5, batch[0].sequence);
    try testing.expectEqual(2, queue.takePeakOccupancy());
    try testing.expectEqual(0, queue.takePeakOccupancy());
}

test "event footprint stays pinned" {
    try testing.expectEqual(48, @sizeOf(platform.Event));
}
