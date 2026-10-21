# Tests and the emulator

## What `zig build test` covers

The tests need no device. They run the host against a fake InkView
(`src/fake.zig`), which has a framebuffer, timers, modal UIs and a clock.

- **`refresh.zig`**: sequences of refresh hints and the updates they become.
  This covers content and page updates, A2's entry delay and exit, content
  frames during A2, missing library functions, and the periodic full
  update.
- **`keys.zig`, `inkview.zig`**: the key map; the loader failing cleanly;
  the struct layouts; the flag structs packing the same as the header's
  constants; and the optional functions defaulting to null.
- **`host.zig`**: the keyboard flags for a text request.
- **`host_test.zig`**: the host driven by the fake InkView, with a small
  reader component. It covers:
  - init and show (panel, orientation, one full update);
  - a tap's partial update covering the button;
  - a pan's gray, A2 and cleaning sequence, with the exit timer;
  - libraries without A2 or dynamic updates;
  - the periodic full update, and the app's `page` hint;
  - the keyboard round trip into the field, and the `EVT_SHOW` after it;
  - `Dialog3`'s answers, quitting, and a dialog refused while another is up;
  - frames held under a dialog, and the redraw after it;
  - the `imenu` tree with ids beyond `short`'s range;
  - a blocking `Message` with timers inside;
  - hard and weak frame timers;
  - page keys and `EVT_NEXTPAGE`, and the close key;
  - rotation, background and foreground;
  - a post from another thread coalesced into one wake;
  - `openDirectory` with and without the library function;
  - a 24-bit framebuffer, the panel's height, and scale from DPI or set
    explicitly.

  After every step that draws, the fake's framebuffer (whose rows are
  padded past the width) is compared with a full redraw.
- **`ReaderShell.zig`**, through fabrum's `app.testing.Harness` with fake
  services: the list and Pick, the search field's keyboard and filter, the
  menu and settings page, Quit's dialog, the page keys (inverted by the
  setting), and a pan.

## The emulator

`zig build emulator` builds the example for x86_64 Linux, as
`zig-out/emulator/ReaderShell`.

The SDK's emulator is just a `libinkview.so`
(`sdk/6.10/B288/emulator-x86_64/` in libinkview) that draws into a GTK 2
window. It needs Debian 12's libraries (ICU 72, jsoncpp), so it runs in a
container, not on macOS. Put the library on `LD_LIBRARY_PATH` or in
`INKVIEW_LIBRARY`, and run from a directory with the SDK's `system/` tree
(fonts and config), as described in section 6.5 of libinkview's
[building.md](https://github.com/ssttevee/libinkview/blob/trunk/docs/building.md).

This hasn't been tried yet.
