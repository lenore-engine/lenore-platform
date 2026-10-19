const std = @import("std");
const windows = std.os.windows;
const system_font = @import("../system_font.zig");

// The host's font on Windows, through DirectWrite.
//
// DirectWrite rather than the font registry, because the question has three
// parts and only DirectWrite answers all of them. The registry's
// `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts` maps display names
// to file names, so a weight or an italic is found by parsing a name, a
// collection lists every face it holds under one file with no index, and
// per-user fonts are under a second key. DirectWrite's system collection
// resolves a family with a weight and a style to one face of one file, the same
// shape as fontconfig's match, and reports the face's index. Godot asks the
// same way (`platform/windows/os_windows.cpp`, `get_system_font_path`).
//
// Windows has no configuration that names a font for a role. `sans-serif` is
// answered with the font the shell uses for message text, which is what the
// person sees across their desktop and the closest thing Windows has to
// fontconfig's answer for it. `serif` and `monospace` have nothing behind
// them, and are answered with the fonts Windows itself uses for those roles.
// Any other name is a family name.
//
// The rendering half comes from the font smoothing settings, which are what the
// ClearType tuner and the "smooth edges of screen fonts" setting write.

// DirectWrite returns COM interfaces, so its shape here is the vtable each one
// begins with, slot by slot in the order dwrite.h declares them (the C
// `...Vtbl` structures in `lib/libc/include/any-windows-any/dwrite.h`). A slot
// this file never calls is an opaque pointer, which keeps the ones after it in
// place without declaring a signature nothing has checked.

const HRESULT = c_long;
const BOOL = windows.BOOL;
const WCHAR = windows.WCHAR;
const Slot = ?*const anyopaque;

fn succeeded(result: HRESULT) bool {
    return result >= 0;
}

// The three IUnknown slots every interface starts with.
fn Unknown(comptime Self: type) type {
    return extern struct {
        QueryInterface: *const fn (*Self, *const windows.GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: Slot,
        Release: *const fn (*Self) callconv(.winapi) u32,
    };
}

fn release(object: anytype) void {
    _ = object.vtable.unknown.Release(object);
}

const Factory = extern struct {
    vtable: *const extern struct {
        unknown: Unknown(Factory),
        GetSystemFontCollection: *const fn (*Factory, *?*FontCollection, BOOL) callconv(.winapi) HRESULT,
    },
};

const FontCollection = extern struct {
    vtable: *const extern struct {
        unknown: Unknown(FontCollection),
        GetFontFamilyCount: Slot,
        GetFontFamily: *const fn (*FontCollection, u32, *?*FontFamily) callconv(.winapi) HRESULT,
        FindFamilyName: *const fn (*FontCollection, [*:0]const WCHAR, *u32, *BOOL) callconv(.winapi) HRESULT,
    },
};

const FontFamily = extern struct {
    vtable: *const extern struct {
        unknown: Unknown(FontFamily),
        GetFontCollection: Slot,
        GetFontCount: Slot,
        GetFont: Slot,
        GetFamilyNames: Slot,
        GetFirstMatchingFont: *const fn (*FontFamily, u32, u32, u32, *?*Font) callconv(.winapi) HRESULT,
    },
};

const Font = extern struct {
    vtable: *const extern struct {
        unknown: Unknown(Font),
        GetFontFamily: Slot,
        GetWeight: Slot,
        GetStretch: Slot,
        GetStyle: Slot,
        IsSymbolFont: Slot,
        GetFaceNames: Slot,
        GetInformationalStrings: Slot,
        GetSimulations: Slot,
        GetMetrics: Slot,
        HasCharacter: Slot,
        CreateFontFace: *const fn (*Font, *?*FontFace) callconv(.winapi) HRESULT,
    },
};

const FontFace = extern struct {
    vtable: *const extern struct {
        unknown: Unknown(FontFace),
        GetType: Slot,
        GetFiles: *const fn (*FontFace, *u32, ?[*]?*FontFile) callconv(.winapi) HRESULT,
        GetIndex: *const fn (*FontFace) callconv(.winapi) u32,
    },
};

const FontFile = extern struct {
    vtable: *const extern struct {
        unknown: Unknown(FontFile),
        GetReferenceKey: *const fn (*FontFile, *?*const anyopaque, *u32) callconv(.winapi) HRESULT,
        GetLoader: *const fn (*FontFile, *?*FontFileLoader) callconv(.winapi) HRESULT,
    },
};

// IDWriteFontFileLoader, queried for the local loader below.
const FontFileLoader = extern struct {
    vtable: *const extern struct {
        unknown: Unknown(FontFileLoader),
    },
};

const LocalFontFileLoader = extern struct {
    vtable: *const extern struct {
        unknown: Unknown(LocalFontFileLoader),
        CreateStreamFromKey: Slot,
        GetFilePathLengthFromKey: *const fn (*LocalFontFileLoader, *const anyopaque, u32, *u32) callconv(.winapi) HRESULT,
        GetFilePathFromKey: *const fn (*LocalFontFileLoader, *const anyopaque, u32, [*]WCHAR, u32) callconv(.winapi) HRESULT,
    },
};

// dwrite.h, DEFINE_GUID(IID_IDWriteFactory, ...) and
// DEFINE_GUID(IID_IDWriteLocalFontFileLoader, ...).
const iid_factory: windows.GUID = .{
    .Data1 = 0xb859ee5a,
    .Data2 = 0xd838,
    .Data3 = 0x4b5b,
    .Data4 = .{ 0xa2, 0xe8, 0x1a, 0xdc, 0x7d, 0x93, 0xdb, 0x48 },
};
const iid_local_loader: windows.GUID = .{
    .Data1 = 0xb2d9f3ec,
    .Data2 = 0xc9fe,
    .Data3 = 0x4a11,
    .Data4 = .{ 0xa2, 0xec, 0xd8, 0x62, 0x08, 0xf7, 0xc0, 0xa2 },
};

// dwrite.h: DWRITE_FACTORY_TYPE_SHARED, DWRITE_FONT_STRETCH_NORMAL and the two
// styles.
const factory_shared = 0;
const stretch_normal = 5;
const style_normal = 0;
const style_italic = 2;

extern "dwrite" fn DWriteCreateFactory(
    factory_type: u32,
    iid: *const windows.GUID,
    factory: *?*Factory,
) callconv(.winapi) HRESULT;

// winuser.h, wingdi.h
const LOGFONTW = extern struct {
    lfHeight: c_long,
    lfWidth: c_long,
    lfEscapement: c_long,
    lfOrientation: c_long,
    lfWeight: c_long,
    lfItalic: u8,
    lfUnderline: u8,
    lfStrikeOut: u8,
    lfCharSet: u8,
    lfOutPrecision: u8,
    lfClipPrecision: u8,
    lfQuality: u8,
    lfPitchAndFamily: u8,
    lfFaceName: [32]WCHAR,
};

const NONCLIENTMETRICSW = extern struct {
    cbSize: u32 = @sizeOf(NONCLIENTMETRICSW),
    iBorderWidth: c_int,
    iScrollWidth: c_int,
    iScrollHeight: c_int,
    iCaptionWidth: c_int,
    iCaptionHeight: c_int,
    lfCaptionFont: LOGFONTW,
    iSmCaptionWidth: c_int,
    iSmCaptionHeight: c_int,
    lfSmCaptionFont: LOGFONTW,
    iMenuWidth: c_int,
    iMenuHeight: c_int,
    lfMenuFont: LOGFONTW,
    lfStatusFont: LOGFONTW,
    lfMessageFont: LOGFONTW,
    iPaddedBorderWidth: c_int,
};

const SPI_GETNONCLIENTMETRICS = 0x0029;
const SPI_GETFONTSMOOTHING = 0x004A;
const SPI_GETFONTSMOOTHINGTYPE = 0x200A;
const SPI_GETFONTSMOOTHINGORIENTATION = 0x2012;
const FE_FONTSMOOTHINGCLEARTYPE = 0x0002;
const FE_FONTSMOOTHINGORIENTATIONBGR = 0x0000;

extern "user32" fn SystemParametersInfoW(action: u32, parameter: u32, value: ?*anyopaque, update: u32) callconv(.winapi) BOOL;

// The Windows fonts for the two roles no setting covers: Times New Roman is
// the serif face every Windows release has carried, and Consolas is the
// monospace face Windows uses for its own console and editors.
const serif_family = std.unicode.utf8ToUtf16LeStringLiteral("Times New Roman");
const monospace_family = std.unicode.utf8ToUtf16LeStringLiteral("Consolas");

pub fn find(buffer: []u8, request: system_font.Request) system_font.Error!?system_font.Found {
    var factory: ?*Factory = null;
    if (!succeeded(DWriteCreateFactory(factory_shared, &iid_factory, &factory))) return null;
    defer release(factory.?);

    var collection: ?*FontCollection = null;
    if (!succeeded(factory.?.vtable.GetSystemFontCollection(factory.?, &collection, .FALSE))) return null;
    defer release(collection.?);

    // The family as UTF-16. A name longer than a face name field holds is not
    // a family any font carries.
    var name: [64:0]WCHAR = undefined;
    const family = familyFor(request.family, &name) orelse return null;

    var index: u32 = 0;
    var exists: BOOL = .FALSE;
    if (!succeeded(collection.?.vtable.FindFamilyName(collection.?, family, &index, &exists))) return null;
    if (!exists.toBool()) {
        // fontconfig answers an unknown family with a substitute rather than
        // nothing, which keeps a missing font a drawing decision rather than
        // an error. The desktop's font is the substitute here.
        const fallback = messageFont(&name) orelse return null;
        if (!succeeded(collection.?.vtable.FindFamilyName(collection.?, fallback, &index, &exists))) return null;
        if (!exists.toBool()) return null;
    }

    var font_family: ?*FontFamily = null;
    if (!succeeded(collection.?.vtable.GetFontFamily(collection.?, index, &font_family))) return null;
    defer release(font_family.?);

    // The nearest face in the family. A family without the weight asked for
    // answers with its closest one, and one without an italic may answer with
    // a simulated slant of the upright, whose file is the upright's.
    var font: ?*Font = null;
    if (!succeeded(font_family.?.vtable.GetFirstMatchingFont(
        font_family.?,
        weightOf(request.weight),
        stretch_normal,
        if (request.italic) style_italic else style_normal,
        &font,
    ))) return null;
    defer release(font.?);

    var face: ?*FontFace = null;
    if (!succeeded(font.?.vtable.CreateFontFace(font.?, &face))) return null;
    defer release(face.?);

    // One file per face is what a path can name. A face split over several,
    // as a Type 1 font's outline and metrics are, is not one this can answer
    // with.
    var file_count: u32 = 0;
    if (!succeeded(face.?.vtable.GetFiles(face.?, &file_count, null)) or file_count != 1) return null;
    var files: [1]?*FontFile = .{null};
    if (!succeeded(face.?.vtable.GetFiles(face.?, &file_count, &files))) return null;
    const file = files[0] orelse return null;
    defer release(file);

    const path_length = try pathOf(file, buffer) orelse return null;

    return .{
        .path = buffer[0..path_length],
        .index = face.?.vtable.GetIndex(face.?),
        .rendering = rendering(),
    };
}

// The path of a file the system collection holds, written into `buffer` as
// WTF-8, the encoding std's Windows paths are in, with a zero after it.
fn pathOf(file: *FontFile, buffer: []u8) system_font.Error!?usize {
    var key: ?*const anyopaque = null;
    var key_size: u32 = 0;
    if (!succeeded(file.vtable.GetReferenceKey(file, &key, &key_size))) return null;

    var loader: ?*FontFileLoader = null;
    if (!succeeded(file.vtable.GetLoader(file, &loader))) return null;
    defer release(loader.?);

    // Only a file on disk has a path. The system collection's files are, but
    // the loader is asked rather than assumed.
    var local_raw: ?*anyopaque = null;
    if (!succeeded(loader.?.vtable.unknown.QueryInterface(loader.?, &iid_local_loader, &local_raw))) return null;
    const local: *LocalFontFileLoader = @ptrCast(@alignCast(local_raw.?));
    defer release(local);

    var length: u32 = 0;
    if (!succeeded(local.vtable.GetFilePathLengthFromKey(local, key.?, key_size, &length))) return null;

    // The length excludes the terminator and the call writes one.
    var wide: [windows.PATH_MAX_WIDE + 1]WCHAR = undefined;
    if (length + 1 > wide.len) return error.PathTooLong;
    if (!succeeded(local.vtable.GetFilePathFromKey(local, key.?, key_size, &wide, length + 1))) return null;

    const units = wide[0..length];
    const size = std.unicode.calcWtf8Len(units);
    if (size + 1 > buffer.len) return error.PathTooLong;
    _ = std.unicode.wtf16LeToWtf8(buffer[0..size], units);
    buffer[size] = 0;
    return size;
}

fn familyFor(requested: [:0]const u8, name: *[64:0]WCHAR) ?[*:0]const WCHAR {
    if (std.mem.eql(u8, requested, "sans-serif")) return messageFont(name);
    if (std.mem.eql(u8, requested, "serif")) return serif_family;
    if (std.mem.eql(u8, requested, "monospace")) return monospace_family;

    const needed = std.unicode.calcUtf16LeLen(requested) catch return null;
    if (needed > name.len) return null;
    const length = std.unicode.utf8ToUtf16Le(name, requested) catch return null;
    name[length] = 0;
    return name[0..length :0];
}

// The face the shell draws message boxes and most of its own text in, which a
// person changes through the system's text settings.
fn messageFont(name: *[64:0]WCHAR) ?[*:0]const WCHAR {
    var metrics: NONCLIENTMETRICSW = undefined;
    metrics.cbSize = @sizeOf(NONCLIENTMETRICSW);
    if (!SystemParametersInfoW(SPI_GETNONCLIENTMETRICS, @sizeOf(NONCLIENTMETRICSW), &metrics, 0).toBool()) return null;

    const face = &metrics.lfMessageFont.lfFaceName;
    const length = std.mem.indexOfScalar(WCHAR, face, 0) orelse face.len;
    if (length == 0) return null;
    @memcpy(name[0..length], face[0..length]);
    name[length] = 0;
    return name[0..length :0];
}

// fontconfig's weights onto the OS/2 scale DirectWrite uses (dwrite.h,
// DWRITE_FONT_WEIGHT). `book` is fontconfig's 75, which sits between light and
// regular as DirectWrite's semi-light does.
fn weightOf(weight: system_font.Weight) u32 {
    return switch (weight) {
        .thin => 100,
        .extralight => 200,
        .light => 300,
        .book => 350,
        .regular => 400,
        .medium => 500,
        .semibold => 600,
        .bold => 700,
        .extrabold => 800,
        .black => 900,
    };
}

// The font smoothing settings, read as the three answers fontconfig gives.
//
// Windows records whether text is smoothed, whether smoothing is ClearType or
// greyscale, and which way the panel's stripes run. It records no hinting
// preference, so the style is inferred from the mode: ClearType as DirectWrite
// draws it hints only vertically, which is FreeType's slight hinting, and
// greyscale smoothing is GDI's, which hints fully.
fn rendering() system_font.Rendering {
    var result: system_font.Rendering = .{};

    var smoothing: BOOL = .TRUE;
    if (SystemParametersInfoW(SPI_GETFONTSMOOTHING, 0, &smoothing, 0).toBool() and !smoothing.toBool()) {
        result.antialias = false;
        result.hint_style = .full;
        result.subpixel = .none;
        return result;
    }

    var kind: u32 = 0;
    if (!SystemParametersInfoW(SPI_GETFONTSMOOTHINGTYPE, 0, &kind, 0).toBool()) return result;
    if (kind != FE_FONTSMOOTHINGCLEARTYPE) {
        result.hint_style = .full;
        result.subpixel = .none;
        return result;
    }

    result.hint_style = .slight;
    var orientation: u32 = 0;
    if (SystemParametersInfoW(SPI_GETFONTSMOOTHINGORIENTATION, 0, &orientation, 0).toBool())
        result.subpixel = if (orientation == FE_FONTSMOOTHINGORIENTATIONBGR) .bgr else .rgb;
    return result;
}
