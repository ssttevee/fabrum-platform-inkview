//! The InkView functions this package calls, typed, and how they are
//! reached: resolved at run time from `libinkview.so` with `std.DynLib`
//! (`Api.load`), so nothing of the SDK is linked and a function a firmware
//! lacks is a null in `Api`, not a loader error at start-up.
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

/// `imenu`: one entry of a popup menu; an array ends with `type == 0`.
pub const MenuItem = extern struct {
    type: c_short,
    index: c_short,
    text: ?[*:0]u8,
    submenu: ?[*]MenuItem,

    pub const end: MenuItem = .{ .type = 0, .index = 0, .text = null, .submenu = null };
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
};

/// The `icon` argument of `Message` and `Dialog3`.
pub const icon = struct {
    pub const information: c_int = 1;
    pub const question: c_int = 2;
    pub const warning: c_int = 3;
    pub const @"error": c_int = 4;
    /// The button highlighted first: `def_button[n]` for button n.
    pub const def_button = [_]c_int{ 0, 0x1000, 0x2000 };
    /// Don't restore the screen under the dialog when it closes.
    pub const no_dismiss: c_int = 0x8000;
    /// Let the page keys press the first and last buttons on touch devices.
    pub const hw_button: c_int = 0x10000;
};

/// `ITEM_*`: menu item types.
pub const item = struct {
    pub const header: c_short = 1;
    pub const active: c_short = 2;
    pub const inactive: c_short = 3;
    pub const submenu: c_short = 5;
    pub const separator: c_short = 6;
    pub const bullet: c_short = 7;
};

/// `KBD_*`: `OpenKeyboard` flags: one layout in the low nibble, options
/// above.
pub const kbd = struct {
    pub const normal: c_int = 0;
    pub const entext: c_int = 1;
    pub const numeric: c_int = 4;
    pub const url: c_int = 7;
    pub const password: c_int = 0x100;
    /// Typing appends to the initial text instead of replacing it.
    pub const noselect: c_int = 0x200;
    /// No `EVT_SHOW` to the restored handler when the keyboard closes.
    pub const no_evt_show: c_int = 0x1000;
    /// No screen refresh when the keyboard closes.
    pub const no_update_after_close: c_int = 0x10000;
};

/// `PANEL_*`: `SetPanelType` values.
pub const panel = struct {
    pub const disabled: c_int = 0;
    pub const enabled: c_int = 1 << 1;
    pub const event_no_handling: c_int = 1 << 2;
    pub const no_fb_offset: c_int = 1 << 3;
    pub const no_self_update: c_int = 1 << 4;
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
    GetOrientation: *const fn () callconv(.c) c_int,
    SetOrientation: *const fn (c_int) callconv(.c) void,
    SetPanelType: *const fn (c_int) callconv(.c) void,
    PanelHeight: *const fn () callconv(.c) c_int,
    Stretch: *const fn ([*]const u8, c_int, c_int, c_int, c_int, c_int, c_int, c_int, c_int, c_int) callconv(.c) void,

    // updates
    FullUpdate: *const fn () callconv(.c) void,
    PartialUpdate: *const fn (c_int, c_int, c_int, c_int) callconv(.c) void,

    // services
    Message: *const fn (c_int, [*:0]const u8, [*:0]const u8, c_int) callconv(.c) void,
    Dialog3: *const fn (c_int, [*:0]const u8, [*:0]const u8, ?[*:0]const u8, ?[*:0]const u8, ?[*:0]const u8, DialogHandler) callconv(.c) void,
    OpenMenu: *const fn ([*]MenuItem, c_int, c_int, c_int, MenuHandler) callconv(.c) void,
    OpenKeyboard: *const fn ([*:0]const u8, [*:0]u8, c_int, c_int, KeyboardHandler) callconv(.c) void,

    // optional
    /// Without it, `interactive` refreshes use `DynamicUpdate` or
    /// `PartialUpdate`.
    DynamicUpdateA2: ?*const fn (c_int, c_int, c_int, c_int) callconv(.c) void = null,
    DynamicUpdate: ?*const fn (c_int, c_int, c_int, c_int) callconv(.c) void = null,
    /// 5.19+. Without it the host never skips a frame for a busy panel.
    IsUpdateInProcess: ?*const fn () callconv(.c) c_int = null,
    /// 5.14+. Without it the scale comes from `Options.dpi`.
    get_screen_dpi: ?*const fn () callconv(.c) c_int = null,
    /// 6.5+: the panel's framebuffer shift when it is at the top.
    PanelHeightFBOffset: ?*const fn () callconv(.c) c_int = null,
    /// Removed in 6.8: without it `openDirectory` is unsupported.
    OpenDirectorySelector: ?*const fn ([*:0]const u8, [*:0]u8, c_int, DirHandler) callconv(.c) void = null,
    GetSoftwareVersion: ?*const fn () callconv(.c) ?[*:0]u8 = null,
    GetDeviceModel: ?*const fn () callconv(.c) ?[*:0]u8 = null,
    FlushEvents: ?*const fn () callconv(.c) void = null,

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

test "the optional functions have defaults, the required ones don't" {
    const info = @typeInfo(Api).@"struct";
    var optional: usize = 0;
    inline for (info.field_types) |T| {
        if (@typeInfo(T) == .optional) optional += 1;
    }
    try std.testing.expectEqual(9, optional);
    try std.testing.expectEqual(@as(?*const fn () callconv(.c) c_int, null), (Api{
        .InkViewMain = undefined,
        .CloseApp = undefined,
        .SendEvent = undefined,
        .SetHardTimer = undefined,
        .SetWeakTimer = undefined,
        .ClearTimer = undefined,
        .ScreenWidth = undefined,
        .ScreenHeight = undefined,
        .GetCanvas = undefined,
        .GetOrientation = undefined,
        .SetOrientation = undefined,
        .SetPanelType = undefined,
        .PanelHeight = undefined,
        .Stretch = undefined,
        .FullUpdate = undefined,
        .PartialUpdate = undefined,
        .Message = undefined,
        .Dialog3 = undefined,
        .OpenMenu = undefined,
        .OpenKeyboard = undefined,
    }).IsUpdateInProcess);
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
