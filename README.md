# fabrum-platform-inkview

fabrum on PocketBook e-readers, through libinkview. It is an external
platform package on fabrum's `none` platform: the app's own code hosts the
runtime, and this package is that code for InkView. InkView's event loop
drives the frames, the z2d renderer draws only what changed into the panel's
gray framebuffer, fabrum's refresh hints choose the e-ink update, and
InkView's own dialogs, menus and keyboard are the services.

Written for the PocketBook Verse (model 629, Allwinner B288), with one
`.app` targeting firmware 6.8, 6.9 and 6.10–6.11, against the 6.10 SDK
headers and [libinkview](https://github.com/ssttevee/libinkview)'s
[documentation](https://github.com/ssttevee/libinkview/blob/trunk/docs/README.md).
**It has passed the first-run checks on a Verse with firmware 6.8**: see
"What needs the device".

## What it is

```zig
const std = @import("std");
const inkview = @import("fabrum-platform-inkview");
const Reader = @import("Reader.zig"); // a fabrum.app component

pub fn main(init: std.process.Init) !void {
    try inkview.run(Reader, init.gpa, init.io, .{}, .{
        .fonts = &.{.{ .name = "Go", .data = @embedFile("fonts/Go-Regular.ttf") }},
        .close_key = .back,
    });
}
```

`run` loads `libinkview.so`, builds the runtime with the e-reader's
capabilities (touch, no hover, no animation, 16 grays, an on-screen
keyboard; the theme turns high-contrast) and the services below, and hands
InkView the handler. It never returns on the device: InkView ends the
process when the app closes.

| Piece | File | What it does |
|---|---|---|
| Bindings | `src/inkview.zig` | The 23 functions the host calls, typed; `Api.load` resolves them from `libinkview.so` with `std.DynLib` at start-up. Nothing of the SDK is linked. Required functions exist in every version since 5.2; optional ones (`DynamicUpdateA2`, `DynamicUpdate`, `get_screen_dpi`, `OpenDirectorySelector`) are null when a firmware lacks them and the host does without. Adding a function is one field: the loader is generated from them. |
| Host | `src/host.zig` | `App(Root)`: the handler, frames, the framebuffer, timers, the wake path for posts from other threads, the services. |
| Refresh policy | `src/refresh.zig` | Hints to updates, with A2 hysteresis and a periodic cleaning refresh; a value with no InkView in it. |
| Keys | `src/keys.zig` | `KeyMap`: which fabrum key each hardware key means. |
| Fake | `src/fake.zig` | A fake InkView for tests: framebuffer, timers, modal UIs, the clock. |
| Example | `src/example/` | `ReaderShell`, the first screen of a reading app (a chapter list, search, a menu, dialogs and a settings page), and its `main.zig`. |

## Adding it to an app

```sh
zig fetch --save git+https://github.com/ssttevee/fabrum#trunk
zig fetch --save git+https://github.com/ssttevee/fabrum-platform-inkview#trunk
```

**fabrum is the app's.** This package does not fetch fabrum for apps: in the
app's `build.zig`, give this module (and the
[z2d renderer](https://github.com/ssttevee/fabrum-renderer-z2d) inside it,
which is this package's own dependency) the `fabrum` the app uses, built
with `.platform = .none`, through `addFabrum`. Otherwise the program would
hold two fabrum modules, the app's and the platform's, and fail to build.

```zig
const fabrum_mod = b.dependency("fabrum", .{ .target = target, .optimize = optimize, .platform = .none }).module("fabrum");
const inkview = b.dependency("fabrum_platform_inkview", .{ .target = target, .optimize = optimize });
const platform = inkview.module("fabrum-platform-inkview");
@import("fabrum_platform_inkview").addFabrum(platform, fabrum_mod);
exe.root_module.addImport("fabrum", fabrum_mod);
exe.root_module.addImport("fabrum-platform-inkview", platform);
exe.root_module.link_libc = true; // dlopen
```

## Building for the Verse

Zig 0.17.0. The dependencies, [fabrum](https://github.com/ssttevee/fabrum)
(`trunk`) and
[fabrum-renderer-z2d](https://github.com/ssttevee/fabrum-renderer-z2d), are
fetched from GitHub by `zig build`; fabrum lazily, since only this package's
own tests and example need it (apps bring their own, above).

```sh
zig build            # zig-out/pocketbook/ReaderShell.app and ReaderShell-log.app
zig build app        # the device build step explicitly
zig build test       # the fake-InkView host tests and the example's Harness tests
zig build emulator   # zig-out/emulator/ReaderShell, x86_64 Linux (see below)
```

The device build is `arm-linux-gnueabi` with glibc 2.23 (dynamic),
`cortex_a7`, ReleaseSmall by default, whatever `-Dtarget` or `-Dcpu` says.
`-Ddevice-optimize=small|safe|fast|debug` chooses its optimization; `safe`
keeps safety checks and symbols for device crash traces. `-Doptimize`
controls the host tests, the public module and the emulator instead. What
comes out (checked with `file` and `llvm-readelf`): a 32-bit ARM EABI5 executable,
soft-float (`e_flags 0x5000200`, no `Tag_ABI_VFP_args`), interpreter
`/lib/ld-linux.so.3`, no linked InkView symbol in it. The size depends on
optimization and the app. The highest glibc symbol version it needs is `GLIBC_2.17` (the clock functions), within
6.8's glibc 2.23. There is no 6.9 SDK, but the official Verse 6.9.862
firmware's root filesystem also has glibc 2.23.

`NEEDED` is `libc.so.6`, `ld-linux.so.3`, `libpthread.so.0` and `libdl.so.2`.
The last two supply std's threaded Io functions and `dlopen`/`dlsym` on
glibc 2.23; their required versions are all `GLIBC_2.4`. No `librt` is
needed: the clock functions are in libc at `GLIBC_2.17`. On glibc 2.39
(6.10), libc supplies the old pthread and dl symbols; the compatibility
libraries retain their version nodes. The versioned imports in the checked
build were checked against the 6.8 and 6.10 B288 sysroots and the official Verse
[U629.6.9.862](https://download.pocketbook-int.com/fw/Liangyan/629/user/20250814/sw_20250814_U629_6.9.862_user.zip)
and [U629.6.10.1461 firmware images](https://download.pocketbook-int.com/fw/Liangyan/629/user/20250826/sw_20250826_U629_6.10.1461_accessibility_eink_user.zip).
The 6.10 image's root filesystem contains `/lib/libpthread.so.0` and
`/lib/libdl.so.2`, byte-identical to the 6.10 B288 SDK copies. The libinkview
docs' statement that 6.10 "dropped" them describes libinkview's `NEEDED`
list, not their removal from the filesystem. Other firmware images have not been checked.

ReaderShell, this host, fabrum and z2d request no entropy. Hash maps use
fixed seeds; `std.process.Init` constructs `std.Io.Threaded` without
seeding its random generator. Its Io vtable still brings the entropy
implementation into the binary. With Zig 0.17, libc linked and the glibc
pin below 2.25, that implementation selects `/dev/urandom`, not the
`getrandom` syscall. The device build checks this choice at compile time;
its ELF has no `getrandom`, `getentropy` or `arc4random` import or ARM
`getrandom` syscall. No std override or fabrum change is needed.

This does not make future uses of `io.randomSecure` work on kernel 3.10:
std's `/dev/urandom` path first validates the file with `statx`, which that
kernel also lacks, and returns `error.EntropyUnavailable` if it fails.
`io.random` then uses std's weaker PID/time/address seed. Apps needing
secure randomness need a separate `/dev/urandom` implementation that does
without `statx`.

The same goes for files: `std.Io.Threaded` asks for a file's size and
metadata with the `statx` syscall (Linux 4.11) whatever the kernel, so
`File.length`, `File.stat`, `Dir.statFile` and what calls them fail on the
B288's 3.10 kernel. Opening, reading and writing files don't use it. The
example reads no files (its font is embedded); an app that needs sizes or
metadata needs an `std.Io` whose stat functions use `fstat`/`fstatat`, which
glibc 2.23 has.

## Deploying

Use the same `ReaderShell.app` on B288 firmware 6.8, 6.9 and 6.10+.
Start with the log launcher on each firmware line: the library checks
above cover one 6.9 image and one 6.10 image; no hardware run yet.
A missing `libpthread.so.0` or `libdl.so.2` stops the loader before the app
starts; keep that error in the log. The RK3566 6.11 SDK is hard-float and
is a different target.

1. Connect the reader by USB and choose *PC link*.
2. Copy `zig-out/pocketbook/ReaderShell.app` into `applications/` on the
   reader. For the first runs also copy `ReaderShell-log.app`, a shell
   script that runs the binary with its output appended to
   `applications/ReaderShell.log` and sets
   `GLIBC_TUNABLES=glibc.rtld.execstack=2` (6.11.1480 refuses to `dlopen`
   a library with an executable stack without it; harmless elsewhere).
3. On macOS run `dot_clean /Volumes/<reader>/applications` so that no
   `._ReaderShell.app` shows up as an app. Eject.
4. Start *ReaderShell* (or *ReaderShell-log*) from the Applications list.
   Menu → Quit closes it, as does Back on readers that have the key (the
   Verse has only Home, the two page keys and Power). Home leaves it
   running in the background: start it again to return to it, and quit
   it before copying a new build over it.

Apps run as user `reader` with the current directory `/`; this package
uses no relative paths.

## Refresh policy

fabrum says how each frame's damage should be shown (`Runtime.refresh`:
`content`, `interactive`, `page`); `refresh.Policy` turns that into an
InkView update, with the state it needs:

| Hint | Update | Notes |
|---|---|---|
| `page` (the app asked, `ctx.refresh(.page)`) | `FullUpdate()` | GC16 with a clearing flash; resets the counters. |
| `content` (anything else) | `PartialUpdate(rect)` per damage region | GC16, no flash. |
| `interactive` (a drag, a scroll) | `DynamicUpdate(rect)` for the first `a2_enter_after` frames (2), then `DynamicUpdateA2(rect)` | A short gesture never pays A2's entry and exit. |
| A2 ends | `FullUpdate()` `a2_exit_delay` (700 ms) after the last interactive frame | What `ExitUpdateA2` does; a hard InkView timer. Content frames meanwhile are gray `DynamicUpdate`s and push the exit out. The framebuffer always holds full grays (nothing is dithered in place), so the full refresh restores them. |
| Every `full_every` (12) partial or gray dynamic updates | `FullUpdate()` | Clears the ghosting partial updates leave, as readers do every few pages. |
| `EVT_SHOW`, `EVT_REPAINT`, `EVT_FOREGROUND` | everything redrawn, `FullUpdate()` (or a whole-screen `PartialUpdate` with `show_refresh = .partial`) | The library restored the screen under us. |
| `EVT_ORIENTATION` | everything redrawn, `FullUpdate()` | Rotation always requests a page refresh. |

The policy is configured through `Options.refresh`; A2 frames do not
advance the periodic cleaning counter. Without `DynamicUpdateA2` in the
library gestures stay gray. Gray updates fall back to `PartialUpdate`
when `DynamicUpdate` is missing.

**Framebuffer.** The task framebuffer from `GetCanvas()` (gray8 on the
B288: one byte per pixel, rows `scanline` apart) is the surface z2d draws
into, in place, as KOReader does; only the damage is redrawn. If a
firmware's framebuffer isn't 8-bit, a private gray8 buffer is drawn and
blitted whole with `Stretch`. Damage rectangles are in points; they are
scaled to pixels and rounded out before the update call (InkView aligns
them to 4 pixels itself).

**Scale.** `Options.scale`, or the panel's dpi (`get_screen_dpi`, else
`Options.dpi` = 212) over `points_per_inch` (96): 2.2 pixels per point on
the Verse, so the theme's 13-point font is 29 pixels, about what the
earlier Clay-based reader drew at 24–32 px, and a 758×1024 panel is a
343×464-point viewport. Pointer coordinates are divided by the same scale.

**Orientation and panel.** `Options.orientation` (portrait by default) is
set at `EVT_INIT`; `EVT_ORIENTATION` (only delivered on 6.x with
`SUPPORT_EVT_ORIENTATION`, which `Options.follow_gsensor` sets) calls
`SetOrientation`, re-reads `ScreenWidth/Height` and the canvas, and
redraws. The status panel is hidden (`SetPanelType(PANEL_DISABLED)`) unless
`Options.panel = .shown`, when the viewport leaves `PanelHeight()` out.

**Before and after.** The earlier Clay-based reader redrew and
`FullUpdate`d the whole screen on every repaint (a flash per tap). Here a
tap on a button is a partial update of the button's rectangle, a pan is
A2, and the flashes are the app's page turns and the periodic clean.

## Events and keys

| InkView | fabrum |
|---|---|
| `EVT_INIT` | panel, orientation, scale and geometry set up |
| `EVT_SHOW`, `EVT_REPAINT`, `EVT_FOREGROUND` | a full redraw and refresh |
| `EVT_BACKGROUND` | the press under way is cancelled; updates stop until the foreground |
| `EVT_POINTERDOWN`, `MOVE`, `DRAG`, `UP` | `Runtime.mouse` with the primary button |
| `EVT_POINTERLONG` | `Runtime.mouse` with `long_press` (the element's `Pointer.long_press`) |
| `EVT_POINTERCANCEL` | `Runtime.cancelPointer` |
| `EVT_KEYPRESS`, `KEYREPEAT`, `KEYRELEASE` | `Runtime.key` through `Options.keys` |
| `EVT_PREVPAGE`, `EVT_NEXTPAGE` | Page Up and Page Down |
| `EVT_EXIT` | nothing: the library is already exiting, and can't be refused |
| `EVT_CUSTOM + 1` | a wake from `Poster.post` on another thread |

The handler returns 1 when the app took the event, so InkView's defaults
(the panel, the power key) apply to the rest.

Keys by default (`KeyMap`): both pairs of page keys are Page Up and Page
Down (on the Verse the page keys arrive as `IV_KEY_PREV` 0x18 and
`IV_KEY_NEXT` 0x19, which the earlier reader saw as 24 and 25); the
arrows are themselves; OK is Enter; Back is Escape (fabrum clears drawn
focus with it) unless it is `Options.close_key`, which asks
`Runtime.shouldClose` and then `CloseApp`; Menu is F10; Home and Power are
left to the library. fabrum takes keys only while a drawn element has
focus: the example gives its list focus on its first frame, so the page
keys scroll it.

Timers: `Runtime.nextFrame` arms one InkView timer (`SetHardTimer`, or
`SetWeakTimer` with `Options.frame_timer = .weak`), re-armed after every
frame, since the library's timers are one-shot and keyed by their
function. The A2 exit is a second one.

Threads: everything runs on InkView's loop thread. A `Poster.post` from
another thread calls `SendEvent`, which libinkview documents as the way
for worker threads to reach the handler; its queue is a ring of 128, so
wakes are coalesced (at most one in flight). Nothing else in InkView is
called off the loop thread.

## Services

| fabrum | InkView | Notes |
|---|---|---|
| `message` | `Message(icon, title, text, timeout)` | Blocks until the box goes. Timers keep running inside it; a frame they ask for waits until the call is over. The title isn't drawn on 6.8+. |
| `confirm` | `Dialog3(icon \| DEF_BUTTONn \| DLG_HW_BUTTON, …)` | Buttons answered 1–3 become indices 0–2, -1 (Back) becomes null. One at a time. |
| `menu` | `OpenMenu(imenu[], 0, x, y, …)` | `ITEM_HEADER`, `ITEM_SEPARATOR`, `ITEM_INACTIVE`, `ITEM_SUBMENU` from the items; `imenu.index` is a position in the tree (a `short`), mapped back to `MenuItem.id`. The strings live until the callback. |
| `editText` | `OpenKeyboard(title, buffer, maxlen, flags, …)` | `KBD_URL` (url, email), `KBD_NUMERIC`, `KBD_PASSWORD`; `KBD_NOSELECT` so typing appends; `KBD_NOUPDATE_AFTER_CLOSE`. The text (or null for cancel) goes through the `Reply`. Drawn text fields ask for it when tapped, since the keyboard is `on_screen`. `multiline` is ignored. The buffer uses `max_len`, or `Options.text_max_len` (1024) when zero, enlarged to hold the initial text. |
| `openDirectory` | `OpenDirectorySelector` | Only on firmware up to 6.5; `error.Unsupported` where the symbol is gone. Starts at `Options.directory` (`/mnt/ext1`). Modal until the callback: a path confirms, null cancels. A new request answers any stale pending request with null before replacing it. |
| `openFile` | none | `error.Unsupported`: InkView has no file chooser. A drawn list on `iv_opendir` is future work. |
| clipboard | none | fabrum's clipboard private to the program. |
| `quit`, `close` | `CloseApp()` | One window: closing is quitting. |

**Modal UI and repaints.** A dialog, menu or keyboard replaces the handler
until the user answers, and then restores the pixels it saved under
itself (dialogs also refresh). While one is up, frames are held (timers
still fire, posts still queue); if any was held, everything is redrawn
when it closes and refreshed without a flash, so what a timer or a post
changed under the dialog isn't lost to the restore. The keyboard also
sends `EVT_SHOW` on closing, which redraws and refreshes the whole screen;
`KBD_NOUPDATE_AFTER_CLOSE` makes that the only refresh.

## Tests

`zig build test` runs without a device:

- `refresh.zig`: hint sequences to updates: content/page, the A2
  hysteresis and exit, content during A2, missing functions, the periodic
  full.
- `keys.zig`, `inkview.zig`: the key map, the loader failing cleanly, the
  struct layouts, the flag structs packing as the header's constants,
  the optional functions defaulting to null.
- `host.zig`: the keyboard flags for a request.
- `host_test.zig`, the host driven by the fake InkView with a small
  reader component: init and show (panel, orientation, one full update);
  a tap's partial update covering the button; a pan's gray, A2 and
  cleaning sequence with the exit timer; libraries without A2 or dynamic
  updates; the periodic full and the app's `page`; the keyboard round
  trip into the field and the `EVT_SHOW` after it; `Dialog3`'s answers,
  the quit, a dialog refused while one is up; frames held under a dialog
  and the redraw after; the `imenu` tree with ids past `short`; a
  blocking `Message` with timers inside; InkView frame timers, hard and
  weak; page keys and `EVT_NEXTPAGE`; the close key; rotation; background
  and foreground; a post from another thread coalesced into one wake;
  `openDirectory` with and without the symbol; a 24-bit framebuffer; the
  panel's height; the scale from dpi and explicit.
  After every step that draws, the fake's framebuffer (rows padded past
  the width) is compared with a full redraw.
- `ReaderShell.zig`, through `app.testing.Harness` with fabrum's fake
  services: the list and Pick, the search field's keyboard and filter,
  the menu and the settings page, Quit's dialog, the page keys (inverted
  by the setting), and a pan.

## The emulator

`zig build emulator` builds the example for x86_64 Linux. The SDK's
emulator is only a `libinkview.so` (`sdk/6.10/B288/emulator-x86_64/` in
libinkview) that draws into a GTK 2 window and needs Debian 12's libraries
(ICU 72, jsoncpp), so it runs in a container, not on macOS: put the
library on `LD_LIBRARY_PATH` or in `INKVIEW_LIBRARY`, run from a directory
with the SDK's `system/` tree (fonts, config), per libinkview's
[building.md](https://github.com/ssttevee/libinkview/blob/trunk/docs/building.md)
§6.5. Not tried.

## What needs the device

All eight passed on a Verse with firmware U629.6.8.4081, step 7 after two
fixes: a frame no longer draws over the dialog its update opened, and
events `Message` delivers to the handler while its box is up wait for the
frame under way. Other firmware hasn't been tried. The first run, with
`ReaderShell-log.app`:

1. The app starts and the library loads: the log's first line after
   `starting` should be `screen 758x1024 px, scale 2.21, viewport 343x464
   pt, drawing into the task framebuffer`. `can't open libinkview.so`
   means the loader didn't find it (try a full path in `INKVIEW_LIBRARY`:
   it is under `/ebrmain/lib` on most firmware); `X isn't in this
   libinkview` names a missing required symbol.
2. The first screen appears with one flash, text at a sane size, nothing
   under the status bar (hidden).
3. A tap on Pick marks the row without a flash (a small partial update);
   if the whole screen flashes, InkView's pending `needupdate` turned it
   into a full one, which is normal once.
4. A pan on the list scrolls it: the first two frames gray, then black
   and white (A2), then one flash 0.7 s after lifting the finger that
   brings the grays back. If A2 leaves the list unreadable (grays
   thresholded), set `.refresh = .{ .interactive = .dynamic }`.
5. The page keys scroll the list; Back, where there is one, closes the app.
6. A tap on the search field opens the system keyboard; OK puts the text
   in the field after one flash; Cancel changes nothing. If the keyboard
   area stays on the panel, `KBD_NOUPDATE_AFTER_CLOSE` plus our `EVT_SHOW`
   full refresh didn't cover it: drop the flag.
7. Menu opens InkView's menu at the top left; Settings shows the page;
   About shows a message box for 3 s; Quit asks and quits.
8. Leave the app for the home screen and come back: the screen is redrawn.

Risks:

- **ABI and versions.** Built against the 6.10 headers' constants and
  struct layouts (`icanvas`, `imenu`, `irect` unchanged since 5.2). Needs
  glibc 2.23 and its `libpthread`/`libdl` (see "Building for the Verse").
  The `dlopen` of a library with an executable stack needs the tunable on
  6.11.1480.
- **A2 ghosting and legibility.** A2 thresholds grays; the full refresh on
  exit cleans up, but a page of gray text under a pan may be unreadable
  for the gesture. The policy can turn A2 off.
- **Keyboard repaint.** Whether the library restores the pixels under the
  keyboard with `KBD_NOUPDATE_AFTER_CLOSE` set wasn't verified; the host
  redraws everything on the `EVT_SHOW` that follows either way.
- **Entropy and `statx`.** Below glibc 2.25 std reads `/dev/urandom`, and
  nothing in this package asks for randomness; std's stat functions use
  `statx`, which the 3.10 kernel lacks (see "Building for the Verse").
- **zg on 32-bit.** fabrum's word segmentation uses its own rules on
  32-bit targets (zg's tables don't build there); graphemes are zg's.
- **`Message` blocks** inside `update`; a 30-second message freezes the
  app for 30 seconds. It can also trigger fabrum's default 16 ms view/update
  watchdog diagnostic (`Runtime.Options.watchdog_ms`); `Options` does not
  expose an override.
- **Task shutdown.** The host does not call `runtime.cancelTasks()` on
  exit. `InkViewMain` ends with `_exit`, so task cancellation and deferred
  cleanup are not guaranteed to run. Apps using `ctx.run`, `ctx.runKey` or
  `ui.task` must finish any required saves or other cleanup before asking
  InkView to close; they cannot rely on task defers at process exit.

## fabrum gaps found

Found building this package, and fixed in fabrum since:

- No touch pan to scroll a drawn scroll container: only the wheel, the
  scrollbar's thumb and `scrollTo` moved one, so the apps here declared
  `on_pointer` on the list and called
  `ctx.scrollTo("chapters", .{ .by = … }, .{})` from each drag. The runtime pans now when `Capabilities.pointer` is `touch`:
  a press on a list is a pan past the drag threshold (cancelling the tap,
  even on a row's button), and the apps declare nothing.
- Scrolls the app asks for (`scrollTo`) were always `content`. They take
  `ScrollOptions` now, `.{ .refresh = .interactive }` for a scroll that
  follows a gesture of the app's own; the page keys keep the default,
  `content`, a quality partial update of the list, which is right for a
  page turn.
- A list with more rows than `Context.Config.breadth` allowed crashed
  with `unreachable`; it fails the frame with `error.LayoutCapacity` now,
  logging which limit to raise (`ReaderShell.layout_capacity` raises it).

The directory selector's 6.5 SDK implementation restores the previous handler
and calls its callback with null on Back/cancel; it does not send `EVT_SHOW`.
If firmware restores the app handler without replying, the next event/frame
answers null by checking `GetEventHandler`. A replacement request also clears
any stale reply. The fake API exercises deferred confirmation, cancellation, and a lost reply
followed by a replacement request.
