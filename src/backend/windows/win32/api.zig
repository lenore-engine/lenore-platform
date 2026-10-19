const windows = @import("std").os.windows;

// The user32 and kernel32 surface the Win32 backend calls.
//
// std.os.windows declares the base types and some of ntdll, and none of the
// windowing API, so the rest is declared here. Every prototype, structure and
// constant is transcribed from the MinGW-w64 headers that ship with Zig
// (`lib/libc/include/any-windows-any`: winuser.h, windef.h, winbase.h,
// synchapi.h, handleapi.h, winnt.h), and the header is named beside each group
// so a line can be checked against it on its own.
//
// Only what the backend calls is declared. A declaration nothing calls is a
// signature nothing has checked.

pub const BOOL = windows.BOOL;
pub const DWORD = windows.DWORD;
pub const UINT = windows.UINT;
pub const ATOM = windows.ATOM;
pub const HANDLE = windows.HANDLE;
pub const HINSTANCE = windows.HINSTANCE;
pub const HWND = windows.HWND;
pub const HCURSOR = windows.HCURSOR;
pub const HICON = windows.HICON;
pub const HBRUSH = windows.HBRUSH;
pub const HMENU = windows.HMENU;
pub const LONG_PTR = windows.LONG_PTR;
pub const LPCWSTR = windows.LPCWSTR;
pub const LARGE_INTEGER = windows.LARGE_INTEGER;

// winnt.h / basetsd.h: WPARAM is UINT_PTR, LRESULT and LPARAM are LONG_PTR.
pub const WPARAM = usize;
pub const LPARAM = windows.LPARAM;
pub const LRESULT = LONG_PTR;

// windef.h
pub const RECT = extern struct {
    left: c_long,
    top: c_long,
    right: c_long,
    bottom: c_long,
};

pub const POINT = extern struct {
    x: c_long,
    y: c_long,
};

// windef.h: DPI_AWARENESS_CONTEXT is an opaque handle whose predefined values
// are small negative integers.
pub const DPI_AWARENESS_CONTEXT = *opaque {};
pub const DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2: DPI_AWARENESS_CONTEXT = @ptrFromInt(@as(usize, @bitCast(@as(isize, -4))));

// winuser.h
pub const WNDPROC = *const fn (HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT;

pub const WNDCLASSEXW = extern struct {
    cbSize: UINT = @sizeOf(WNDCLASSEXW),
    style: UINT,
    lpfnWndProc: WNDPROC,
    cbClsExtra: c_int = 0,
    cbWndExtra: c_int = 0,
    hInstance: HINSTANCE,
    hIcon: ?HICON = null,
    hCursor: ?HCURSOR = null,
    hbrBackground: ?HBRUSH = null,
    lpszMenuName: ?LPCWSTR = null,
    lpszClassName: LPCWSTR,
    hIconSm: ?HICON = null,
};

pub const MSG = extern struct {
    hwnd: ?HWND,
    message: UINT,
    wParam: WPARAM,
    lParam: LPARAM,
    time: DWORD,
    pt: POINT,
};

// Messages (winuser.h)
pub const WM_SIZE = 0x0005;
pub const WM_CLOSE = 0x0010;
pub const WM_ERASEBKGND = 0x0014;
pub const WM_DPICHANGED = 0x02e0;

// WM_SIZE wParam (winuser.h)
pub const SIZE_RESTORED = 0;
pub const SIZE_MINIMIZED = 1;
pub const SIZE_MAXIMIZED = 2;

// Class and window styles (winuser.h)
pub const CS_VREDRAW = 0x0001;
pub const CS_HREDRAW = 0x0002;
pub const CS_OWNDC = 0x0020;
pub const WS_OVERLAPPEDWINDOW: DWORD = 0x00C00000 | 0x00080000 | 0x00040000 | 0x00020000 | 0x00010000;
pub const WS_EX_APPWINDOW: DWORD = 0x00040000;
pub const CW_USEDEFAULT: c_int = @bitCast(@as(c_uint, 0x80000000));

// ShowWindow and SetWindowPos (winuser.h)
pub const SW_SHOWNORMAL = 1;
pub const SWP_NOMOVE = 0x0002;
pub const SWP_NOZORDER = 0x0004;
pub const SWP_NOACTIVATE = 0x0010;

pub const GWLP_USERDATA = -21;

// winuser.h: MAKEINTRESOURCE(32512), an integer resource id passed where a
// string pointer is declared.
pub const IDC_ARROW: LPCWSTR = @ptrFromInt(32512);

pub const USER_DEFAULT_SCREEN_DPI = 96;

// Message queue (winuser.h). QS_INPUT is the WINVER >= 0x602 form, which adds
// touch and pointer input to the mouse, key and raw-input bits.
pub const PM_REMOVE = 0x0001;
pub const QS_KEY = 0x0001;
pub const QS_MOUSEMOVE = 0x0002;
pub const QS_MOUSEBUTTON = 0x0004;
pub const QS_POSTMESSAGE = 0x0008;
pub const QS_TIMER = 0x0010;
pub const QS_PAINT = 0x0020;
pub const QS_SENDMESSAGE = 0x0040;
pub const QS_HOTKEY = 0x0080;
pub const QS_RAWINPUT = 0x0400;
pub const QS_TOUCH = 0x0800;
pub const QS_POINTER = 0x1000;
pub const QS_INPUT = QS_MOUSEMOVE | QS_MOUSEBUTTON | QS_KEY | QS_RAWINPUT | QS_TOUCH | QS_POINTER;
pub const QS_ALLINPUT = QS_INPUT | QS_POSTMESSAGE | QS_TIMER | QS_PAINT | QS_HOTKEY | QS_SENDMESSAGE;
pub const MWMO_INPUTAVAILABLE = 0x0004;

// winbase.h, winnt.h
pub const INFINITE: DWORD = 0xffffffff;
pub const WAIT_OBJECT_0: DWORD = 0;
pub const WAIT_FAILED: DWORD = 0xffffffff;

// synchapi.h, winnt.h
pub const CREATE_WAITABLE_TIMER_HIGH_RESOLUTION = 0x2;
pub const SYNCHRONIZE: DWORD = 0x00100000;
pub const TIMER_MODIFY_STATE: DWORD = 0x0002;

pub extern "user32" fn RegisterClassExW(class: *const WNDCLASSEXW) callconv(.winapi) ATOM;
pub extern "user32" fn UnregisterClassW(class_name: LPCWSTR, instance: HINSTANCE) callconv(.winapi) BOOL;
pub extern "user32" fn CreateWindowExW(
    ex_style: DWORD,
    class_name: LPCWSTR,
    window_name: LPCWSTR,
    style: DWORD,
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
    parent: ?HWND,
    menu: ?HMENU,
    instance: HINSTANCE,
    param: ?*anyopaque,
) callconv(.winapi) ?HWND;
pub extern "user32" fn DestroyWindow(window: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn DefWindowProcW(window: HWND, message: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT;
pub extern "user32" fn ShowWindow(window: HWND, command: c_int) callconv(.winapi) BOOL;
pub extern "user32" fn SetWindowPos(
    window: HWND,
    insert_after: ?HWND,
    x: c_int,
    y: c_int,
    cx: c_int,
    cy: c_int,
    flags: UINT,
) callconv(.winapi) BOOL;
pub extern "user32" fn GetClientRect(window: HWND, rect: *RECT) callconv(.winapi) BOOL;
pub extern "user32" fn AdjustWindowRectExForDpi(
    rect: *RECT,
    style: DWORD,
    menu: BOOL,
    ex_style: DWORD,
    dpi: UINT,
) callconv(.winapi) BOOL;
pub extern "user32" fn GetDpiForWindow(window: HWND) callconv(.winapi) UINT;
pub extern "user32" fn SetProcessDpiAwarenessContext(value: DPI_AWARENESS_CONTEXT) callconv(.winapi) BOOL;
pub extern "user32" fn GetWindowLongPtrW(window: HWND, index: c_int) callconv(.winapi) LONG_PTR;
pub extern "user32" fn SetWindowLongPtrW(window: HWND, index: c_int, value: LONG_PTR) callconv(.winapi) LONG_PTR;
pub extern "user32" fn LoadCursorW(instance: ?HINSTANCE, name: LPCWSTR) callconv(.winapi) ?HCURSOR;
pub extern "user32" fn PeekMessageW(
    message: *MSG,
    window: ?HWND,
    filter_min: UINT,
    filter_max: UINT,
    remove: UINT,
) callconv(.winapi) BOOL;
pub extern "user32" fn TranslateMessage(message: *const MSG) callconv(.winapi) BOOL;
pub extern "user32" fn DispatchMessageW(message: *const MSG) callconv(.winapi) LRESULT;
pub extern "user32" fn MsgWaitForMultipleObjectsEx(
    count: DWORD,
    handles: ?[*]const HANDLE,
    milliseconds: DWORD,
    wake_mask: DWORD,
    flags: DWORD,
) callconv(.winapi) DWORD;

pub extern "kernel32" fn CreateWaitableTimerExW(
    attributes: ?*anyopaque,
    name: ?LPCWSTR,
    flags: DWORD,
    access: DWORD,
) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn SetWaitableTimer(
    timer: HANDLE,
    due_time: *const LARGE_INTEGER,
    period: c_long,
    completion: ?*const anyopaque,
    completion_argument: ?*anyopaque,
    resume_system: BOOL,
) callconv(.winapi) BOOL;

// Input
// =====

// Messages (winuser.h)
pub const WM_MOVE = 0x0003;
pub const WM_SETFOCUS = 0x0007;
pub const WM_KILLFOCUS = 0x0008;
pub const WM_SETCURSOR = 0x0020;
pub const WM_INPUT = 0x00FF;
pub const WM_KEYDOWN = 0x0100;
pub const WM_KEYUP = 0x0101;
pub const WM_CHAR = 0x0102;
pub const WM_SYSKEYDOWN = 0x0104;
pub const WM_SYSKEYUP = 0x0105;
pub const WM_SYSCHAR = 0x0106;
pub const WM_SYSCOMMAND = 0x0112;
pub const WM_MOUSEMOVE = 0x0200;
pub const WM_LBUTTONDOWN = 0x0201;
pub const WM_LBUTTONUP = 0x0202;
pub const WM_RBUTTONDOWN = 0x0204;
pub const WM_RBUTTONUP = 0x0205;
pub const WM_MBUTTONDOWN = 0x0207;
pub const WM_MBUTTONUP = 0x0208;
pub const WM_MOUSEWHEEL = 0x020A;
pub const WM_XBUTTONDOWN = 0x020B;
pub const WM_XBUTTONUP = 0x020C;
pub const WM_MOUSEHWHEEL = 0x020E;
pub const WM_CAPTURECHANGED = 0x0215;

pub const SC_KEYMENU = 0xF100;
pub const HTCLIENT = 1;
pub const WHEEL_DELTA = 120;
pub const XBUTTON1 = 0x0001;
pub const XBUTTON2 = 0x0002;
pub const PM_NOREMOVE = 0x0000;

// Virtual keys (winuser.h)
pub const VK_SHIFT = 0x10;
pub const VK_CONTROL = 0x11;
pub const VK_MENU = 0x12;
pub const VK_CAPITAL = 0x14;
pub const VK_LWIN = 0x5B;
pub const VK_RWIN = 0x5C;
pub const VK_NUMLOCK = 0x90;
pub const VK_LSHIFT = 0xA0;
pub const VK_RSHIFT = 0xA1;

pub const MAPVK_VK_TO_VSC_EX = 4;

// GetSystemMetrics (winuser.h)
pub const SM_CXSCREEN = 0;
pub const SM_CYSCREEN = 1;
pub const SM_XVIRTUALSCREEN = 76;
pub const SM_YVIRTUALSCREEN = 77;
pub const SM_CXVIRTUALSCREEN = 78;
pub const SM_CYVIRTUALSCREEN = 79;

// Raw Input (winuser.h, hidusage.h)
pub const HRAWINPUT = *opaque {};
pub const RID_INPUT = 0x10000003;
pub const RIM_INPUT = 0;
pub const RIM_TYPEMOUSE = 0;
pub const RIDEV_REMOVE: DWORD = 0x00000001;
pub const MOUSE_MOVE_ABSOLUTE = 0x01;
pub const MOUSE_VIRTUAL_DESKTOP = 0x02;
pub const HID_USAGE_PAGE_GENERIC = 0x01;
pub const HID_USAGE_GENERIC_MOUSE = 0x02;

pub const RAWINPUTDEVICE = extern struct {
    usUsagePage: u16,
    usUsage: u16,
    dwFlags: DWORD,
    hwndTarget: ?HWND,
};

pub const RAWINPUTHEADER = extern struct {
    dwType: DWORD,
    dwSize: DWORD,
    hDevice: ?HANDLE,
    wParam: WPARAM,
};

// The button fields are a union with one ULONG in the header, which is what
// puts them at offset 4 rather than 2.
pub const RAWMOUSE = extern struct {
    usFlags: u16,
    _union_alignment: u16 = 0,
    usButtonFlags: u16,
    usButtonData: u16,
    ulRawButtons: u32,
    lLastX: c_long,
    lLastY: c_long,
    ulExtraInformation: u32,
};

// RAWINPUT with its data union narrowed to the mouse arm. The union's other
// arms, RAWKEYBOARD and RAWHID, are no larger, so the size is the same.
pub const RAWINPUT_MOUSE = extern struct {
    header: RAWINPUTHEADER,
    mouse: RAWMOUSE,
};

pub extern "user32" fn GetKeyState(key: c_int) callconv(.winapi) c_short;
pub extern "user32" fn MapVirtualKeyW(code: UINT, map_type: UINT) callconv(.winapi) UINT;
pub extern "user32" fn GetMessageTime() callconv(.winapi) c_long;
pub extern "user32" fn SetCapture(window: HWND) callconv(.winapi) ?HWND;
pub extern "user32" fn ReleaseCapture() callconv(.winapi) BOOL;
pub extern "user32" fn SetCursor(cursor: ?HCURSOR) callconv(.winapi) ?HCURSOR;
pub extern "user32" fn ClipCursor(rect: ?*const RECT) callconv(.winapi) BOOL;
pub extern "user32" fn MapWindowPoints(from: ?HWND, to: ?HWND, points: [*]POINT, count: UINT) callconv(.winapi) c_int;
pub extern "user32" fn GetSystemMetrics(index: c_int) callconv(.winapi) c_int;
pub extern "user32" fn RegisterRawInputDevices(
    devices: [*]const RAWINPUTDEVICE,
    count: UINT,
    size: UINT,
) callconv(.winapi) BOOL;
pub extern "user32" fn GetRawInputData(
    raw: HRAWINPUT,
    command: UINT,
    data: ?*anyopaque,
    size: *UINT,
    header_size: UINT,
) callconv(.winapi) UINT;

// Clipboard
// =========

// winuser.h, winbase.h
pub const CF_UNICODETEXT = 13;
pub const GMEM_MOVEABLE = 0x0002;

pub extern "user32" fn OpenClipboard(owner: ?HWND) callconv(.winapi) BOOL;
pub extern "user32" fn CloseClipboard() callconv(.winapi) BOOL;
pub extern "user32" fn EmptyClipboard() callconv(.winapi) BOOL;
pub extern "user32" fn GetClipboardData(format: UINT) callconv(.winapi) ?HANDLE;
pub extern "user32" fn SetClipboardData(format: UINT, memory: ?HANDLE) callconv(.winapi) ?HANDLE;

pub extern "kernel32" fn GlobalAlloc(flags: UINT, bytes: usize) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn GlobalSize(memory: HANDLE) callconv(.winapi) usize;
pub extern "kernel32" fn GlobalLock(memory: HANDLE) callconv(.winapi) ?*anyopaque;
pub extern "kernel32" fn GlobalUnlock(memory: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn GlobalFree(memory: HANDLE) callconv(.winapi) ?HANDLE;

// Fullscreen
// ==========

// winuser.h
pub const GWL_STYLE = -16;
pub const SWP_NOSIZE = 0x0001;
pub const SWP_FRAMECHANGED = 0x0020;
pub const SWP_NOOWNERZORDER = 0x0200;
pub const MONITOR_DEFAULTTONEAREST = 0x00000002;

pub const HMONITOR = *opaque {};

pub const WINDOWPLACEMENT = extern struct {
    length: UINT = @sizeOf(WINDOWPLACEMENT),
    flags: UINT = 0,
    showCmd: UINT = 0,
    ptMinPosition: POINT = .{ .x = 0, .y = 0 },
    ptMaxPosition: POINT = .{ .x = 0, .y = 0 },
    rcNormalPosition: RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
};

pub const MONITORINFO = extern struct {
    cbSize: DWORD = @sizeOf(MONITORINFO),
    rcMonitor: RECT = undefined,
    rcWork: RECT = undefined,
    dwFlags: DWORD = 0,
};

pub extern "user32" fn GetWindowPlacement(window: HWND, placement: *WINDOWPLACEMENT) callconv(.winapi) BOOL;
pub extern "user32" fn SetWindowPlacement(window: HWND, placement: *const WINDOWPLACEMENT) callconv(.winapi) BOOL;
pub extern "user32" fn MonitorFromWindow(window: HWND, flags: DWORD) callconv(.winapi) ?HMONITOR;
pub extern "user32" fn GetMonitorInfoW(monitor: HMONITOR, info: *MONITORINFO) callconv(.winapi) BOOL;
