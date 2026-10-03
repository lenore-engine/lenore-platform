const std = @import("std");
const platform = @import("lenore-platform");

const testing = std.testing;

// What a host answer has to satisfy, whatever it is.
//
// The answer itself is the machine's and cannot be pinned: a host with no
// fontconfig has no font, and one with fontconfig has whichever the person
// using it configured. What can be pinned is the shape of the answer and that
// the file behind it exists, which is what separates a match from a path that
// merely came back.
fn check(io: std.Io, found: platform.SystemFont) !void {
    try testing.expect(found.path.len > 0);
    // fontconfig answers with the file it found, and it finds files by walking
    // directories it was configured with. A relative path would mean a match
    // against a directory this process does not know.
    try testing.expectEqual(@as(u8, '/'), found.path[0]);
    try testing.expectEqual(@as(u8, 0), found.path.ptr[found.path.len]);

    var file = try std.Io.Dir.cwd().openFile(io, found.path, .{});
    defer file.close(io);

    // The drawing preferences are the host's and cannot be pinned either. What
    // is checked is that every one came back as a member this build knows,
    // rather than as a number cast into an enumeration: a switch with no `else`
    // fails to compile when a member is added and fails at run time on a value
    // outside the set.
    switch (found.rendering.subpixel) {
        .unknown, .none, .rgb, .bgr, .vrgb, .vbgr => {},
    }
    switch (found.rendering.hint_style) {
        .none, .slight, .medium, .full => {},
    }
}

// The numbers are fontconfig's own and they are the whole of what these
// enumerations mean (`fontconfig.h`, `FC_RGBA_*` and `FC_HINT_*`). A member
// whose value moved would name another panel's stripe order or another hinting
// mode, and nothing in the picture would say so: the text would simply be worse
// on every machine that configured it.
test "the two enumerations carry the host's own numbering" {
    try testing.expectEqual(@as(c_int, 0), @backingInt(platform.SystemFontSubpixel.unknown));
    try testing.expectEqual(@as(c_int, 1), @backingInt(platform.SystemFontSubpixel.rgb));
    try testing.expectEqual(@as(c_int, 2), @backingInt(platform.SystemFontSubpixel.bgr));
    try testing.expectEqual(@as(c_int, 3), @backingInt(platform.SystemFontSubpixel.vrgb));
    try testing.expectEqual(@as(c_int, 4), @backingInt(platform.SystemFontSubpixel.vbgr));
    try testing.expectEqual(@as(c_int, 5), @backingInt(platform.SystemFontSubpixel.none));

    try testing.expectEqual(@as(c_int, 0), @backingInt(platform.SystemFontHintStyle.none));
    try testing.expectEqual(@as(c_int, 1), @backingInt(platform.SystemFontHintStyle.slight));
    try testing.expectEqual(@as(c_int, 2), @backingInt(platform.SystemFontHintStyle.medium));
    try testing.expectEqual(@as(c_int, 3), @backingInt(platform.SystemFontHintStyle.full));

    // The fallbacks a match that carried no such property leaves behind. They
    // are this module's and not fontconfig's, which is why they are stated
    // here: `unknown` in particular has to survive, because a consumer that saw
    // `none` would turn subpixel rendering off on a host that never said to.
    const absent: platform.SystemFontRendering = .{};
    try testing.expect(absent.antialias);
    try testing.expectEqual(platform.SystemFontHintStyle.slight, absent.hint_style);
    try testing.expectEqual(platform.SystemFontSubpixel.unknown, absent.subpixel);
}

test "the host is asked for a font by role rather than by name" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const sans = try platform.findSystemFont(&buffer, .{});
    if (sans) |found| {
        try check(io, found);
    } else {
        // Not a failure. A host without fontconfig has no answer to give, and
        // the caller's job is then to draw no text rather than to stop.
        return error.SkipZigTest;
    }

    // A second role, which a configuration is as entitled to have an opinion
    // about. Both resolving to one file is a legitimate configuration and not
    // something to assert against.
    var monospace_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    if (try platform.findSystemFont(&monospace_buffer, .{ .family = "monospace" })) |found| {
        try check(io, found);
    }

    // A family no host has. fontconfig substitutes rather than failing, which
    // is the behaviour that makes a missing font a drawing decision and not an
    // error path: the request is for a font like this one, not this one.
    var nonsense_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    if (try platform.findSystemFont(&nonsense_buffer, .{ .family = "no-such-family-8c1f" })) |found| {
        try check(io, found);
    }
}

test "a path that does not fit the caller's buffer is refused rather than cut" {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    if (try platform.findSystemFont(&buffer, .{}) == null) return error.SkipZigTest;

    // One byte short of the answer, which is where a copy that trusted the
    // buffer would write past its end.
    var tight: [8]u8 = undefined;
    try testing.expectError(error.PathTooLong, platform.findSystemFont(&tight, .{}));
}
