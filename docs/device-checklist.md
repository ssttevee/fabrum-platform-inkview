# Checking a build on the device

The tests run against a fake InkView, so some things can only be checked
on a real reader. This page lists those checks, what to look for, and the
known risks. Use `ReaderShell-log.app` for these runs, so the log ends up
in `applications/ReaderShell.log`.

## Status

All eight checks passed on a Verse with firmware U629.6.8.4081. Step 7
passed after two fixes: a frame no longer draws over the dialog its own
update opened, and events that `Message` delivers to the handler while its
box is up now wait for the frame already under way. Other firmware hasn't
been tried.

## The first-run checks

1. **The app starts and the library loads.** The log's first line after
   `starting` should be `screen 758x1024 px, scale 2.21, viewport 343x464
   pt, drawing into the task framebuffer`.
   - `can't open libinkview.so` means the loader didn't find the library.
     Try a full path in `INKVIEW_LIBRARY`; it's under `/ebrmain/lib` on most
     firmware.
   - `X isn't in this libinkview` names a required function that's missing.
2. **The first screen appears** with one flash, with text at a sensible
   size and nothing under the status bar (which is hidden).
3. **A tap on Pick marks the row without a flash** (a small partial
   update). If the whole screen flashes, InkView's pending `needupdate`
   turned it into a full update, which is normal once.
4. **A pan scrolls the list.** The first two frames are gray, then black and
   white (A2), then one flash 0.7 s after you lift your finger brings the
   grays back. If A2 leaves the list unreadable because the grays are
   thresholded away, set `.refresh = .{ .interactive = .dynamic }`.
5. **The page keys scroll the list.** Back, on readers that have one,
   closes the app.
6. **A tap on the search field opens the system keyboard.** OK puts the
   text in the field after one flash. Cancel changes nothing. If the
   keyboard stays visible on the panel, `KBD_NOUPDATE_AFTER_CLOSE` plus the
   host's `EVT_SHOW` full refresh didn't cover it: drop the flag.
7. **Menu opens InkView's menu** at the top left. Settings shows the
   settings page, About shows a message box for 3 seconds, and Quit asks
   first, then quits.
8. **Leave for the home screen and come back.** The screen is redrawn.

## Risks

- **ABI and versions.** The bindings are built against the 6.10 headers'
  constants and struct layouts (`icanvas`, `imenu` and `irect` are
  unchanged since 5.2). The binary needs glibc 2.23 and its
  `libpthread`/`libdl`. On 6.11.1480, loading a library with an executable
  stack needs the tunable the log launcher sets. See
  [compatibility](compatibility.md).
- **A2 ghosting and legibility.** A2 thresholds grays away. The full
  refresh at the end cleans up, but a page of gray text may be unreadable
  during the gesture. The refresh policy can turn A2 off.
- **Keyboard repaint.** It hasn't been verified whether the library restores
  the pixels under the keyboard when `KBD_NOUPDATE_AFTER_CLOSE` is set. The
  host redraws everything on the `EVT_SHOW` that follows either way.
- **Entropy and `statx`.** Below glibc 2.25, std reads `/dev/urandom`, and
  nothing in this package asks for randomness. std's stat functions use
  `statx`, which the 3.10 kernel lacks. See
  [compatibility](compatibility.md).
- **zg on 32-bit.** fabrum's word segmentation uses its own rules on 32-bit
  targets, because zg's tables don't build there. Graphemes still come from
  zg.
- **`Message` blocks** inside `update`, so a 30-second message freezes the
  app for 30 seconds. It can also trigger fabrum's watchdog diagnostic,
  which by default warns when a view or update takes over 16 ms.
  `Options.watchdog_ms` is passed to the runtime: raise the budget for
  blocking dialogs, or set it to null or zero to turn the diagnostic off.
  The watchdog only runs in debug builds. It logs slow view and update
  calls, and doesn't interrupt the dialog.
- **Task shutdown.** `EVT_EXIT`, the host's close key, and the quit and
  close services all call `runtime.cancelTasks()` before InkView can end
  the process with `_exit`. Cancellation joins the workers while their
  runtime and services are still alive, so task `defer`s run. Tasks must
  use cancellation-aware I/O or `Task.checkCancel()` and return promptly. A
  task that ignores cancellation can block exit indefinitely. The SDK
  documents no fixed cleanup deadline, and a forced kill can skip
  `EVT_EXIT` entirely, so apps should save persistent state during normal
  operation too. No further frames are drawn once exit starts, even when a
  blocking `Message` re-enters the handler.
