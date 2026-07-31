const std = @import("std");
const events = @import("events.zig");
const EventQueue = @import("event_queue.zig").EventQueue;
const InputState = @import("input_state.zig").InputState;
const Clock = @import("clock.zig").Clock;

// What an ordinary frame costs. Cursor, scroll and metrics coalesce to one slot
// each, so occupancy tracks key, button, text and focus transitions, which are
// human-rate. The queue grows past this on demand.
pub const initial_event_capacity: usize = 64;

// A staleness ceiling, not a memory one: past some backlog, replaying seconds of
// old clicks and text after a stall is worse than reporting the loss, and the
// queue's overflow is that report. 8192 events is 384 KiB. Provisional — to be
// set from a measured session via takePeakOccupancy.
pub const max_event_capacity: usize = 8192;

// Owns the event queue and the polled state; a backend feeds it through submit.
pub const Input = struct {
    gpa: std.mem.Allocator,
    clock: Clock,
    queue: EventQueue,
    state: InputState = .{},

    // Numbers the surface configurations cursor events refer back to. Starts at
    // 0, which no event can carry, so a cursor position that arrives before the
    // first SurfaceMetrics can never match one.
    metrics_generation: u32 = 0,
    text_transaction: u32 = 0,

    // Last position the backend reported as finite. A button transition must
    // never be dropped, so this is what it falls back to: the position
    // consumers already observed, not a fabricated one.
    last_cursor: [2]f32 = .{ 0, 0 },

    pub fn init(
        gpa: std.mem.Allocator,
        clock: Clock,
        capacity: usize,
        max_capacity: usize,
    ) !Input {
        return .{
            .gpa = gpa,
            .clock = clock,
            .queue = try .initCapacity(gpa, capacity, max_capacity),
        };
    }

    pub fn deinit(self: *Input) void {
        self.queue.deinit(self.gpa);
        self.* = undefined;
    }

    // The backend's one entry point. Called from native callbacks during the
    // pump, so it must not fail and has nowhere to report if it did.
    pub fn submit(self: *Input, payload: events.Payload) void {
        self.state.apply(payload);
        _ = self.queue.submit(self.gpa, self.clock.now(), payload);
    }

    // Advances the surface generation and returns it, for a backend about to
    // submit SurfaceMetrics. Never returns 0.
    pub fn nextMetricsGeneration(self: *Input) u32 {
        self.metrics_generation +%= 1;
        if (self.metrics_generation == 0) self.metrics_generation = 1;
        return self.metrics_generation;
    }

    pub fn nextTextTransaction(self: *Input) u32 {
        self.text_transaction +%= 1;
        if (self.text_transaction == 0) self.text_transaction = 1;
        return self.text_transaction;
    }

    // Paired with releaseBatch: the slice points into the queue's storage,
    // which the next submit overwrites from the start.
    pub fn takeBatch(self: *Input) error{InputEventOverflow}![]const events.Event {
        return self.queue.takeBatch();
    }

    pub fn releaseBatch(self: *Input) void {
        self.queue.releaseBatch();
    }

    pub fn inputState(self: *const Input) *const InputState {
        return &self.state;
    }

    pub fn keyDown(self: *const Input, key: events.PhysicalKey) bool {
        return self.state.keyDown(key);
    }

    pub fn overflowCount(self: *const Input) u64 {
        return self.queue.overflow_count;
    }

    pub fn takePeakOccupancy(self: *Input) usize {
        return self.queue.takePeakOccupancy();
    }
};
