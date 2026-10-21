# fabrum-platform-inkview

Run [fabrum](https://github.com/ssttevee/fabrum) apps on PocketBook
e-readers.

PocketBook readers come with their own UI library, **InkView**. This
package connects a fabrum app to it. InkView delivers taps and key presses,
fabrum works out what the screen should look like, and this package draws
the result onto the e-ink panel and picks the right kind of screen refresh.
You write an ordinary fabrum component, and it runs on the reader.

It was written for the **PocketBook Verse** (model 629, Allwinner B288).
One build runs on firmware 6.8, 6.9 and 6.10–6.11. **It has passed the
first-run checks on a Verse with firmware 6.8**
([details](docs/device-checklist.md)). The bindings are written against
the 6.10 SDK headers and
[libinkview](https://github.com/ssttevee/libinkview)'s
[documentation](https://github.com/ssttevee/libinkview/blob/trunk/docs/README.md).

## What an app looks like

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

`run` does the setup and hands control to InkView:

1. It loads `libinkview.so` from the device. Nothing from the SDK is linked
   into your binary.
2. It creates the fabrum runtime with an e-reader's **capabilities**: a
   touch screen, no hover, no animation, 16 shades of gray, and an
   on-screen keyboard. fabrum's theme switches to high contrast to suit.
3. It connects fabrum's **services**, such as dialogs, menus and text
   entry, to InkView's own versions of them.
4. It gives InkView the event handler, and InkView runs the app from then
   on. `run` never returns on the device: InkView ends the process when the
   app closes.

## Why e-ink needs special handling

An e-ink screen can't redraw like a normal display. Each update physically
moves ink, and the panel offers several update modes:

- a **full** update blinks the whole screen to clear leftover "ghost"
  images, which is slow and visible;
- a **partial** update redraws one rectangle cleanly, without a blink;
- a fast black-and-white mode called **A2** is quick enough to follow a
  finger while scrolling, but loses the grays until the next clean update.

fabrum tags every frame with what kind of change it is (`content`,
`interactive` or `page`), and with which regions changed. This package
redraws only those regions and turns each tag into the right update. A tap
on a button refreshes just the button, without a flash. Scrolling uses A2,
and is cleaned up shortly after your finger lifts. Full flashes happen only
when the app turns a page, and every so often to clear ghosting. The earlier
Clay-based reader flashed the whole screen on every tap.
[How it works](docs/how-it-works.md#refresh-policy) has the exact rules.

## Add it to your app

Fetch fabrum and this package:

```sh
zig fetch --save git+https://github.com/ssttevee/fabrum#trunk
zig fetch --save git+https://github.com/ssttevee/fabrum-platform-inkview#trunk
```

Then, in `build.zig`:

```zig
const fabrum_mod = b.dependency("fabrum", .{ .target = target, .optimize = optimize, .platform = .none }).module("fabrum");
const inkview = b.dependency("fabrum_platform_inkview", .{ .target = target, .optimize = optimize });
const platform = inkview.module("fabrum-platform-inkview");
@import("fabrum_platform_inkview").addFabrum(platform, fabrum_mod);
exe.root_module.addImport("fabrum", fabrum_mod);
exe.root_module.addImport("fabrum-platform-inkview", platform);
exe.root_module.link_libc = true; // needed for dlopen
```

**Why `addFabrum`?** This package uses fabrum, and so does the
[z2d renderer](https://github.com/ssttevee/fabrum-renderer-z2d) it draws
with. Neither fetches its own copy. `addFabrum` hands both of them *your*
fabrum module. Without it, the program would contain two separate copies of
fabrum, and it wouldn't build.

fabrum is built with `.platform = .none` because there's no desktop toolkit
on the reader. This package plays the toolkit's part: in fabrum's terms, it
is the **host**.

## Build the example

The repository includes an example app, **ReaderShell**: the first screen
of a reading app, with a chapter list, search, a menu, dialogs and a
settings page. You need **Zig 0.17.0**. `zig build` fetches the
dependencies from GitHub.

```sh
zig build            # zig-out/pocketbook/ReaderShell.app and ReaderShell-log.app
zig build app        # the same device build, as an explicit step
zig build test       # tests against a fake InkView; no device needed
zig build emulator   # zig-out/emulator/ReaderShell, for x86_64 Linux
```

The device build always targets the Verse (32-bit ARM, glibc 2.23), whatever
`-Dtarget` says. It's `ReleaseSmall` by default. Use
`-Ddevice-optimize=safe` to keep safety checks and symbols, which makes
crashes on the device easier to trace. `-Doptimize` applies to the tests
and the emulator instead.

[Compatibility](docs/compatibility.md) explains exactly what the binary
needs from the device, and how that was checked against each firmware.

## Put it on the reader

The same `ReaderShell.app` works on B288 firmware 6.8, 6.9 and 6.10+. It has
been run on 6.8 hardware. For 6.9 and 6.10, the device's libraries have been
checked, but the app hasn't been run on those readers yet. So start with
the log launcher on each firmware version.

1. Connect the reader by USB and choose **PC link**.
2. Copy `zig-out/pocketbook/ReaderShell.app` into `applications/` on the
   reader. For the first runs, copy `ReaderShell-log.app` too. It's a small
   shell script that runs the app and appends its output to
   `applications/ReaderShell.log`. If a system library is missing, the
   error appears there before the app even starts.
3. On macOS, run `dot_clean /Volumes/<reader>/applications`, so that macOS's
   hidden `._ReaderShell.app` file doesn't show up as an extra app. Then
   eject.
4. Start **ReaderShell** (or **ReaderShell-log**) from the Applications
   list.

To close it, use Menu → Quit, or Back on readers that have a Back key (the
Verse only has Home, two page keys and Power). Home leaves the app running
in the background: starting it again returns to it. Quit it before copying a
new build over it.

Apps run as the user `reader`, with `/` as the current directory. This
package uses no relative paths.

Readers with the RK3566 chip on firmware 6.11 are a different target (their
SDK is hard-float), which this build doesn't cover.

## How InkView maps to fabrum

| fabrum | On the reader |
|---|---|
| Taps, drags, long presses | InkView's pointer events |
| Keys | The hardware keys. Page keys are Page Up and Page Down, OK is Enter, Back is Escape (or closes the app, if it's the `close_key`), and Menu is F10. |
| Timers and animation frames | InkView timers |
| Posting a message from another thread | `SendEvent`, which wakes InkView's loop |
| Alerts and confirmations | `Message` and `Dialog3` |
| Popup menus | `OpenMenu` |
| Text entry | The on-screen keyboard (`OpenKeyboard`) |
| Choosing a directory | `OpenDirectorySelector`, on firmware up to 6.5 only |
| Choosing a file | Not available: InkView has no file chooser |
| Clipboard | Kept inside the app |
| Drawing | Straight into the panel's grayscale framebuffer, with z2d |

A few things behave differently from a desktop:

- **InkView's dialogs block.** `Message`, for example, doesn't return until
  the box goes away, so a 30-second message freezes the app for 30 seconds.
  Timers keep running underneath, and the screen is brought up to date when
  the dialog closes.
- **Keys only reach focused elements.** fabrum delivers keys only while a
  drawn element has focus. The example focuses its list on the first
  frame, so the page keys scroll it.
- **Closing cancels background tasks.** When the app exits, it cancels and
  waits for running tasks, so they must stop promptly when cancelled.

[How it works](docs/how-it-works.md) has the details: every event, key,
timer and service, and how dialogs and repaints interact.

## The code

| Piece | File | What it does |
|---|---|---|
| Bindings | `src/inkview.zig` | The 23 InkView functions the host calls, with Zig types. `Api.load` looks them up in `libinkview.so` at start-up with `std.DynLib`. Optional functions (`DynamicUpdateA2`, `DynamicUpdate`, `get_screen_dpi`, `OpenDirectorySelector`) are null on firmware that lacks them, and the host works without them. Every required function exists in every version since 5.2. Adding a function means adding one field; the loader is generated from the fields. |
| Host | `src/host.zig` | `App(Root)`: the event handler, frames, the framebuffer, timers, wake-ups from other threads, and the services. |
| Refresh policy | `src/refresh.zig` | Turns fabrum's refresh hints into e-ink updates. Plain logic with no InkView calls, so it's easy to test. |
| Keys | `src/keys.zig` | `KeyMap`: which fabrum key each hardware key means. |
| Fake | `src/fake.zig` | A fake InkView for tests, with a framebuffer, timers, modal UIs and a clock. |
| Example | `src/example/` | `ReaderShell` and its `main.zig`. |

## More documentation

- [How it works](docs/how-it-works.md): refresh rules, the framebuffer and
  scaling, events, keys, timers, threads and services.
- [Compatibility](docs/compatibility.md): the device build, C library
  versions, and known limits of the old kernel (randomness, file metadata).
- [Device checklist](docs/device-checklist.md): what to check on a real
  reader, the results so far, and known risks.
- [Tests and the emulator](docs/testing.md): what the tests cover, and
  running the SDK's emulator.
- [fabrum gaps found](docs/fabrum-gaps.md): features fabrum gained because
  of this package.
