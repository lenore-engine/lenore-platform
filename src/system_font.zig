const std = @import("std");

// Which font the host prefers, asked for without naming one.
//
// An application that wants to draw its own interface in the system's font has
// no business knowing what that font is called. What it asks for is a generic
// family, and the answer is whatever the person using the machine configured
// their desktop to use. A path baked into a program is that question answered
// wrongly at build time, on one distribution, for one user.
//
// On Linux the mechanism is fontconfig, which is the thing that resolves
// `sans-serif` against the user's own configuration. Godot does the same in its
// OS layer, in `platform/linuxbsd/os_linuxbsd.cpp`, `get_system_font_path`, and
// this follows its shape: a pattern of family, weight and slant, the
// configuration's substitutions applied to it, then a match.
//
// **fontconfig is loaded at runtime and never linked.** The module then builds
// on a host without its headers, and a host without the library at all answers
// "no system font" instead of failing to start. That is also Godot's
// arrangement, which loads the library through a generated stub rather than
// linking it (`os_linuxbsd.cpp:1342`).
//
// Nothing here is a font. It is a path and a face index inside it, which is
// exactly what a font library needs to open one, and this module has no font
// library and wants none.

// The versioned name, not `libfontconfig.so`. The unversioned symlink belongs
// to the development package and is absent on a machine that only runs
// software.
const library_name = "libfontconfig.so.1";

pub const Error = error{
    // The path does not fit the buffer the caller supplied. A caller sizing its
    // buffer at `std.Io.Dir.max_path_bytes` cannot reach this.
    PathTooLong,
};

// fontconfig's own weight scale, which is not the OS/2 one an application may
// be thinking of: 80 is regular and 200 is bold, against 400 and 700 there.
// The numbers are from `fontconfig.h`, `FC_WEIGHT_*`.
pub const Weight = enum(c_int) {
    thin = 0,
    extralight = 40,
    light = 50,
    book = 75,
    regular = 80,
    medium = 100,
    semibold = 180,
    bold = 200,
    extrabold = 205,
    black = 210,
};

pub const Request = struct {
    // A generic family rather than a name, which is the whole point of asking.
    // `sans-serif`, `serif` and `monospace` are the three a configuration is
    // guaranteed to have an opinion about. A real family name also works and
    // then this is a request for that font in particular.
    family: [:0]const u8 = "sans-serif",

    weight: Weight = .regular,
    italic: bool = false,
};

// How a display's colour stripes are laid out, in fontconfig's own numbering
// (`fontconfig.h`, `FC_RGBA_*`).
//
// Six values rather than a flag, and the shape is not this module's invention:
// `wl_output.geometry` reports the same six for the same question
// (`wayland.xml`, the `subpixel` enum). A compositor answers it per output and
// from the driver rather than from a configuration file, so the day that
// backend exists it fills this same field from a better source.
//
// `unknown` and `none` are different answers. `none` is a display that has no
// stripe order to speak of, and `unknown` is nobody having said.
pub const SubpixelLayout = enum(c_int) {
    unknown = 0,
    rgb = 1,
    bgr = 2,
    vrgb = 3,
    vbgr = 4,
    none = 5,
};

// How much the rasteriser should snap a glyph to the pixel grid, in
// fontconfig's numbering (`fontconfig.h`, `FC_HINT_*`).
pub const HintStyle = enum(c_int) {
    none = 0,
    slight = 1,
    medium = 2,
    full = 3,
};

// What the host says about drawing text, as opposed to which file to open.
//
// Preferences and not measurements. Nothing in fontconfig is read off the
// display: it is where the person using the machine records what they want, and
// a desktop environment writes the same file on their behalf. That is why this
// is reported rather than obeyed here, and why the field names are the
// property names.
//
// A property the match did not carry keeps the value below. Those are this
// module's fallbacks for having no answer, not a claim about what fontconfig
// would have defaulted to.
pub const Rendering = struct {
    // False is a request for no antialiasing at all, which is a rasterisation
    // this project does not produce. A consumer that cannot honour it should
    // say so rather than quietly do something else.
    antialias: bool = true,
    // `hinting` and `hintstyle` say one thing between them, so they are
    // reported as one: `hinting: false` arrives here as `none`. A consumer
    // reading only the style would otherwise hint a face whose owner asked for
    // none.
    hint_style: HintStyle = .slight,
    subpixel: SubpixelLayout = .unknown,
};

// A font on the host: the file, which face inside it, and how the host wants
// text drawn.
//
// The index is not decoration. A collection holds several faces in one file and
// the match names one of them, so dropping it would open whichever face
// happened to be first.
pub const Found = struct {
    // Into the buffer the caller passed. It ends where the path does, and the
    // buffer holds a terminating zero after it for a caller that needs one.
    path: []const u8,
    index: u32,
    rendering: Rendering,
};

// Asks the host for a font, or reports that there is no answer to be had.
//
// Null covers every way this can come to nothing: fontconfig is not installed,
// it is too old to have the symbols, its configuration matched no font. None of
// them is an error the caller can do anything about except draw no text, which
// is a decision it was going to have to make anyway.
//
// Costs a configuration load, which reads the font caches. Milliseconds, and it
// is a startup call.
pub fn find(buffer: []u8, request: Request) Error!?Found {
    var library = std.DynLib.open(library_name) catch return null;
    defer library.close();

    const fc = Fontconfig.load(&library) orelse return null;

    // Our own configuration rather than the process-global one a null argument
    // would lazily create. What we build here we destroy below; the global one
    // can only be freed by `FcFini`, which tears down state belonging to the
    // whole process rather than to this call.
    const config = fc.initLoadConfigAndFonts() orelse return null;
    defer fc.configDestroy(config);

    const pattern = fc.patternCreate() orelse return null;
    defer fc.patternDestroy(pattern);

    _ = fc.patternAddString(pattern, "family", request.family.ptr);
    _ = fc.patternAddInteger(pattern, "weight", @backingInt(request.weight));
    _ = fc.patternAddInteger(pattern, "slant", if (request.italic) slant_italic else slant_roman);
    // A bitmap face has strikes at the sizes it was drawn at and nothing in
    // between, so a rasteriser opened at an arbitrary pixel size fails on one.
    // Scalability is the property that matters here; which outline format it is
    // in is FreeType's business.
    _ = fc.patternAddBool(pattern, "scalable", 1);

    // The two together are what makes this a question about the host rather
    // than about the pattern. The first applies the configuration's rules,
    // which is where `sans-serif` becomes a family the user chose; the second
    // fills in what neither the caller nor the configuration named.
    _ = fc.configSubstitute(config, pattern, match_pattern);
    fc.defaultSubstitute(pattern);

    var result: c_int = 0;
    const match = fc.fontMatch(config, pattern, &result) orelse return null;
    defer fc.patternDestroy(match);
    if (result != result_match) return null;

    var path: [*:0]u8 = undefined;
    if (fc.patternGetString(match, "file", 0, &path) != result_match) return null;

    // The index is optional in the answer even though every match this project
    // has seen carries one. A file with no index is a file with one face.
    var index: c_int = 0;
    if (fc.patternGetInteger(match, "index", 0, &index) != result_match) index = 0;

    const text = std.mem.span(path);
    if (text.len + 1 > buffer.len) return error.PathTooLong;
    @memcpy(buffer[0..text.len], text);
    buffer[text.len] = 0;

    return .{
        // Negative would mean a named instance of a variable font, which is
        // encoded in the high half of the index and is not something this can
        // open. Clamped to the face rather than refused: the wrong weight of
        // the right font is a better answer than no font.
        .path = buffer[0..text.len],
        .index = if (index < 0) 0 else @intCast(index),
        .rendering = renderingOf(fc, match),
    };
}

// The drawing preferences off a resolved match.
//
// Every one is optional, and a missing one leaves `Rendering`'s own fallback
// rather than a zero: zero is a meaningful value in both of these enumerations
// and would be a wrong answer rather than an absent one.
//
// Three properties fontconfig also carries are deliberately not read here.
// `lcdfilter` selects the five-tap filter, which the Harmony renderer this
// project builds ignores, so it is a number nothing could act on. `dpi` and
// `pixelsize` are fontconfig's own defaults unless a desktop set them, and a
// size in this answer would be one an interface had no reason to obey: how
// large its text is follows from its own scale.
fn renderingOf(fc: Fontconfig, match: *const Pattern) Rendering {
    var rendering: Rendering = .{};

    var flag: c_int = 0;
    if (fc.patternGetBool(match, "antialias", 0, &flag) == result_match)
        rendering.antialias = flag != 0;

    var number: c_int = 0;
    if (fc.patternGetInteger(match, "hintstyle", 0, &number) == result_match)
        rendering.hint_style = hintStyleOf(number);
    // After the style, so that it wins: the two are one preference and this is
    // the half that turns the other off.
    if (fc.patternGetBool(match, "hinting", 0, &flag) == result_match and flag == 0)
        rendering.hint_style = .none;

    if (fc.patternGetInteger(match, "rgba", 0, &number) == result_match)
        rendering.subpixel = subpixelOf(number);

    return rendering;
}

// A number fontconfig does not define is `unknown` rather than a value cast
// into range. Both enumerations are open in principle and a future member
// would arrive here as an integer nothing in this build has a meaning for.
fn subpixelOf(value: c_int) SubpixelLayout {
    return switch (value) {
        1 => .rgb,
        2 => .bgr,
        3 => .vrgb,
        4 => .vbgr,
        5 => .none,
        else => .unknown,
    };
}

// An unrecognised style is `slight`, which is what fontconfig's own shipped
// configuration selects and the mode a face is least distorted by.
fn hintStyleOf(value: c_int) HintStyle {
    return switch (value) {
        0 => .none,
        2 => .medium,
        3 => .full,
        else => .slight,
    };
}

// From `fontconfig.h`: `FcResultMatch` and `FcMatchPattern` are the first
// members of their enumerations, and the two slants are 0 and 100.
const result_match: c_int = 0;
const match_pattern: c_int = 0;
const slant_roman: c_int = 0;
const slant_italic: c_int = 100;

// The part of fontconfig this uses, declared rather than translated.
//
// Every type it takes and returns is opaque to us, so what has to be right is
// the argument counts and the two integer widths. `FcBool` is an `int` and
// `FcChar8` is an `unsigned char` (`fontconfig.h`), which is why the strings
// below are byte pointers and the booleans are `c_int`.
//
// A pointer looked up by name is trusted to be the function it names, which is
// what any use of a shared library rests on. The version check that would tell
// us otherwise is `FcGetVersion`, and it cannot be reached before the same
// trust has already been extended to it.
const Config = opaque {};
const Pattern = opaque {};

const Fontconfig = struct {
    initLoadConfigAndFonts: *const fn () callconv(.c) ?*Config,
    configDestroy: *const fn (*Config) callconv(.c) void,
    patternCreate: *const fn () callconv(.c) ?*Pattern,
    patternDestroy: *const fn (*Pattern) callconv(.c) void,
    patternAddString: *const fn (*Pattern, [*:0]const u8, [*:0]const u8) callconv(.c) c_int,
    patternAddInteger: *const fn (*Pattern, [*:0]const u8, c_int) callconv(.c) c_int,
    patternAddBool: *const fn (*Pattern, [*:0]const u8, c_int) callconv(.c) c_int,
    configSubstitute: *const fn (*Config, *Pattern, c_int) callconv(.c) c_int,
    defaultSubstitute: *const fn (*Pattern) callconv(.c) void,
    fontMatch: *const fn (*Config, *Pattern, *c_int) callconv(.c) ?*Pattern,
    patternGetString: *const fn (*const Pattern, [*:0]const u8, c_int, *[*:0]u8) callconv(.c) c_int,
    patternGetInteger: *const fn (*const Pattern, [*:0]const u8, c_int, *c_int) callconv(.c) c_int,
    // `FcBool` is an `int`, so this writes one and not a byte.
    patternGetBool: *const fn (*const Pattern, [*:0]const u8, c_int, *c_int) callconv(.c) c_int,

    // All or nothing: a library missing one of these is not one to call the
    // rest of. Written as a loop over the fields so that adding a symbol above
    // cannot be forgotten here.
    fn load(library: *std.DynLib) ?Fontconfig {
        var self: Fontconfig = undefined;
        inline for (@typeInfo(Fontconfig).@"struct".field_names, @typeInfo(Fontconfig).@"struct".field_types) |field_name, field_type| {
            const symbol = comptime std.fmt.comptimePrint("Fc{c}{s}", .{
                std.ascii.toUpper(field_name[0]),
                field_name[1..],
            });
            @field(self, field_name) = library.lookup(field_type, symbol) orelse return null;
        }
        return self;
    }
};
