//! Growable event queue with ordered coalescing. Native callbacks submit during
//! the pump; the consumer takes the whole batch at once. Overflow discards it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const events = @import("events.zig");

// takeBatch hands out a slice of the queue's storage, which the next submit
// overwrites from index 0 — the one lifetime rule that cannot be checked from a
// single call site.
const track_batch = std.debug.runtime_safety;
const BatchOutstanding = if (track_batch) bool else void;
const batch_none: BatchOutstanding = if (track_batch) false else {};

pub const EventQueue = struct {
    buffered: std.ArrayList(events.Event),
    max_capacity: usize,

    // Monotonic and intentionally sparse: advanced on every submit before the
    // overflow check and coalescing, so gaps encode lost or merged events.
    // Compare sequences, never subtract.
    next_sequence: u64 = 1,
    overflowed: bool = false,
    overflow_count: u64 = 0,
    // High-water mark, for sizing. Read and cleared by the consumer.
    peak_occupancy: usize = 0,
    batch_outstanding: BatchOutstanding = batch_none,

    pub fn initCapacity(gpa: Allocator, capacity: usize, max_capacity: usize) Allocator.Error!EventQueue {
        std.debug.assert(capacity > 0);
        std.debug.assert(max_capacity >= capacity);
        return .{
            .buffered = try .initCapacity(gpa, capacity),
            .max_capacity = max_capacity,
        };
    }

    pub fn deinit(self: *EventQueue, gpa: Allocator) void {
        self.buffered.deinit(gpa);
        self.* = undefined;
    }

    // Returns false once this batch has overflowed; further submissions are
    // dropped until takeBatch reports and resets it.
    pub fn submit(self: *EventQueue, gpa: Allocator, timestamp_ns: u64, payload: events.Payload) bool {
        if (track_batch) std.debug.assert(!self.batch_outstanding);

        const sequence = self.next_sequence;
        self.next_sequence += 1;
        if (self.overflowed) return false;

        const incoming: events.Event = .{
            .sequence = sequence,
            .timestamp_ns = timestamp_ns,
            .payload = payload,
        };

        const items = self.buffered.items;
        if (items.len > 0 and coalesce(&items[items.len - 1], incoming)) return true;

        if (items.len == self.buffered.capacity and !self.grow(gpa)) {
            self.overflowed = true;
            self.overflow_count +|= 1;
            return false;
        }

        self.buffered.appendAssumeCapacity(incoming);
        self.peak_occupancy = @max(self.peak_occupancy, self.buffered.items.len);
        return true;
    }

    // False at the ceiling or when the allocator refuses. Silent by design: the
    // caller is a native callback with nowhere to report, and the overflow the
    // consumer already handles is the report.
    fn grow(self: *EventQueue, gpa: Allocator) bool {
        if (self.buffered.capacity >= self.max_capacity) return false;
        const List = std.ArrayList(events.Event);
        const wanted = @min(List.growCapacity(self.buffered.capacity + 1), self.max_capacity);
        self.buffered.ensureTotalCapacityPrecise(gpa, wanted) catch return false;
        return true;
    }

    // The slice stays valid until releaseBatch. Ownership transfers to the
    // caller immediately, which is why submit is forbidden until it is returned.
    pub fn takeBatch(self: *EventQueue) error{InputEventOverflow}![]const events.Event {
        if (track_batch) std.debug.assert(!self.batch_outstanding);

        if (self.overflowed) {
            self.buffered.clearRetainingCapacity();
            self.overflowed = false;
            return error.InputEventOverflow;
        }

        const batch = self.buffered.items;
        if (track_batch) self.batch_outstanding = true;
        return batch;
    }

    // The caller is done reading the batch. Clearing here rather than in
    // takeBatch is what keeps the returned slice valid for its whole documented
    // lifetime.
    pub fn releaseBatch(self: *EventQueue) void {
        self.buffered.clearRetainingCapacity();
        if (track_batch) self.batch_outstanding = false;
    }

    // Peak occupancy since the last call, and clears it.
    pub fn takePeakOccupancy(self: *EventQueue) usize {
        defer self.peak_occupancy = 0;
        return self.peak_occupancy;
    }
};

// Merges incoming into previous when adjacent and mergeable, returning true if
// it did. Absolute payloads replace; relative accumulate deltas. Both take the
// incoming sequence and timestamp.
fn coalesce(previous: *events.Event, incoming: events.Event) bool {
    switch (previous.payload) {
        // Absolute: an older position is not actionable.
        .cursor => |*old| switch (incoming.payload) {
            .cursor => |new| if (old.device == new.device) {
                previous.* = incoming;
                return true;
            },
            else => {},
        },

        // Relative: deltas accumulate.
        .scroll => |*old| switch (incoming.payload) {
            .scroll => |new| if (old.device == new.device and
                old.phase == .update and new.phase == .update and
                old.source == new.source)
            {
                old.pixel_delta[0] += new.pixel_delta[0];
                old.pixel_delta[1] += new.pixel_delta[1];
                old.line_delta[0] += new.line_delta[0];
                old.line_delta[1] += new.line_delta[1];
                previous.sequence = incoming.sequence;
                previous.timestamp_ns = incoming.timestamp_ns;
                return true;
            },
            else => {},
        },

        // Absolute: only the final geometry matters.
        .surface_metrics => switch (incoming.payload) {
            .surface_metrics => {
                previous.* = incoming;
                return true;
            },
            else => {},
        },
        else => {},
    }
    return false;
}
