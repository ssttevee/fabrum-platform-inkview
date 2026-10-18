//! A reader shell: the screen a manga reader would start from, as a stand-in
//! for one built on the Tachiyomi (Suwayomi) protocol. A title bar, a
//! search field that opens the system keyboard, a Menu button for the
//! context menu, a scrolling list of chapters with Pick buttons, which
//! the page keys and a finger pan scroll, a confirm dialog before quitting,
//! and a Settings page the menu toggles.
//!
//! Where the reader would go: the list's items would come from the
//! server's library through a `Poster` from a fetching thread (covers
//! decoded to gray through the same path), and picking one would open the
//! reader page, whose page turns ask for `page` refreshes. Nothing here
//! talks to a network.
//!
//! It knows nothing of InkView: `main.zig` hosts it, and the tests below
//! run it through `app.testing.Harness` with fake services.
const std = @import("std");
const Allocator = std.mem.Allocator;

const fabrum = @import("fabrum");
const app = fabrum.app;
const layout = fabrum.layout;
const widgets = app.widgets;
const Color = fabrum.Color;

const ReaderShell = @This();

pub const chapter_count = 40;

/// Room in the layout for the chapters: more direct children than the
/// default allows.
pub const layout_capacity: layout.Context.Config = .{ .breadth = 64 };

pub const Page = enum { library, settings };

pub const State = struct {
    page: Page = .library,
    /// The search field's text.
    query: std.ArrayList(u8) = .empty,
    /// The chapter picked last.
    picked: ?usize = null,
    picks: usize = 0,
    /// Settings.
    invert_page_keys: bool = false,
    show_numbers: bool = true,
    /// Whether the list has been given focus, so the page keys reach it.
    list_focused: bool = false,
    /// Where the finger was, while panning the list.
    pan_last: f32 = 0,
    /// What the last dialog or menu answered, for the status line.
    status: []const u8 = "Ready",

    pub fn deinit(self: *State, gpa: Allocator) void {
        self.query.deinit(gpa);
    }
};

pub const MenuId = enum(usize) { settings = 1, library, refresh, about, quit };

pub const Msg = union(enum) {
    query: []const u8,
    pick: usize,
    open_menu,
    chose: ?usize,
    ask_quit,
    quit_answered: ?usize,
    key: app.KeyEvent,
    pan: app.Pointer,
    focus_list,
    invert_page_keys: bool,
    show_numbers: bool,
    go: Page,
};

pub const Props = struct {};

pub const ChapterKey = struct { chapter: usize };
pub const PickKey = struct { pick: usize };

/// The list scrolls by this much for a page key.
const page_step = 300;

pub fn update(state: *State, msg: Msg, ctx: *app.Update(ReaderShell)) !void {
    switch (msg) {
        // the field's text is borrowed: copy it
        .query => |text| {
            state.query.clearRetainingCapacity();
            try state.query.appendSlice(ctx.gpa, text);
        },
        .pick => |i| {
            state.picked = i;
            state.picks += 1;
            state.status = "Picked a chapter";
        },
        .open_menu => try ctx.menu(.{ .items = &.{
            .{ .title = "Reader shell", .kind = .header },
            .{ .title = if (state.page == .library) "Settings" else "Library", .id = @backingInt(if (state.page == .library) MenuId.settings else MenuId.library) },
            .{ .title = "Refresh the screen", .id = @backingInt(MenuId.refresh) },
            .{ .kind = .separator },
            .{ .title = "About", .id = @backingInt(MenuId.about) },
            .{ .title = "Quit", .id = @backingInt(MenuId.quit) },
        }, .at = .init(8, 40) }, ctx.handler(.chose)),
        .chose => |id| {
            const choice = std.enums.fromInt(MenuId, id orelse 0) orelse {
                state.status = "Menu dismissed";
                return;
            };
            switch (choice) {
                .settings => state.page = .settings,
                .library => {
                    state.page = .library;
                    // the list is new: give it focus again
                    state.list_focused = false;
                },
                .refresh => ctx.refresh(.page),
                .about => try ctx.message(.{ .title = "About", .text = "A fabrum reader shell on InkView.", .timeout_ms = 3000 }),
                .quit => try ctx.emit(ctx.handler(.ask_quit), {}),
            }
            state.status = "Menu chosen";
        },
        .ask_quit => try ctx.confirm(.{ .title = "Quit", .text = "Quit the reader shell?", .buttons = &.{ "Quit", "Stay" }, .default = 1 }, ctx.handler(.quit_answered)),
        .quit_answered => |button| if (button == 0) try ctx.quit() else {
            state.status = "Stayed";
        },
        .key => |event| if (event.phase == .press) {
            const down = if (state.invert_page_keys) event.key == .page_up else event.key == .page_down;
            const up = if (state.invert_page_keys) event.key == .page_down else event.key == .page_up;
            if (down) ctx.scrollTo("chapters", .{ .by = .init(0, page_step) });
            if (up) ctx.scrollTo("chapters", .{ .by = .init(0, -page_step) });
        },
        // a finger pan scrolls the list by how far it moved
        .pan => |p| switch (p.phase) {
            .press => state.pan_last = p.local.y,
            .drag => {
                ctx.scrollTo("chapters", .{ .by = .init(0, state.pan_last - p.local.y) });
                state.pan_last = p.local.y;
            },
            else => {},
        },
        .focus_list => {
            state.list_focused = true;
            ctx.focus("chapters");
        },
        .invert_page_keys => |on| state.invert_page_keys = on,
        .show_numbers => |on| state.show_numbers = on,
        .go => |page| {
            state.page = page;
            if (page == .library) state.list_focused = false;
        },
    }
}

pub fn view(ui: *app.Ui, state: *const State, _: Props) !void {
    const theme = ui.use(app.native.Theme);

    try ui.open(null, .{ .layout = .{ .sizing = .grow(.{}), .axis = .y }, .background_color = theme.window_background });
    defer ui.close();

    try titleBar(ui, state, theme);
    switch (state.page) {
        .library => try library(ui, state, theme),
        .settings => try settings(ui, state, theme),
    }
    try statusLine(ui, state, theme);
}

fn titleBar(ui: *app.Ui, state: *const State, theme: *const app.native.Theme) !void {
    const on = ui.messages(ReaderShell);
    try ui.open(null, .{
        .layout = .{ .sizing = .{ .width = .grow(.{}) }, .padding = .init(12, 12, 8, 8), .child_gap = 8, .child_alignment = .center_left },
        .background_color = theme.control_background,
        .border = .{ .color = theme.separator, .widths = .{ .bottom = 1 } },
    });
    defer ui.close();
    try ui.text(if (state.page == .library) "Library" else "Settings", font(20, theme.text));
    ui.spacer();
    try widgets.button(ui, "menu", .{ .label = "Menu", .on_click = on.bind(.open_menu) });
}

fn library(ui: *app.Ui, state: *const State, theme: *const app.native.Theme) !void {
    const on = ui.messages(ReaderShell);
    // the list takes the page keys once it has focus; give it focus with
    // the first frame
    if (!state.list_focused) try ui.after("focus", .fromMilliseconds(0), on.bind(.focus_list));

    {
        try ui.open(null, .{ .layout = .{ .sizing = .{ .width = .grow(.{}) }, .padding = .init(12, 12, 8, 4), .child_gap = 8, .child_alignment = .center_left } });
        defer ui.close();
        try ui.text("Search", font(theme.font_size, theme.secondary_text));
        // on the reader the field asks for the system keyboard when tapped
        try widgets.textField(ui, "query", .{ .text = state.query.items, .placeholder = "Title or author", .on_change = on.handler(.query) });
    }

    try ui.open("chapters", .{
        .layout = .{ .sizing = .grow(.{}), .axis = .y, .padding = .init(12, 12, 4, 4), .child_gap = 6 },
        .scroll = .{ .y = true },
        .focus = .{ .on_key = on.handler(.key), .keys = .navigation_only },
        .on_pointer = on.handler(.pan),
    });
    defer ui.close();
    for (0..chapter_count) |i| {
        if (!matches(state.query.items, i)) continue;
        const key: ChapterKey = .{ .chapter = i };
        try ui.open(key, .{
            .layout = .{ .sizing = .{ .width = .grow(.{}) }, .padding = .init(10, 10, 6, 6), .child_gap = 8, .child_alignment = .center_left },
            .background_color = theme.control_background,
            .corner_radius = .uniform(4),
            .border = .{ .color = if (state.picked == i) theme.text else theme.separator, .widths = .outside(1) },
        });
        defer ui.close();
        if (state.show_numbers) {
            try ui.print(font(theme.font_size, theme.text), "Chapter {d}", .{i + 1});
        } else {
            try ui.text("Chapter", font(theme.font_size, theme.text));
        }
        ui.spacer();
        try widgets.button(ui, PickKey{ .pick = i }, .{ .label = if (state.picked == i) "Picked" else "Pick", .on_click = on.bind(.{ .pick = i }) });
    }
}

/// Whether chapter `i` matches the search: its number contains the
/// query's digits, or the query is empty.
fn matches(query: []const u8, i: usize) bool {
    if (query.len == 0) return true;
    var buffer: [16]u8 = undefined;
    const number = std.fmt.bufPrint(&buffer, "{d}", .{i + 1}) catch return true;
    return std.mem.indexOf(u8, number, query) != null;
}

fn settings(ui: *app.Ui, state: *const State, theme: *const app.native.Theme) !void {
    const on = ui.messages(ReaderShell);
    try ui.open(null, .{ .layout = .{ .sizing = .grow(.{}), .axis = .y, .padding = .all(12), .child_gap = 12 } });
    defer ui.close();
    try widgets.checkbox(ui, "invert", .{ .label = "Invert the page keys", .checked = state.invert_page_keys, .on_change = on.handler(.invert_page_keys) });
    {
        try ui.open(null, .{ .layout = .{ .child_gap = 8, .child_alignment = .center_left } });
        defer ui.close();
        try widgets.toggle(ui, "numbers", .{ .on = state.show_numbers, .on_change = on.handler(.show_numbers) });
        try ui.text("Show chapter numbers", font(theme.font_size, theme.text));
    }
    try widgets.button(ui, "quit", .{ .label = "Quit…", .on_click = on.bind(.ask_quit) });
    ui.spacer();
    try widgets.button(ui, "back", .{ .label = "Back to the library", .on_click = on.bind(.{ .go = .library }) });
}

fn statusLine(ui: *app.Ui, state: *const State, theme: *const app.native.Theme) !void {
    try ui.open(null, .{
        .layout = .{ .sizing = .{ .width = .grow(.{}) }, .padding = .init(12, 12, 4, 4), .child_gap = 8 },
        .border = .{ .color = theme.separator, .widths = .{ .top = 1 } },
    });
    defer ui.close();
    try ui.text(state.status, font(theme.font_size, theme.secondary_text));
    ui.spacer();
    if (state.picked) |i| try ui.print(font(theme.font_size, theme.secondary_text), "Chapter {d}", .{i + 1});
}

fn font(size: f32, color: Color) layout.text.Style {
    return .{ .font_size = size, .color = color, .wrap_mode = .none };
}

// Tests, through fabrum's harness, with its fake services

const testing = std.testing;
const eink: app.Capabilities = .{ .pointer = .touch, .hover = false, .animation = .none, .color = .gray16, .keyboard = .on_screen };
const Harness = app.testing.Harness(.{}, ReaderShell);

fn harness() !Harness {
    return .init(.{}, .{ .viewport = .init(343, 463), .capabilities = eink, .widgets = .drawn, .context = layout_capacity });
}

test "the library lists chapters with Pick buttons, and picking one marks it" {
    var h = try harness();
    defer h.deinit();
    try h.frame();
    try h.expectText("Library");
    try h.expectText("Chapter 1");
    try h.clickElement(h.root().element(PickKey{ .pick = 0 }));
    try testing.expectEqual(@as(?usize, 0), h.state().picked);
    try h.expectText("Picked");
    try h.expectText("Picked a chapter");
}

test "tapping the search field asks for the system keyboard, and its text filters the list" {
    var h = try harness();
    defer h.deinit();
    try h.frame();
    try h.clickElement(h.root().child(app.drawn.TextBox, "query").element("field"));
    try h.enterText("3");
    try testing.expectEqualStrings("3", h.state().query.items);
    try h.expectText("Chapter 3");
    try h.expectText("Chapter 13");
    try h.expectNoText("Chapter 1");
}

test "the menu toggles the settings page, and Quit asks first" {
    var h = try harness();
    defer h.deinit();
    try h.frame();
    try h.click("Menu");
    try h.chooseMenuItem(@backingInt(MenuId.settings));
    try testing.expectEqual(Page.settings, h.state().page);
    try h.expectText("Invert the page keys");
    try h.click("Menu");
    try h.chooseMenuItem(@backingInt(MenuId.library));
    try testing.expectEqual(Page.library, h.state().page);
    try h.click("Menu");
    try h.chooseMenuItem(null);
    try h.expectText("Menu dismissed");

    try h.click("Menu");
    try h.chooseMenuItem(@backingInt(MenuId.quit));
    try h.answerDialog(1);
    try h.expectText("Stayed");
    try h.click("Menu");
    try h.chooseMenuItem(@backingInt(MenuId.quit));
    try h.answerDialog(0);
    try testing.expect(h.tree.quits > 0);
}

test "the page keys scroll the list, inverted by the setting" {
    var h = try harness();
    defer h.deinit();
    try h.frame();
    try h.advance(.fromMilliseconds(1));
    try h.frame();
    const list = h.root().element("chapters");
    try testing.expect(h.state().list_focused);
    try h.press(.page_down, .{});
    try testing.expectEqual(page_step, h.scrollInfo(list).?.offset.y);
    try h.press(.page_up, .{});
    try testing.expectEqual(0, h.scrollInfo(list).?.offset.y);

    try h.click("Menu");
    try h.chooseMenuItem(@backingInt(MenuId.settings));
    try h.click("Invert the page keys");
    try h.click("Back to the library");
    try h.advance(.fromMilliseconds(1));
    try h.frame();
    try h.press(.page_up, .{});
    try testing.expectEqual(page_step, h.scrollInfo(list).?.offset.y);
}

test "a pan over the chapters scrolls them" {
    var h = try harness();
    defer h.deinit();
    try h.frame();
    const list = h.root().element("chapters");
    const box = h.findElement(list).?.bbox;
    const x = box.x + box.w / 2;
    try h.drag(.init(x, box.y + box.h - 20), .init(x, box.y + 20), 5);
    try testing.expectApproxEqAbs(box.h - 40, h.scrollInfo(list).?.offset.y, 1);
}
