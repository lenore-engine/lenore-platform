const std = @import("std");
const windows = std.os.windows;
const window_contract = @import("../../../window.zig");

const api = @import("api.zig");

// Text on the Windows clipboard.
//
// The clipboard holds text as CF_UNICODETEXT: NUL-terminated UTF-16 in a
// movable global memory block, with lines ended by CR LF (winuser.h, standard
// clipboard formats). The contract speaks UTF-8 with LF, as Wayland does, so
// both directions convert, and the conversion writes straight between the
// clipboard's block and the caller's buffer. Nothing is allocated here except
// the block Windows requires to hand text to the clipboard, which the
// clipboard then owns.
//
// The clipboard is one per desktop session and is opened by one window at a
// time. Another program holding it open is an ordinary failure, reported as
// unavailable rather than waited out.

const cr = 0x0d;
const lf = 0x0a;
const replacement: u21 = 0xfffd;

pub fn text(hwnd: api.HWND, buffer: []u8) window_contract.ClipboardError![]const u8 {
    if (!api.OpenClipboard(hwnd).toBool()) return error.ClipboardUnavailable;
    defer _ = api.CloseClipboard();

    // Null when the clipboard holds no text. The system synthesizes
    // CF_UNICODETEXT from CF_TEXT and CF_OEMTEXT, so text placed by an older
    // program is found here too.
    const memory = api.GetClipboardData(api.CF_UNICODETEXT) orelse return error.ClipboardUnavailable;
    const locked = api.GlobalLock(memory) orelse return error.ClipboardUnavailable;
    defer _ = api.GlobalUnlock(memory);

    // The block may be larger than the string in it, so the terminator ends
    // the text, and the block's size only bounds the search for it.
    const capacity = api.GlobalSize(memory) / @sizeOf(u16);
    const units: [*]const u16 = @ptrCast(@alignCast(locked));
    const length = std.mem.indexOfScalar(u16, units[0..capacity], 0) orelse capacity;

    return decode(units[0..length], buffer);
}

pub fn setText(hwnd: api.HWND, utf8: [:0]const u8) void {
    const view = std.unicode.Utf8View.init(utf8) catch {
        std.log.warn("win32: clipboard text is not UTF-8; not copied", .{});
        return;
    };

    const units = encodedLength(view);
    const memory = api.GlobalAlloc(api.GMEM_MOVEABLE, (units + 1) * @sizeOf(u16)) orelse {
        std.log.warn("win32: cannot allocate clipboard memory: {t}", .{windows.GetLastError()});
        return;
    };
    // Owned by the clipboard once SetClipboardData accepts it, and by this
    // function until then.
    var owned = true;
    defer if (owned) {
        _ = api.GlobalFree(memory);
    };

    const locked = api.GlobalLock(memory) orelse return;
    const destination: [*]u16 = @ptrCast(@alignCast(locked));
    encode(view, destination[0..units]);
    destination[units] = 0;
    _ = api.GlobalUnlock(memory);

    if (!api.OpenClipboard(hwnd).toBool()) {
        std.log.warn("win32: cannot open the clipboard: {t}", .{windows.GetLastError()});
        return;
    }
    defer _ = api.CloseClipboard();

    // Emptying is what makes this window the clipboard's owner, and only the
    // owner may set data on it.
    if (!api.EmptyClipboard().toBool()) {
        std.log.warn("win32: cannot take the clipboard: {t}", .{windows.GetLastError()});
        return;
    }
    if (api.SetClipboardData(api.CF_UNICODETEXT, memory) == null) {
        std.log.warn("win32: cannot place text on the clipboard: {t}", .{windows.GetLastError()});
        return;
    }
    owned = false;
}

// UTF-16 to UTF-8, CR LF to LF. A lone surrogate, which the clipboard does not
// forbid, becomes U+FFFD rather than failing the paste. All or nothing: text
// that does not fit is ClipboardTooLarge with nothing promised in the buffer.
fn decode(units: []const u16, buffer: []u8) window_contract.ClipboardError![]const u8 {
    var written: usize = 0;
    var index: usize = 0;
    while (index < units.len) {
        const unit = units[index];
        index += 1;

        const codepoint: u21 = switch (unit) {
            cr => if (index < units.len and units[index] == lf) continue else cr,
            0xd800...0xdbff => if (index < units.len and units[index] >= 0xdc00 and units[index] <= 0xdfff) pair: {
                const low = units[index];
                index += 1;
                break :pair 0x10000 + (@as(u21, unit - 0xd800) << 10) + (low - 0xdc00);
            } else replacement,
            0xdc00...0xdfff => replacement,
            else => unit,
        };

        // Both calls fail only for a surrogate or a value past U+10FFFF, and
        // the switch above produces neither.
        const size = std.unicode.utf8CodepointSequenceLength(codepoint) catch unreachable;
        if (written + size > buffer.len) return error.ClipboardTooLarge;
        _ = std.unicode.utf8Encode(codepoint, buffer[written..][0..size]) catch unreachable;
        written += size;
    }
    return buffer[0..written];
}

// The UTF-16 length of `view` once every bare LF has become CR LF.
fn encodedLength(view: std.unicode.Utf8View) usize {
    var units: usize = 0;
    var previous: u21 = 0;
    var iterator = view.iterator();
    while (iterator.nextCodepoint()) |codepoint| {
        units += if (codepoint >= 0x10000) 2 else if (codepoint == lf and previous != cr) 2 else 1;
        previous = codepoint;
    }
    return units;
}

fn encode(view: std.unicode.Utf8View, destination: []u16) void {
    var index: usize = 0;
    var previous: u21 = 0;
    var iterator = view.iterator();
    while (iterator.nextCodepoint()) |codepoint| {
        if (codepoint >= 0x10000) {
            const offset = codepoint - 0x10000;
            destination[index] = @intCast(0xd800 + (offset >> 10));
            destination[index + 1] = @intCast(0xdc00 + (offset & 0x3ff));
            index += 2;
        } else if (codepoint == lf and previous != cr) {
            destination[index] = cr;
            destination[index + 1] = lf;
            index += 2;
        } else {
            destination[index] = @intCast(codepoint);
            index += 1;
        }
        previous = codepoint;
    }
    std.debug.assert(index == destination.len);
}
