const events = @import("../../../events.zig");

// Evdev codes to the canonical positions in events.zig.
//
// A Wayland key event carries the code the kernel gave the device, not a
// character and not a layout position (wayland.xml, wl_keyboard.key). The codes
// are transcribed from linux/input-event-codes.h with the kernel's own name
// beside each one, so a line can be checked against that header on its own.
// Arithmetic over runs is deliberately not used: the two orders agree in places
// and diverge in others, and a run that looked contiguous is how a whole block
// of keys ends up one position out.
//
// A code with no position here is a key this contract does not name. It is
// reported as `unknown`, which still carries the press and release.

pub fn physicalKey(code: u32) events.PhysicalKey {
    return switch (code) {
        1 => .escape, // KEY_ESC
        2 => .digit_1, // KEY_1
        3 => .digit_2, // KEY_2
        4 => .digit_3, // KEY_3
        5 => .digit_4, // KEY_4
        6 => .digit_5, // KEY_5
        7 => .digit_6, // KEY_6
        8 => .digit_7, // KEY_7
        9 => .digit_8, // KEY_8
        10 => .digit_9, // KEY_9
        11 => .digit_0, // KEY_0
        12 => .minus, // KEY_MINUS
        13 => .equal, // KEY_EQUAL
        14 => .backspace, // KEY_BACKSPACE
        15 => .tab, // KEY_TAB
        16 => .q, // KEY_Q
        17 => .w, // KEY_W
        18 => .e, // KEY_E
        19 => .r, // KEY_R
        20 => .t, // KEY_T
        21 => .y, // KEY_Y
        22 => .u, // KEY_U
        23 => .i, // KEY_I
        24 => .o, // KEY_O
        25 => .p, // KEY_P
        26 => .left_bracket, // KEY_LEFTBRACE
        27 => .right_bracket, // KEY_RIGHTBRACE
        28 => .enter, // KEY_ENTER
        29 => .control_left, // KEY_LEFTCTRL
        30 => .a, // KEY_A
        31 => .s, // KEY_S
        32 => .d, // KEY_D
        33 => .f, // KEY_F
        34 => .g, // KEY_G
        35 => .h, // KEY_H
        36 => .j, // KEY_J
        37 => .k, // KEY_K
        38 => .l, // KEY_L
        39 => .semicolon, // KEY_SEMICOLON
        40 => .apostrophe, // KEY_APOSTROPHE
        41 => .grave, // KEY_GRAVE
        42 => .shift_left, // KEY_LEFTSHIFT
        43 => .backslash, // KEY_BACKSLASH
        44 => .z, // KEY_Z
        45 => .x, // KEY_X
        46 => .c, // KEY_C
        47 => .v, // KEY_V
        48 => .b, // KEY_B
        49 => .n, // KEY_N
        50 => .m, // KEY_M
        51 => .comma, // KEY_COMMA
        52 => .period, // KEY_DOT
        53 => .slash, // KEY_SLASH
        54 => .shift_right, // KEY_RIGHTSHIFT
        55 => .numpad_multiply, // KEY_KPASTERISK
        56 => .alt_left, // KEY_LEFTALT
        57 => .space, // KEY_SPACE
        58 => .caps_lock, // KEY_CAPSLOCK
        59 => .f1, // KEY_F1
        60 => .f2, // KEY_F2
        61 => .f3, // KEY_F3
        62 => .f4, // KEY_F4
        63 => .f5, // KEY_F5
        64 => .f6, // KEY_F6
        65 => .f7, // KEY_F7
        66 => .f8, // KEY_F8
        67 => .f9, // KEY_F9
        68 => .f10, // KEY_F10
        69 => .num_lock, // KEY_NUMLOCK
        70 => .scroll_lock, // KEY_SCROLLLOCK
        71 => .numpad_7, // KEY_KP7
        72 => .numpad_8, // KEY_KP8
        73 => .numpad_9, // KEY_KP9
        74 => .numpad_subtract, // KEY_KPMINUS
        75 => .numpad_4, // KEY_KP4
        76 => .numpad_5, // KEY_KP5
        77 => .numpad_6, // KEY_KP6
        78 => .numpad_add, // KEY_KPPLUS
        79 => .numpad_1, // KEY_KP1
        80 => .numpad_2, // KEY_KP2
        81 => .numpad_3, // KEY_KP3
        82 => .numpad_0, // KEY_KP0
        83 => .numpad_decimal, // KEY_KPDOT
        87 => .f11, // KEY_F11
        88 => .f12, // KEY_F12
        96 => .numpad_enter, // KEY_KPENTER
        97 => .control_right, // KEY_RIGHTCTRL
        98 => .numpad_divide, // KEY_KPSLASH
        99 => .print_screen, // KEY_SYSRQ
        100 => .alt_right, // KEY_RIGHTALT
        102 => .home, // KEY_HOME
        103 => .arrow_up, // KEY_UP
        104 => .page_up, // KEY_PAGEUP
        105 => .arrow_left, // KEY_LEFT
        106 => .arrow_right, // KEY_RIGHT
        107 => .end, // KEY_END
        108 => .arrow_down, // KEY_DOWN
        109 => .page_down, // KEY_PAGEDOWN
        110 => .insert, // KEY_INSERT
        111 => .delete, // KEY_DELETE
        117 => .numpad_equal, // KEY_KPEQUAL
        119 => .pause, // KEY_PAUSE
        125 => .super_left, // KEY_LEFTMETA
        126 => .super_right, // KEY_RIGHTMETA
        127 => .menu, // KEY_COMPOSE, the context menu key on a PC keyboard
        139 => .menu, // KEY_MENU
        183 => .f13, // KEY_F13
        184 => .f14, // KEY_F14
        185 => .f15, // KEY_F15
        186 => .f16, // KEY_F16
        187 => .f17, // KEY_F17
        188 => .f18, // KEY_F18
        189 => .f19, // KEY_F19
        190 => .f20, // KEY_F20
        191 => .f21, // KEY_F21
        192 => .f22, // KEY_F22
        193 => .f23, // KEY_F23
        194 => .f24, // KEY_F24
        else => .unknown,
    };
}

// The layout-independent identity of a non-text key. Printable keys carry no
// named identity: what they insert arrives as a TextChunk, which is the only
// thing that knows the layout.
pub fn namedKey(key: events.PhysicalKey) events.NamedKey {
    return switch (key) {
        .escape => .escape,
        .enter, .numpad_enter => .enter,
        .tab => .tab,
        .backspace => .backspace,
        .insert => .insert,
        .delete => .delete,
        .arrow_right => .arrow_right,
        .arrow_left => .arrow_left,
        .arrow_down => .arrow_down,
        .arrow_up => .arrow_up,
        .page_up => .page_up,
        .page_down => .page_down,
        .home => .home,
        .end => .end,
        else => .unidentified,
    };
}

// Evdev button codes, from the BTN_ block of the same header.
//
// A mouse reports two pairs of side buttons and a given mouse uses one pair or
// the other, so both map onto the same two names.
pub fn mouseButton(code: u32) events.MouseButton {
    return switch (code) {
        0x110 => .left, // BTN_LEFT
        0x111 => .right, // BTN_RIGHT
        0x112 => .middle, // BTN_MIDDLE
        0x113 => .back, // BTN_SIDE
        0x114 => .forward, // BTN_EXTRA
        0x115 => .forward, // BTN_FORWARD
        0x116 => .back, // BTN_BACK
        else => .other,
    };
}
