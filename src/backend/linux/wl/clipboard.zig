const std = @import("std");
const window_contract = @import("../../../window.zig");

const client = @import("client.zig");
const wl = @import("protocol/wayland.zig");
const posix = @import("posix.zig");

// The clipboard, which on Wayland is a selection a seat owns and a pipe the two
// clients pass bytes through.
//
// Both directions are asynchronous in the protocol and synchronous in the
// contract, and the two halves of that mismatch are handled differently.
//
// Reading blocks on a pipe the owner of the selection writes into. It is given
// a deadline, because the owner is another program and the caller is a frame
// loop: a source that stops answering must not take the window with it.
//
// Writing happens long after setClipboardText returns, when the compositor asks
// for the bytes on behalf of whoever pasted. The text is therefore copied and
// held, which is the one allocation in this file.

// How long a paste waits for the other program to produce a chunk. A frame
// budget rather than a protocol limit: it is the pause a person would see.
const chunk_timeout_ms = 250;

// The types a text selection is offered and asked for under. Declaration order
// is preference order, best first, which is what pick() compares.
const Mime = enum {
    utf8,
    plain,

    fn name(self: Mime) [*:0]const u8 {
        return switch (self) {
            // The charset is part of the type. A source that offers only the
            // bare text/plain leaves the encoding unstated, and everything this
            // engine draws is UTF-8 either way.
            .utf8 => "text/plain;charset=utf-8",
            .plain => "text/plain",
        };
    }

    fn parse(offered: [*:0]const u8) ?Mime {
        const text = std.mem.span(offered);
        for ([_]Mime{ .utf8, .plain }) |candidate| {
            if (std.mem.eql(u8, text, std.mem.span(candidate.name()))) return candidate;
        }
        return null;
    }
};

pub const Clipboard = struct {
    display: *wl.Display,
    manager: *wl.DataDeviceManager,
    device: *wl.DataDevice,
    allocator: std.mem.Allocator,

    // An offer the compositor has introduced but not yet given a role. Its
    // types arrive between the introduction and the role, and this is what
    // collects them.
    pending: ?Offer = null,

    // The current selection, once the compositor has said that is what the
    // pending offer was.
    selection: ?Offer = null,

    // What this program has put on the clipboard, and the bytes it promised.
    source: ?*wl.DataSource = null,
    promised: []u8 = &.{},

    const Offer = struct {
        object: *wl.DataOffer,
        mime: ?Mime = null,
    };

    pub fn init(
        display: *wl.Display,
        manager: *wl.DataDeviceManager,
        seat: *wl.Seat,
        allocator: std.mem.Allocator,
    ) ?Clipboard {
        const device = manager.getDataDevice(seat) catch |err| {
            std.log.warn("wayland: cannot open the seat's data device: {t}", .{err});
            return null;
        };
        return .{
            .display = display,
            .manager = manager,
            .device = device,
            .allocator = allocator,
        };
    }

    // Separate from init for the same reason the seat's own listener is: the
    // address passed here is the one the clipboard keeps.
    pub fn listen(self: *Clipboard) void {
        self.device.setListener(*Clipboard, onDevice, self);
    }

    pub fn deinit(self: *Clipboard) void {
        self.dropPending();
        self.dropSelection();
        self.releaseSource();
        if (self.device.proxy().version() >= wl.DataDevice.since.release)
            self.device.release()
        else
            self.device.proxy().destroy();
        self.* = undefined;
    }

    // Reading
    // =======

    pub fn text(self: *Clipboard, buffer: []u8) window_contract.ClipboardError![]const u8 {
        const selection = self.selection orelse return error.ClipboardUnavailable;
        const mime = selection.mime orelse return error.ClipboardUnavailable;

        var fds: [2]i32 = undefined;
        if (posix.pipe2(&fds, posix.cloexec) != 0) return error.ClipboardUnavailable;

        // The owner writes into the descriptor it is handed, so this end is
        // given away and closed here. Keeping it open would mean never seeing
        // the end of the data, because the pipe would still have a writer.
        selection.object.receive(mime.name(), fds[1]);
        _ = posix.close(fds[1]);
        defer _ = posix.close(fds[0]);

        // Nothing is written until the request reaches the compositor, and
        // requests sit in a buffer until something sends them.
        client.flush(self.display) catch {};

        return self.drain(fds[0], buffer);
    }

    fn drain(self: *Clipboard, fd: i32, buffer: []u8) window_contract.ClipboardError![]const u8 {
        _ = self;
        var filled: usize = 0;
        while (true) {
            // Per chunk rather than for the whole transfer: a source that has
            // stopped is what this guards against, and one that is merely slow
            // keeps making progress.
            var watch = [_]std.posix.pollfd{
                .{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 },
            };
            const ready = std.posix.poll(&watch, chunk_timeout_ms) catch
                return error.ClipboardUnavailable;
            if (ready == 0) {
                std.log.warn("wayland: the selection's owner stopped answering", .{});
                return error.ClipboardUnavailable;
            }

            if (filled == buffer.len) {
                // The buffer is full, which is not yet too large: the selection
                // may be exactly this long. One more read says which.
                var probe: [1]u8 = undefined;
                const extra = std.posix.read(fd, &probe) catch
                    return error.ClipboardUnavailable;
                if (extra == 0) return buffer[0..filled];
                return error.ClipboardTooLarge;
            }

            const count = std.posix.read(fd, buffer[filled..]) catch
                return error.ClipboardUnavailable;
            if (count == 0) return buffer[0..filled];
            filled += count;
        }
    }

    // Writing
    // =======

    // `serial` is from the most recent input event on this seat. A compositor
    // will not hand the selection to a program that cannot name one, which is
    // what stops a background process from taking the clipboard.
    pub fn setText(self: *Clipboard, value: [:0]const u8, serial: u32) void {
        const copy = self.allocator.dupe(u8, value) catch {
            std.log.warn("wayland: out of memory copying {d} bytes to the clipboard", .{value.len});
            return;
        };

        const source = self.manager.createDataSource() catch |err| {
            self.allocator.free(copy);
            std.log.warn("wayland: cannot create a clipboard source: {t}", .{err});
            return;
        };

        self.releaseSource();
        self.source = source;
        self.promised = copy;

        source.setListener(*Clipboard, onSource, self);
        source.offer(Mime.utf8.name());
        source.offer(Mime.plain.name());

        if (serial == 0) {
            // Nothing has been typed or clicked in this window yet. The request
            // is still sent, because a compositor is free to accept it, and a
            // rejection is silent either way.
            std.log.warn("wayland: setting the clipboard before any input event", .{});
        }
        self.device.setSelection(source, serial);
    }

    fn releaseSource(self: *Clipboard) void {
        if (self.source) |source| source.destroy();
        self.allocator.free(self.promised);
        self.source = null;
        self.promised = &.{};
    }

    fn deliver(self: *Clipboard, fd: i32) void {
        defer _ = posix.close(fd);

        var written: usize = 0;
        while (written < self.promised.len) {
            const count = posix.write(
                fd,
                self.promised[written..].ptr,
                self.promised.len - written,
            );
            if (count > 0) {
                written += @intCast(count);
                continue;
            }
            if (count < 0 and std.posix.errno(count) == .INTR) continue;

            // A reader that closed early took as much as it wanted, and the
            // write answers EPIPE rather than ending the process because
            // posix.ignoreBrokenPipe said so.
            return;
        }
    }

    // Events
    // ======

    fn onDevice(_: *wl.DataDevice, event: wl.DataDevice.Event, self: *Clipboard) void {
        switch (event) {
            .data_offer => |introduced| {
                self.dropPending();
                introduced.id.setListener(*Clipboard, onOffer, self);
                self.pending = .{ .object = introduced.id };
            },
            .selection => |named| {
                self.dropSelection();
                const object = named.id orelse {
                    // An empty clipboard, or one holding something this program
                    // was not offered.
                    self.dropPending();
                    return;
                };
                if (self.pending) |pending| {
                    if (pending.object == object) {
                        self.selection = pending;
                        self.pending = null;
                        return;
                    }
                }
                self.selection = .{ .object = object };
            },
            // Drag and drop. Nothing here accepts a drop, and the offer that
            // came with it is destroyed rather than left to the compositor:
            // an offer the client never releases is leaked for the life of the
            // connection.
            .enter, .leave, .motion, .drop => self.dropPending(),
        }
    }

    fn onOffer(object: *wl.DataOffer, event: wl.DataOffer.Event, self: *Clipboard) void {
        switch (event) {
            .offer => |offered| {
                const pending = if (self.pending) |*value| value else return;
                if (pending.object != object) return;

                const mime = Mime.parse(offered.mime_type) orelse return;
                const better = if (pending.mime) |current|
                    @backingInt(mime) < @backingInt(current)
                else
                    true;
                if (better) pending.mime = mime;
            },
            // What a drag would be allowed to do with the data. This program
            // accepts no drags.
            .source_actions, .action => {},
        }
    }

    fn onSource(object: *wl.DataSource, event: wl.DataSource.Event, self: *Clipboard) void {
        switch (event) {
            .send => |request| {
                // A source that has already been replaced still gets its
                // descriptor closed, or the reader waits for an end that never
                // comes.
                if (self.source != object) {
                    _ = posix.close(request.fd);
                    return;
                }
                self.deliver(request.fd);
            },
            .cancelled => {
                // Another program took the selection. The protocol says this
                // source is now unused and must be destroyed.
                if (self.source == object) self.releaseSource() else object.destroy();
            },
            // Drag and drop again.
            .target, .dnd_drop_performed, .dnd_finished, .action => {},
        }
    }

    fn dropPending(self: *Clipboard) void {
        if (self.pending) |pending| pending.object.destroy();
        self.pending = null;
    }

    fn dropSelection(self: *Clipboard) void {
        if (self.selection) |selection| selection.object.destroy();
        self.selection = null;
    }
};
