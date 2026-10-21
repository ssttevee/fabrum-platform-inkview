//! The InkView functions this package calls, typed, and how they are
//! reached: resolved at run time from `libinkview.so` with `std.DynLib`
//! (`Api.load`), so nothing of the SDK is linked and a function a firmware
//! lacks is null only when it is optional in `Api`. A missing required
//! function fails loading with `error.MissingSymbol`.
//!
//! Only what the host needs is bound; signatures and constants come from
//! `sdk/6.10/B288/include/inkview.h` (the Verse's firmware line) and
//! libinkview's `docs/api/*.md`. The `par1`/`par2` meanings of events and
//! the behaviour of each update function are in `events.md` and
//! `graphics-update.md`. Every symbol here is exported by 6.5 through 6.11
//! except where noted in `Api`.
const std = @import("std");

const log = std.log.scoped(.inkview);

/// `iv_handler`: the application's event handler. Returns non-zero when it
/// handled the event; zero lets the library apply its default action.
pub const Handler = *const fn (kind: c_int, par1: c_int, par2: c_int) callconv(.c) c_int;
/// `iv_timerproc`: a one-shot timer, cleared before it runs.
pub const TimerProc = *const fn () callconv(.c) void;
/// `iv_dialoghandler`: 1, 2 or 3 for the button pressed, -1 when dismissed.
pub const DialogHandler = *const fn (button: c_int) callconv(.c) void;
/// `iv_menuhandler`: the chosen item's `index`, or -1.
pub const MenuHandler = *const fn (index: c_int) callconv(.c) void;
/// `iv_keyboardhandler`: the buffer on OK, null when cancelled.
pub const KeyboardHandler = *const fn (text: ?[*:0]u8) callconv(.c) void;
/// `iv_dirselecthandler`: the chosen path.
pub const DirHandler = *const fn (path: ?[*:0]u8) callconv(.c) void;

/// `icanvas`: a drawing target. `GetCanvas()` returns the task
/// framebuffer by default: `depth` 8 is one gray byte per pixel (0 black,
/// 255 white), rows `scanline` bytes apart, which may be more than
/// `width`.
pub const Canvas = extern struct {
    width: c_int,
    height: c_int,
    scanline: c_int,
    depth: c_int,
    clipx1: c_int,
    clipx2: c_int,
    clipy1: c_int,
    clipy2: c_int,
    addr: ?[*]u8,
};

/// `imenu`: one entry of a popup menu; an array ends with `type == .end`.
pub const MenuItem = extern struct {
    type: Type,
    index: c_short,
    text: ?[*:0]u8,
    submenu: ?[*]MenuItem,

    /// `ITEM_*`: what an entry is. Non-exhaustive: the header has style
    /// bits above `ITEM_TYPEMASK` the host never sets.
    pub const Type = enum(c_short) {
        end = 0,
        header = 1,
        active = 2,
        inactive = 3,
        submenu = 5,
        separator = 6,
        bullet = 7,
        _,
    };

    pub const end: MenuItem = .{ .type = .end, .index = 0, .text = null, .submenu = null };
};

/// `EVT_*`: what the handler is called with. Non-exhaustive: the library
/// sends many more, which the host ignores.
pub const Event = enum(c_int) {
    init = 21,
    exit = 22,
    show = 23,
    hide = 24,
    key_press = 25,
    key_release = 26,
    key_repeat = 28,
    pointer_up = 29,
    pointer_down = 30,
    pointer_move = 31,
    orientation = 32,
    pointer_long = 34,
    pointer_hold = 35,
    activate = 38,
    mt_sync = 39,
    repaint = 43,
    pointer_drag = 44,
    pointer_cancel = 45,
    prev_page = 91,
    next_page = 92,
    update = 95,
    foreground = 151,
    background = 152,
    config_changed = 154,
    /// `EVT_CUSTOM`: the first event number an app may use for itself.
    custom = 1024,
    _,
};

/// `IV_KEY_*`: `par1` of the key events. On the Verse the page keys are
/// `prev` (0x18) and `next` (0x19), as the user's earlier app saw them
/// (24 and 25).
pub const Key = enum(c_int) {
    power = 0x01,
    delete = 0x08,
    tab = 0x09,
    ok = 0x0a,
    up = 0x11,
    down = 0x12,
    left = 0x13,
    right = 0x14,
    minus = 0x15,
    plus = 0x16,
    menu = 0x17,
    prev = 0x18,
    next = 0x19,
    home = 0x1a,
    back = 0x1b,
    prev2 = 0x1c,
    next2 = 0x1d,
    _,
};

/// `SetOrientation` values. 1 and 2 are the two landscapes (the sources
/// disagree on which way each turns), 3 is upside-down portrait.
pub const Orientation = enum(c_int) {
    portrait = 0,
    landscape_90 = 1,
    landscape_270 = 2,
    portrait_180 = 3,
    _,

    /// Whether the screen is wider than it is tall.
    pub fn isLandscape(o: Orientation) bool {
        return o == .landscape_90 or o == .landscape_270;
    }
};

/// The `icon` argument of `Message` and `Dialog3`: `ICON_*` in the low
/// bits, `DEF_BUTTONn`, `NO_DISMISS` and `DLG_HW_BUTTON` above.
pub const DialogIcon = packed struct(u32) {
    kind: Kind,
    /// The button highlighted first.
    default: enum(u2) { first = 0, second = 1, third = 2 } = .first,
    _reserved: u1 = 0,
    /// Don't restore the screen under the dialog when it closes.
    no_dismiss: bool = false,
    /// Let the page keys press the first and last buttons on touch devices.
    hw_button: bool = false,
    _padding: u15 = 0,

    pub const Kind = enum(u12) {
        information = 1,
        question = 2,
        warning = 3,
        @"error" = 4,
        _,
    };
};

/// `KBD_*`: `OpenKeyboard` flags: one layout in the low nibble, options
/// above.
pub const KeyboardFlags = packed struct(u32) {
    layout: Layout = .normal,
    _reserved: u4 = 0,
    password: bool = false,
    /// Typing appends to the initial text instead of replacing it.
    noselect: bool = false,
    _reserved2: u2 = 0,
    /// No `EVT_SHOW` to the restored handler when the keyboard closes.
    no_evt_show: bool = false,
    _reserved3: u3 = 0,
    /// No screen refresh when the keyboard closes.
    no_update_after_close: bool = false,
    _padding: u15 = 0,

    pub const Layout = enum(u4) {
        normal = 0,
        entext = 1,
        numeric = 4,
        url = 7,
        _,
    };
};

/// `PANEL_*`: `SetPanelType` flags; all clear is `PANEL_DISABLED`.
pub const PanelType = packed struct(u32) {
    _reserved: u1 = 0,
    enabled: bool = false,
    event_no_handling: bool = false,
    no_fb_offset: bool = false,
    no_self_update: bool = false,
    _padding: u27 = 0,

    pub const disabled: PanelType = .{};
};

/// `IMAGE_GRAY8`: `Stretch`'s source format for one gray byte per pixel.
pub const image_gray8: c_int = 8;

/// The functions the host calls, as pointers into `libinkview.so`.
/// Required ones (plain pointers) exist in every version from 5.2 on;
/// `load` fails without them. Optional ones (`?`) may be missing on some
/// firmware, and the host does without: see each.
pub const Api = struct {
    // the loop and the app
    InkViewMain: *const fn (Handler) callconv(.c) void,
    CloseApp: *const fn () callconv(.c) void,
    SendEvent: *const fn (Handler, c_int, c_int, c_int) callconv(.c) void,
    SetHardTimer: *const fn ([*:0]const u8, TimerProc, c_int) callconv(.c) void,
    SetWeakTimer: *const fn ([*:0]const u8, TimerProc, c_int) callconv(.c) void,
    ClearTimer: *const fn (TimerProc) callconv(.c) void,

    // the screen
    ScreenWidth: *const fn () callconv(.c) c_int,
    ScreenHeight: *const fn () callconv(.c) c_int,
    GetCanvas: *const fn () callconv(.c) ?*Canvas,
    SetOrientation: *const fn (Orientation) callconv(.c) void,
    SetPanelType: *const fn (PanelType) callconv(.c) void,
    PanelHeight: *const fn () callconv(.c) c_int,
    Stretch: *const fn ([*]const u8, c_int, c_int, c_int, c_int, c_int, c_int, c_int, c_int, c_int) callconv(.c) void,

    // updates
    FullUpdate: *const fn () callconv(.c) void,
    PartialUpdate: *const fn (c_int, c_int, c_int, c_int) callconv(.c) void,

    // services
    Message: *const fn (DialogIcon, [*:0]const u8, [*:0]const u8, c_int) callconv(.c) void,
    Dialog3: *const fn (DialogIcon, [*:0]const u8, [*:0]const u8, ?[*:0]const u8, ?[*:0]const u8, ?[*:0]const u8, DialogHandler) callconv(.c) void,
    OpenMenu: *const fn ([*]MenuItem, c_int, c_int, c_int, MenuHandler) callconv(.c) void,
    OpenKeyboard: *const fn ([*:0]const u8, [*:0]u8, c_int, KeyboardFlags, KeyboardHandler) callconv(.c) void,

    // optional
    /// Without it, `interactive` refreshes use `DynamicUpdate` or
    /// `PartialUpdate`.
    DynamicUpdateA2: ?*const fn (c_int, c_int, c_int, c_int) callconv(.c) void = null,
    DynamicUpdate: ?*const fn (c_int, c_int, c_int, c_int) callconv(.c) void = null,
    /// 5.14+. Without it the scale comes from `Options.dpi`.
    get_screen_dpi: ?*const fn () callconv(.c) c_int = null,
    /// Removed in 6.8: without it `openDirectory` is unsupported.
    OpenDirectorySelector: ?*const fn ([*:0]const u8, [*:0]u8, c_int, DirHandler) callconv(.c) void = null,

    pub const Error = error{ LibraryNotFound, MissingSymbol };

    /// Opens `libinkview.so` (by its soname, through the loader's search
    /// path, or by `path`) and resolves every function; the optional ones
    /// are null when absent. The library stays open for the process.
    pub fn load(path: [*:0]const u8) Error!Api {
        var lib = std.DynLib.openZ(path) catch |err| {
            log.warn("can't open {s}: {t}", .{ path, err });
            return error.LibraryNotFound;
        };
        var api: Api = undefined;
        var missing = false;
        const info = @typeInfo(Api).@"struct";
        inline for (info.field_names, info.field_types) |name, T| {
            const name_z: [:0]const u8 = name;
            switch (@typeInfo(T)) {
                .optional => |o| {
                    @field(api, name) = lib.lookup(o.child, name_z);
                    if (@field(api, name) == null) log.info("{s} isn't in this libinkview; doing without", .{name});
                },
                else => {
                    if (lib.lookup(T, name_z)) |f| {
                        @field(api, name) = f;
                    } else {
                        log.warn("{s} isn't in this libinkview", .{name});
                        missing = true;
                        @field(api, name) = undefined;
                    }
                },
            }
        }
        if (missing) return error.MissingSymbol;
        return api;
    }
};

test "the optional functions default to null, the required ones have no default" {
    const info = @typeInfo(Api).@"struct";
    inline for (info.field_types, info.field_attrs) |T, attrs| {
        const optional = @typeInfo(T) == .optional;
        if (attrs.default_value_ptr) |ptr| {
            const default: *const T = @ptrCast(@alignCast(ptr));
            try std.testing.expect(optional);
            try std.testing.expectEqual(@as(T, null), default.*);
        } else {
            try std.testing.expect(!optional);
        }
    }
}

test "loading a library that isn't there fails cleanly" {
    try std.testing.expectError(error.LibraryNotFound, Api.load("/nonexistent/libinkview.so"));
}

test "the struct layouts match the C headers" {
    try std.testing.expectEqual(4 * 8 + @sizeOf(usize), @sizeOf(Canvas));
    try std.testing.expectEqual(@as(usize, if (@sizeOf(usize) == 8) 24 else 12), @sizeOf(MenuItem));
    try std.testing.expectEqual(24, @backingInt(Key.prev));
    try std.testing.expectEqual(25, @backingInt(Key.next));
}

test "the flag structs pack as the header's constants" {
    // ICON_QUESTION | DEF_BUTTON2 | DLG_HW_BUTTON
    try std.testing.expectEqual(2 | 0x1000 | 0x10000, @as(u32, @bitCast(DialogIcon{ .kind = .question, .default = .second, .hw_button = true })));
    // KBD_URL | KBD_PASSWORD | KBD_NOSELECT | KBD_NOUPDATE_AFTER_CLOSE
    try std.testing.expectEqual(7 | 0x100 | 0x200 | 0x10000, @as(u32, @bitCast(KeyboardFlags{ .layout = .url, .password = true, .noselect = true, .no_update_after_close = true })));
    try std.testing.expectEqual(0, @as(u32, @bitCast(PanelType.disabled)));
    try std.testing.expectEqual(1 << 1, @as(u32, @bitCast(PanelType{ .enabled = true })));
}
