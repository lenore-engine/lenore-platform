const std = @import("std");
const events = @import("../../../events.zig");
const posix = @import("posix.zig");

// libxkbcommon, bound by hand. Transcribed from xkbcommon.h, xkbcommon-names.h
// and xkbcommon-compose.h of libxkbcommon 1.13.1; re-check with
// `pkg-config --modversion xkbcommon`.
//
// A Wayland compositor sends a keymap and a modifier mask and nothing else: it
// is the client that turns a keycode into a character, and xkbcommon is the
// implementation of the layout, level and compose rules that requires. Nothing
// else here needs the library.

pub const Context = opaque {};
pub const Keymap = opaque {};
pub const State = opaque {};
pub const ComposeTable = opaque {};
pub const ComposeState = opaque {};

pub const Keycode = u32;
pub const Keysym = u32;

// enum xkb_state_component. Only the effective mask is read here: it is the
// union of depressed, latched and locked, which is what "is shift held" means
// to a caller.
const state_mods_effective: c_uint = 1 << 3;

// enum xkb_compose_status.
const ComposeStatus = enum(c_uint) { nothing, composing, composed, cancelled };

// xkbcommon-names.h. Alt and Super have no names of their own in the core
// protocol and are the conventional aliases of Mod1 and Mod4.
const mod_shift = "Shift";
const mod_caps = "Lock";
const mod_control = "Control";
const mod_alt = "Mod1";
const mod_num = "Mod2";
const mod_super = "Mod4";

// The whole keyboard interpretation, from the compositor's keymap down to the
// bytes a text field receives.
pub const Keyboard = struct {
    context: *Context,
    keymap: ?*Keymap = null,
    state: ?*State = null,

    // Dead keys and sequences. Optional by construction: a host with no Compose
    // file for its locale is ordinary, and every key still produces its own
    // character without one.
    compose_table: ?*ComposeTable = null,
    compose_state: ?*ComposeState = null,

    pub fn init() ?Keyboard {
        // No flags: the default include path and the XKB_ environment variables
        // are how a user's own layout is found.
        const context = xkb_context_new(0) orelse {
            std.log.err("xkb: cannot create a context", .{});
            return null;
        };
        var keyboard: Keyboard = .{ .context = context };
        keyboard.openCompose();
        return keyboard;
    }

    pub fn deinit(self: *Keyboard) void {
        self.releaseKeymap();
        if (self.compose_state) |state| xkb_compose_state_unref(state);
        if (self.compose_table) |table| xkb_compose_table_unref(table);
        xkb_context_unref(self.context);
        self.* = undefined;
    }

    fn releaseKeymap(self: *Keyboard) void {
        if (self.state) |state| xkb_state_unref(state);
        if (self.keymap) |keymap| xkb_keymap_unref(keymap);
        self.state = null;
        self.keymap = null;
    }

    fn openCompose(self: *Keyboard) void {
        // The locale the user actually types in. LC_ALL and LC_CTYPE outrank
        // LANG, which is the order setlocale would apply.
        const locale: [*:0]const u8 = std.c.getenv("LC_ALL") orelse
            std.c.getenv("LC_CTYPE") orelse
            std.c.getenv("LANG") orelse
            "C";

        const table = xkb_compose_table_new_from_locale(self.context, locale, 0) orelse {
            std.log.info("xkb: no compose file for locale {s}; dead keys stay literal", .{locale});
            return;
        };
        const state = xkb_compose_state_new(table, 0) orelse {
            xkb_compose_table_unref(table);
            return;
        };
        self.compose_table = table;
        self.compose_state = state;
    }

    // Compiles the keymap the compositor sent, and closes the descriptor it
    // came on whatever happens.
    //
    // MAP_PRIVATE is required from wl_keyboard version 7 onwards and is
    // accepted by every earlier one (wayland.xml, wl_keyboard.keymap).
    pub fn setKeymapFd(self: *Keyboard, fd: i32, size: u32) bool {
        defer _ = posix.close(fd);

        const mapping = std.posix.mmap(
            null,
            size,
            .{ .READ = true },
            .{ .TYPE = .PRIVATE },
            fd,
            0,
        ) catch |err| {
            std.log.err("xkb: cannot map the keymap: {t}", .{err});
            return false;
        };
        defer std.posix.munmap(mapping);

        return self.setKeymap(mapping);
    }

    // `bytes` is the mapping, and the protocol says it is a null-terminated
    // string (wayland.xml, wl_keyboard.keymap_format.xkb_v1). That is checked
    // rather than trusted: it arrives from another process, and the compile
    // below reads until a terminator.
    fn setKeymap(self: *Keyboard, bytes: []const u8) bool {
        if (bytes.len == 0 or bytes[bytes.len - 1] != 0) {
            std.log.err("xkb: the compositor sent an unterminated keymap; keyboard disabled", .{});
            return false;
        }

        const keymap = xkb_keymap_new_from_string(self.context, @ptrCast(bytes.ptr), 1, 0) orelse {
            std.log.err("xkb: the compositor's keymap does not compile; keyboard disabled", .{});
            return false;
        };
        const state = xkb_state_new(keymap) orelse {
            xkb_keymap_unref(keymap);
            return false;
        };

        self.releaseKeymap();
        self.keymap = keymap;
        self.state = state;
        return true;
    }

    pub fn ready(self: *const Keyboard) bool {
        return self.state != null;
    }

    // A Wayland keycode is an evdev code and xkb numbers the same key eight
    // higher (wayland.xml, wl_keyboard.keymap_format.xkb_v1).
    pub fn keycode(wayland_key: u32) Keycode {
        return wayland_key +% 8;
    }

    pub fn updateModifiers(
        self: *Keyboard,
        depressed: u32,
        latched: u32,
        locked: u32,
        group: u32,
    ) void {
        const state = self.state orelse return;
        _ = xkb_state_update_mask(state, depressed, latched, locked, 0, 0, group);
    }

    pub fn modifiers(self: *const Keyboard) events.Modifiers {
        const state = self.state orelse return .{};
        return .{
            .shift = active(state, mod_shift),
            .control = active(state, mod_control),
            .alt = active(state, mod_alt),
            .super = active(state, mod_super),
            .caps_lock = active(state, mod_caps),
            .num_lock = active(state, mod_num),
        };
    }

    fn active(state: *State, name: [*:0]const u8) bool {
        // Negative means the modifier is not in this keymap at all, which is
        // not the same as inactive and is read the same way here.
        return xkb_state_mod_name_is_active(state, name, state_mods_effective) > 0;
    }

    pub fn repeats(self: *const Keyboard, code: Keycode) bool {
        const keymap = self.keymap orelse return false;
        return xkb_keymap_key_repeats(keymap, code) != 0;
    }

    // What a key press should insert, or nothing.
    //
    // The buffer is the caller's because this is called on the event path and
    // the result is copied into a TextChunk immediately. Control characters are
    // dropped: a text field receives what a person typed, and Escape, Return
    // and Ctrl-C reach it as key events instead.
    pub fn text(self: *Keyboard, code: Keycode, buffer: []u8) []const u8 {
        const state = self.state orelse return &.{};

        if (self.compose_state) |compose| {
            const sym = xkb_state_key_get_one_sym(state, code);
            // Feeding is what advances a sequence; a keysym the table does not
            // take leaves the sequence where it was.
            _ = xkb_compose_state_feed(compose, sym);
            switch (xkb_compose_state_get_status(compose)) {
                // Mid-sequence and after a dead end, the key contributes no
                // text of its own.
                .composing => return &.{},
                .cancelled => {
                    xkb_compose_state_reset(compose);
                    return &.{};
                },
                .composed => {
                    const written = xkb_compose_state_get_utf8(compose, buffer.ptr, buffer.len);
                    xkb_compose_state_reset(compose);
                    return printable(buffer, written);
                },
                .nothing => {},
            }
        }

        return printable(buffer, xkb_state_key_get_utf8(state, code, buffer.ptr, buffer.len));
    }

    // Both get_utf8 entry points answer with the length they would have
    // written, so a result that does not fit was truncated and is dropped
    // rather than cut in half.
    fn printable(buffer: []u8, written: c_int) []const u8 {
        if (written <= 0) return &.{};
        const length: usize = @intCast(written);
        if (length >= buffer.len) return &.{};

        const utf8 = buffer[0..length];
        if (length == 1 and (utf8[0] < 0x20 or utf8[0] == 0x7f)) return &.{};
        return utf8;
    }
};

extern fn xkb_context_new(flags: c_uint) ?*Context;
extern fn xkb_context_unref(context: *Context) void;
extern fn xkb_keymap_new_from_string(
    context: *Context,
    string: [*:0]const u8,
    format: c_uint,
    flags: c_uint,
) ?*Keymap;
extern fn xkb_keymap_unref(keymap: *Keymap) void;
extern fn xkb_keymap_key_repeats(keymap: *Keymap, key: Keycode) c_int;
extern fn xkb_state_new(keymap: *Keymap) ?*State;
extern fn xkb_state_unref(state: *State) void;
extern fn xkb_state_update_mask(
    state: *State,
    depressed_mods: u32,
    latched_mods: u32,
    locked_mods: u32,
    depressed_layout: u32,
    latched_layout: u32,
    locked_layout: u32,
) c_uint;
extern fn xkb_state_key_get_utf8(state: *State, key: Keycode, buffer: [*]u8, size: usize) c_int;
extern fn xkb_state_key_get_one_sym(state: *State, key: Keycode) Keysym;
extern fn xkb_state_mod_name_is_active(state: *State, name: [*:0]const u8, type: c_uint) c_int;

extern fn xkb_compose_table_new_from_locale(
    context: *Context,
    locale: [*:0]const u8,
    flags: c_uint,
) ?*ComposeTable;
extern fn xkb_compose_table_unref(table: *ComposeTable) void;
extern fn xkb_compose_state_new(table: *ComposeTable, flags: c_uint) ?*ComposeState;
extern fn xkb_compose_state_unref(state: *ComposeState) void;
extern fn xkb_compose_state_feed(state: *ComposeState, keysym: Keysym) c_uint;
extern fn xkb_compose_state_reset(state: *ComposeState) void;
extern fn xkb_compose_state_get_status(state: *ComposeState) ComposeStatus;
extern fn xkb_compose_state_get_utf8(state: *ComposeState, buffer: [*]u8, size: usize) c_int;
