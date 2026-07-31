const std = @import("std");
const Extent2D = @import("types.zig").Extent2D;

// Canonical positions (USB HID / W3C); runs a..z, digits, f1..f25, numpad must stay contiguous and ordered.
pub const PhysicalKey = enum(u8) {
    unknown = 0,
    a,
    b,
    c,
    d,
    e,
    f,
    g,
    h,
    i,
    j,
    k,
    l,
    m,
    n,
    o,
    p,
    q,
    r,
    s,
    t,
    u,
    v,
    w,
    x,
    y,
    z,
    digit_0,
    digit_1,
    digit_2,
    digit_3,
    digit_4,
    digit_5,
    digit_6,
    digit_7,
    digit_8,
    digit_9,
    space,
    apostrophe,
    comma,
    minus,
    period,
    slash,
    semicolon,
    equal,
    left_bracket,
    backslash,
    right_bracket,
    grave,
    escape,
    enter,
    tab,
    backspace,
    insert,
    delete,
    arrow_right,
    arrow_left,
    arrow_down,
    arrow_up,
    page_up,
    page_down,
    home,
    end,
    caps_lock,
    scroll_lock,
    num_lock,
    print_screen,
    pause,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
    f13,
    f14,
    f15,
    f16,
    f17,
    f18,
    f19,
    f20,
    f21,
    f22,
    f23,
    f24,
    f25,
    numpad_0,
    numpad_1,
    numpad_2,
    numpad_3,
    numpad_4,
    numpad_5,
    numpad_6,
    numpad_7,
    numpad_8,
    numpad_9,
    numpad_decimal,
    numpad_divide,
    numpad_multiply,
    numpad_subtract,
    numpad_add,
    numpad_enter,
    numpad_equal,
    shift_left,
    control_left,
    alt_left,
    super_left,
    shift_right,
    control_right,
    alt_right,
    super_right,
    menu,
};

// Named non-text key identity. Printable input is delivered via TextChunk.
pub const NamedKey = enum(u8) {
    unidentified,
    escape,
    enter,
    tab,
    backspace,
    insert,
    delete,
    arrow_right,
    arrow_left,
    arrow_down,
    arrow_up,
    page_up,
    page_down,
    home,
    end,
};

pub const DeviceId = enum(u16) { primary = 0, _ };

pub const KeyAction = enum(u8) { press, repeat, release };

// Modifier state at event time (not pump time).
// Filled by backends from the same native callback.
pub const Modifiers = packed struct(u8) {
    shift: bool = false,
    control: bool = false,
    alt: bool = false,
    super: bool = false,
    caps_lock: bool = false,
    num_lock: bool = false,
    _padding: u2 = 0,
};

pub const KeyEvent = struct {
    device: DeviceId = .primary,
    physical: PhysicalKey,
    logical: NamedKey = .unidentified,
    action: KeyAction,
    modifiers: Modifiers = .{},
};

pub const TextKind = enum(u8) { commit, preedit };

// `bytes` is 16: Unicode Standard Annex #29 grapheme clusters can contain
// multiple codepoints. `zglfw.zig`, CharFn delivers one u32 per callback, but
// that backend shape does not narrow the cross-backend text contract.
// TextChunk is the largest payload, so growing `bytes` widens every Event.
pub const TextChunk = struct {
    transaction: u32,
    kind: TextKind,
    begin: bool,
    end: bool,
    len: u8,
    bytes: [16]u8,
};

pub const CursorEvent = struct {
    device: DeviceId = .primary,
    logical_position: [2]f32,
    metrics_generation: u32,
};

pub const MouseButton = enum(u8) { left, right, middle, back, forward, other };

pub const MouseButtonEvent = struct {
    device: DeviceId = .primary,
    button: MouseButton,
    action: KeyAction,
    modifiers: Modifiers = .{},
    // Atomic event location. Consumers must not substitute the final cursor
    // position of the batch, which may be separated by later motion.
    logical_position: [2]f32,
    metrics_generation: u32,
};

pub const ScrollPhase = enum(u8) { begin, update, end };
pub const ScrollSource = enum(u8) { wheel, finger, continuous, unknown };

pub const ScrollEvent = struct {
    device: DeviceId = .primary,
    pixel_delta: [2]f32 = .{ 0, 0 },
    line_delta: [2]f32 = .{ 0, 0 },
    phase: ScrollPhase = .update,
    source: ScrollSource = .unknown,
};

pub const FocusEvent = struct { focused: bool };

// Atomic logical/framebuffer/scale snapshot. `generation` increments with each
// one and is what cursor events refer back to.
pub const SurfaceMetrics = struct {
    logical_size: [2]f32,
    framebuffer_extent: Extent2D,
    // UI content/DPI scale. The pointer-to-framebuffer mapping uses the exact
    // framebuffer_extent/logical_size ratio instead, to account for the integer
    // rounding the compositor already applied.
    scale: [2]f32,
    generation: u32,
};

pub const Payload = union(enum) {
    key: KeyEvent,
    text: TextChunk,
    cursor: CursorEvent,
    mouse_button: MouseButtonEvent,
    scroll: ScrollEvent,
    focus: FocusEvent,
    surface_metrics: SurfaceMetrics,
};

pub const Event = struct {
    // Monotonic, and deliberately not dense: the queue advances it on every
    // submit, including ones it coalesces or drops. Compare sequences, never
    // subtract them for a count.
    sequence: u64,
    timestamp_ns: u64,
    payload: Payload,
};

comptime {
    // Measured. TextChunk is the largest payload at 24 bytes, making
    // Payload 32 bytes and Event 48 bytes, so every 1024 events the queue
    // holds cost 48 KiB. This assert ensures that any payload growth is
    // acknowledged where that cost is paid.
    std.debug.assert(@sizeOf(Event) == 48);
}
