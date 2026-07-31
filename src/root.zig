const events = @import("events.zig");
const window = @import("window.zig");
const input = @import("input.zig");

pub const Extent2D = @import("types.zig").Extent2D;
pub const Clock = @import("clock.zig").Clock;

pub const Platform = window.Platform;
pub const Window = window.Window;
pub const NativeHandles = window.NativeHandles;
pub const CursorMode = window.CursorMode;
pub const InitError = window.InitError;
pub const CreateWindowError = window.CreateWindowError;
pub const CursorModeError = window.CursorModeError;

pub const Input = input.Input;
pub const InputState = @import("input_state.zig").InputState;
pub const EventQueue = @import("event_queue.zig").EventQueue;
pub const initial_event_capacity = input.initial_event_capacity;
pub const max_event_capacity = input.max_event_capacity;

pub const DeviceId = events.DeviceId;
pub const PhysicalKey = events.PhysicalKey;
pub const NamedKey = events.NamedKey;
pub const KeyAction = events.KeyAction;
pub const Modifiers = events.Modifiers;
pub const KeyEvent = events.KeyEvent;
pub const TextKind = events.TextKind;
pub const TextChunk = events.TextChunk;
pub const CursorEvent = events.CursorEvent;
pub const MouseButton = events.MouseButton;
pub const MouseButtonEvent = events.MouseButtonEvent;
pub const ScrollPhase = events.ScrollPhase;
pub const ScrollSource = events.ScrollSource;
pub const ScrollEvent = events.ScrollEvent;
pub const FocusEvent = events.FocusEvent;
pub const SurfaceMetrics = events.SurfaceMetrics;
pub const Payload = events.Payload;
pub const Event = events.Event;
