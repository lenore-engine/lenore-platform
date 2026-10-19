const std = @import("std");
const events = @import("../../../events.zig");

// Keyboard scan codes to the canonical positions in events.zig.
//
// A key message carries the scan code of the key's position in bits 16 to 23
// of lParam and an extended flag in bit 24 (winuser.h, WM_KEYDOWN), and that
// pair names a position on the keyboard whatever the layout. The codes below
// are written the way Microsoft's scan code tables write them, 0xE0 before the
// extended ones, and were taken from Chromium's
// ui/events/keycodes/dom/dom_code_data.inc, which lists the USB usage, the
// evdev code and the Windows scan code of each key on one row. The Wayland
// table in this module is keyed by the evdev column of the same rows, so the
// two backends agree on every position by construction rather than by review.
//
// The list is the one source of truth. The lookup is built from it at comptime,
// and so are the checks: no code listed twice, and every position the contract
// names reachable from some code, except the ones a PC keyboard has no scan
// code for.

const Entry = struct { code: u16, key: events.PhysicalKey };

const entries = [_]Entry{
    .{ .code = 0x0001, .key = .escape },
    .{ .code = 0x0002, .key = .digit_1 },
    .{ .code = 0x0003, .key = .digit_2 },
    .{ .code = 0x0004, .key = .digit_3 },
    .{ .code = 0x0005, .key = .digit_4 },
    .{ .code = 0x0006, .key = .digit_5 },
    .{ .code = 0x0007, .key = .digit_6 },
    .{ .code = 0x0008, .key = .digit_7 },
    .{ .code = 0x0009, .key = .digit_8 },
    .{ .code = 0x000a, .key = .digit_9 },
    .{ .code = 0x000b, .key = .digit_0 },
    .{ .code = 0x000c, .key = .minus },
    .{ .code = 0x000d, .key = .equal },
    .{ .code = 0x000e, .key = .backspace },
    .{ .code = 0x000f, .key = .tab },
    .{ .code = 0x0010, .key = .q },
    .{ .code = 0x0011, .key = .w },
    .{ .code = 0x0012, .key = .e },
    .{ .code = 0x0013, .key = .r },
    .{ .code = 0x0014, .key = .t },
    .{ .code = 0x0015, .key = .y },
    .{ .code = 0x0016, .key = .u },
    .{ .code = 0x0017, .key = .i },
    .{ .code = 0x0018, .key = .o },
    .{ .code = 0x0019, .key = .p },
    .{ .code = 0x001a, .key = .left_bracket },
    .{ .code = 0x001b, .key = .right_bracket },
    .{ .code = 0x001c, .key = .enter },
    .{ .code = 0x001d, .key = .control_left },
    .{ .code = 0x001e, .key = .a },
    .{ .code = 0x001f, .key = .s },
    .{ .code = 0x0020, .key = .d },
    .{ .code = 0x0021, .key = .f },
    .{ .code = 0x0022, .key = .g },
    .{ .code = 0x0023, .key = .h },
    .{ .code = 0x0024, .key = .j },
    .{ .code = 0x0025, .key = .k },
    .{ .code = 0x0026, .key = .l },
    .{ .code = 0x0027, .key = .semicolon },
    .{ .code = 0x0028, .key = .apostrophe },
    .{ .code = 0x0029, .key = .grave },
    .{ .code = 0x002a, .key = .shift_left },
    .{ .code = 0x002b, .key = .backslash },
    .{ .code = 0x002c, .key = .z },
    .{ .code = 0x002d, .key = .x },
    .{ .code = 0x002e, .key = .c },
    .{ .code = 0x002f, .key = .v },
    .{ .code = 0x0030, .key = .b },
    .{ .code = 0x0031, .key = .n },
    .{ .code = 0x0032, .key = .m },
    .{ .code = 0x0033, .key = .comma },
    .{ .code = 0x0034, .key = .period },
    .{ .code = 0x0035, .key = .slash },
    .{ .code = 0x0036, .key = .shift_right },
    .{ .code = 0x0037, .key = .numpad_multiply },
    .{ .code = 0x0038, .key = .alt_left },
    .{ .code = 0x0039, .key = .space },
    .{ .code = 0x003a, .key = .caps_lock },
    .{ .code = 0x003b, .key = .f1 },
    .{ .code = 0x003c, .key = .f2 },
    .{ .code = 0x003d, .key = .f3 },
    .{ .code = 0x003e, .key = .f4 },
    .{ .code = 0x003f, .key = .f5 },
    .{ .code = 0x0040, .key = .f6 },
    .{ .code = 0x0041, .key = .f7 },
    .{ .code = 0x0042, .key = .f8 },
    .{ .code = 0x0043, .key = .f9 },
    .{ .code = 0x0044, .key = .f10 },
    // Pause sends E1 1D 45 and Num Lock 45 on the wire, and Windows reports
    // them the other way round from what the bytes suggest: Pause as 0x45 and
    // Num Lock as extended 0x45.
    .{ .code = 0x0045, .key = .pause },
    .{ .code = 0x0046, .key = .scroll_lock },
    .{ .code = 0x0047, .key = .numpad_7 },
    .{ .code = 0x0048, .key = .numpad_8 },
    .{ .code = 0x0049, .key = .numpad_9 },
    .{ .code = 0x004a, .key = .numpad_subtract },
    .{ .code = 0x004b, .key = .numpad_4 },
    .{ .code = 0x004c, .key = .numpad_5 },
    .{ .code = 0x004d, .key = .numpad_6 },
    .{ .code = 0x004e, .key = .numpad_add },
    .{ .code = 0x004f, .key = .numpad_1 },
    .{ .code = 0x0050, .key = .numpad_2 },
    .{ .code = 0x0051, .key = .numpad_3 },
    .{ .code = 0x0052, .key = .numpad_0 },
    .{ .code = 0x0053, .key = .numpad_decimal },
    .{ .code = 0x0057, .key = .f11 },
    .{ .code = 0x0058, .key = .f12 },
    .{ .code = 0x0059, .key = .numpad_equal },
    .{ .code = 0x0064, .key = .f13 },
    .{ .code = 0x0065, .key = .f14 },
    .{ .code = 0x0066, .key = .f15 },
    .{ .code = 0x0067, .key = .f16 },
    .{ .code = 0x0068, .key = .f17 },
    .{ .code = 0x0069, .key = .f18 },
    .{ .code = 0x006a, .key = .f19 },
    .{ .code = 0x006b, .key = .f20 },
    .{ .code = 0x006c, .key = .f21 },
    .{ .code = 0x006d, .key = .f22 },
    .{ .code = 0x006e, .key = .f23 },
    .{ .code = 0x0076, .key = .f24 },
    .{ .code = 0xe01c, .key = .numpad_enter },
    .{ .code = 0xe01d, .key = .control_right },
    .{ .code = 0xe035, .key = .numpad_divide },
    .{ .code = 0xe037, .key = .print_screen },
    .{ .code = 0xe038, .key = .alt_right },
    .{ .code = 0xe045, .key = .num_lock },
    .{ .code = 0xe047, .key = .home },
    .{ .code = 0xe048, .key = .arrow_up },
    .{ .code = 0xe049, .key = .page_up },
    .{ .code = 0xe04b, .key = .arrow_left },
    .{ .code = 0xe04d, .key = .arrow_right },
    .{ .code = 0xe04f, .key = .end },
    .{ .code = 0xe050, .key = .arrow_down },
    .{ .code = 0xe051, .key = .page_down },
    .{ .code = 0xe052, .key = .insert },
    .{ .code = 0xe053, .key = .delete },
    .{ .code = 0xe05b, .key = .super_left },
    .{ .code = 0xe05c, .key = .super_right },
    .{ .code = 0xe05d, .key = .menu },
};

// Positions the contract names that a PC keyboard has no scan code for. F25
// exists in USB and evdev and in no Windows table.
const unreachable_keys = [_]events.PhysicalKey{ .unknown, .f25 };

// What the same key reports under a modifier, mapped back to the key. Each is
// a scan code the keyboard emits in place of the plain one, not a key of its
// own (Microsoft, Keyboard Scan Code Specification, the notes on Print Screen
// and Pause).
const aliases = [_]struct { from: u16, to: u16 }{
    // Alt with Print Screen is SysRq, a separate code on the wire.
    .{ .from = 0x0054, .to = 0xe037 },
    // Control with Pause is Break.
    .{ .from = 0xe046, .to = 0x0045 },
    // Some IMEs set the extended flag on the right Shift.
    .{ .from = 0xe036, .to = 0x0036 },
};

// Indexed by the scan code with the extended flag as bit 8, which is the
// layout lParam already has once shifted down by 16. Two pages of 256.
const index_count = 0x200;

fn indexOf(comptime code: u16) u9 {
    const high = code >> 8;
    if (high != 0 and high != 0xe0) @compileError(std.fmt.comptimePrint("not a scan code: 0x{x}", .{code}));
    return @intCast((if (high == 0xe0) @as(u16, 0x100) else 0) | (code & 0xff));
}

const table: [index_count]events.PhysicalKey = table: {
    @setEvalBranchQuota(10_000);
    var result: [index_count]events.PhysicalKey = @splat(.unknown);
    var named: std.enums.EnumSet(events.PhysicalKey) = .empty;

    for (entries) |entry| {
        const index = indexOf(entry.code);
        if (result[index] != .unknown)
            @compileError(std.fmt.comptimePrint("scan code 0x{x} listed twice", .{entry.code}));
        result[index] = entry.key;
        named.insert(entry.key);
    }
    for (aliases) |alias| {
        const index = indexOf(alias.from);
        if (result[index] != .unknown)
            @compileError(std.fmt.comptimePrint("alias 0x{x} hides a listed key", .{alias.from}));
        result[index] = result[indexOf(alias.to)];
    }

    for (unreachable_keys) |key| named.insert(key);
    for (std.enums.values(events.PhysicalKey)) |key| {
        if (!named.contains(key))
            @compileError("no scan code reaches ." ++ @tagName(key));
    }
    break :table result;
};

// The position a key message's lParam names.
pub fn physicalKey(lparam: isize) events.PhysicalKey {
    const bits: usize = @bitCast(lparam);
    return table[@as(u9, @truncate(bits >> 16))];
}
