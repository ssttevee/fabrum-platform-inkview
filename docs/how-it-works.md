# How the host works

This page explains what the host does between InkView and fabrum: how
frames reach the e-ink panel, how InkView's events become fabrum input, and
how fabrum's services map to InkView's dialogs, menus and keyboard. The
[README](../README.md) covers using the package.

## Contents

- [Refresh policy](#refresh-policy)
- [Framebuffer, scale and orientation](#framebuffer-scale-and-orientation)
- [Events and keys](#events-and-keys)
- [Timers and threads](#timers-and-threads)
- [Services](#services)

## Refresh policy

### Some background on e-ink

An e-ink panel doesn't redraw like an LCD. Each update physically moves ink
particles, and the panel offers several update modes that trade speed
against quality:

- A **full update** (GC16 with a flash) blinks the screen black and white,
  then draws all 16 grays cleanly. It's slow and visible, but clears
  leftover ghost images.
- A **partial update** (GC16 without a flash) redraws one rectangle in full
  gray quality without blinking. Repeated partial updates slowly leave
  **ghosting**, faint traces of what was there before.
- **A2** is a fast black-and-white mode for things that move, like
  scrolling. It's quick enough to follow a finger, but it drops the grays,
  so it has to be cleaned up afterwards.

fabrum doesn't know about any of this directly. With each frame, it says
what *kind* of change the frame is (`Runtime.refresh`): `content`,
`interactive` or `page`. `refresh.Policy` (`src/refresh.zig`) turns that
hint into an InkView update call, and keeps the state it needs to do so.

### From hint to update

| Hint | Update | Notes |
|---|---|---|
| `page` (the app asked, `ctx.refresh(.page)`) | `FullUpdate()` | GC16 with a clearing flash; resets the counters. |
| `content` (anything else) | `PartialUpdate(rect)` per damage region | GC16, no flash. |
| `interactive` (a drag, a scroll) | `DynamicUpdate(rect)` for the first `a2_enter_after` frames (2), then `DynamicUpdateA2(rect)` | A short gesture never pays A2's entry and exit. |
| A2 ends | `FullUpdate()` `a2_exit_delay` (700 ms) after the last interactive frame | What `ExitUpdateA2` does; a hard InkView timer. Content frames meanwhile are gray `DynamicUpdate`s and push the exit out. The framebuffer always holds full grays (nothing is dithered in place), so the full refresh restores them. |
| Every `full_every` (12) partial or gray dynamic updates | `FullUpdate()` | Clears the ghosting partial updates leave, as readers do every few pages. |
| `EVT_SHOW`, `EVT_REPAINT`, `EVT_FOREGROUND` | everything redrawn, `FullUpdate()` (or a whole-screen `PartialUpdate` with `show_refresh = .partial`) | The library restored the screen under us. |
| `EVT_ORIENTATION` | everything redrawn, `FullUpdate()` | Rotation always requests a page refresh. |

The policy is configured through `Options.refresh`. A2 frames don't advance
the periodic cleaning counter. If the library has no `DynamicUpdateA2`,
gestures stay gray. Gray updates fall back to `PartialUpdate` when
`DynamicUpdate` is missing.

### Before and after

The earlier Clay-based reader redrew the whole screen and called
`FullUpdate` on every repaint, so every tap flashed. Here a tap on a button
is a partial update of just the button's rectangle, a pan is A2, and the
only flashes are the app's page turns and the periodic clean.

## Framebuffer, scale and orientation

**Framebuffer.** The task framebuffer from `GetCanvas()` is the surface z2d
draws into, in place, as KOReader does. On the B288 it is `gray8`: one byte
per pixel, with rows `scanline` bytes apart. Only the damage is redrawn. If
a firmware's framebuffer isn't 8-bit, the host draws into a private `gray8`
buffer and copies it across whole with `Stretch`. Damage rectangles are in
points; they are scaled to pixels and rounded outwards before the update
call. InkView aligns them to 4 pixels itself.

**Scale.** fabrum lays out in points. The scale, in pixels per point, is
`Options.scale` if set. Otherwise it is the panel's DPI (`get_screen_dpi`,
or `Options.dpi` = 212 without it) divided by `points_per_inch` (96). That
gives 2.2 pixels per point on the Verse. The theme's 13-point font is then
29 pixels, about what the earlier Clay-based reader drew at 24–32 px. A
758×1024-pixel panel becomes a 343×464-point viewport. Pointer coordinates
are divided by the same scale.

**Orientation.** `Options.orientation` (portrait by default) is set at
`EVT_INIT`. `EVT_ORIENTATION` is only delivered on 6.x with
`SUPPORT_EVT_ORIENTATION`, which `Options.follow_gsensor` sets. When it
arrives, the host calls `SetOrientation`, re-reads `ScreenWidth`,
`ScreenHeight` and the canvas, and redraws.

**Status panel.** InkView's status panel is hidden
(`SetPanelType(PANEL_DISABLED)`) unless `Options.panel = .shown`. When it's
shown, the viewport leaves out `PanelHeight()`.

## Events and keys

InkView calls one handler function for every event. The host translates
each one:

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
| `EVT_EXIT` | cancel and join runtime tasks before InkView calls `_exit`; cannot be refused and does not draw |
| `EVT_CUSTOM + 1` | a wake from `Poster.post` on another thread |

The handler returns 1 when the app took the event, so InkView's defaults
(the panel, the power key) apply to the rest.

**Keys.** `KeyMap` (`src/keys.zig`) decides which fabrum key each hardware
key means. By default:

- Both pairs of page keys are Page Up and Page Down. On the Verse the page
  keys arrive as `IV_KEY_PREV` (0x18) and `IV_KEY_NEXT` (0x19), which the
  earlier reader saw as 24 and 25.
- The arrows are themselves, and OK is Enter.
- Back is Escape, which clears drawn focus in fabrum. The exception is when
  Back is `Options.close_key`: then it asks `Runtime.shouldClose` and calls
  `CloseApp`.
- Menu is F10.
- Home and Power are left to the library.

fabrum only takes keys while a drawn element has focus. The example gives
its list focus on its first frame, so the page keys scroll it.

## Timers and threads

**Frame timers.** `Runtime.nextFrame` says when fabrum next wants to draw.
The host arms one InkView timer for it (`SetHardTimer`, or `SetWeakTimer`
with `Options.frame_timer = .weak`) and re-arms it after every frame,
because the library's timers are one-shot and keyed by their function. The
A2 exit is a second timer.

**Background tasks.** While background tasks are pending, a hard timer also
checks for completed tasks at most every `Options.task_poll_interval_ms`
milliseconds (100 by default). This is a fallback for firmware that queues
worker events without promptly waking the idle loop. It stops once the tasks
are collected, and keeps any earlier UI timer deadline. Set the option to
`null` to test direct wake delivery without periodic polling; ordinary UI
timers still run.

`Options.task_activity` is called on the main thread while work is pending,
including on fallback ticks. It is called with `false` after completion, or
after shutdown joins the workers, so an app can balance its own sleep
protection. The activity hook stays enabled when polling is disabled.

**Threads.** Everything runs on InkView's loop thread. A `Poster.post` from
another thread calls `SendEvent`, which libinkview documents as the way for
worker threads to reach the handler. Its queue is a ring of 128 entries, so
wakes are coalesced, with at most one in flight. Nothing else in InkView is
called off the loop thread.

## Services

fabrum's services are the things a platform offers beyond drawing:
dialogs, menus, text entry and so on. Here's how each maps to InkView:

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
until the user answers. Then it restores the pixels it saved from under
itself, and dialogs also refresh. While one is up, frames are held: timers
still fire and posts still queue. If any frame was held, everything is
redrawn when the dialog closes and refreshed without a flash, so whatever a
timer or a post changed under the dialog isn't lost to the restore. The
keyboard also sends `EVT_SHOW` when it closes, which redraws and refreshes
the whole screen; `KBD_NOUPDATE_AFTER_CLOSE` makes that the only refresh.

**The directory selector.** The 6.5 SDK's implementation restores the
previous handler and calls its callback with null on Back or cancel; it
doesn't send `EVT_SHOW`. If firmware restores the app's handler without
replying, the next event or frame answers null by checking
`GetEventHandler`. A replacement request also clears any stale reply. The
fake API exercises deferred confirmation, cancellation, and a lost reply
followed by a replacement request.
