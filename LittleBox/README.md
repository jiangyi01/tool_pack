# LittleBox 📦

**English** · [简体中文](README.zh-CN.md)

A menu bar helper for MacBooks with a notch. LittleBox leaves your menu bar exactly as it is and hides nothing. Icons that the notch covers, or that don't fit, show up in a small strip under 📦, looking exactly as they do in the menu bar.

## Usage

- **Point at 📦**: the strip drops down with the icons this display can't fit.
- **Rest on an icon in the strip**: it opens that icon's own menu, no click needed. Slide to another icon and the menu follows, just like the real menu bar.
- Click, right-click and ⌥-click work as usual too.
- **Right-click 📦**: Settings (permissions, hover on/off, launch at login).

If clicking an icon runs an action instead of showing a menu, LittleBox remembers it after two hovers that show no menu. Hover then leaves it alone, and clicking still works. You can reset this in Settings. Control Center and other system menu items are never remembered this way.

Menu bar icons of Electron apps (for example the Claude desktop app) ignore Accessibility actions, so hover can't open them. The strip says "Click to open" instead. On click, LittleBox clicks a copy of the icon that is visible on another display; if it isn't visible on any display, it can't be opened.

If a hidden icon belongs to an app that doesn't support Accessibility actions, the bottom of the strip suggests ⌘-dragging it further right in the menu bar, where it stays visible.

## Works on any Mac

- Nothing is hard-coded: the notch position comes from the system, and hidden icons are worked out separately for each display. An icon that fits on an external display doesn't appear in that display's strip.
- macOS 14 or later. Universal binary for Apple silicon and Intel.
- The interface follows the system language (Chinese or English).

## Build and install

No Xcode needed; the Command Line Tools are enough.

```bash
./build_app.sh --run          # build, install to ~/Applications and launch
./build_app.sh --zip          # also write dist/LittleBox.zip to copy to another Mac
```

The app is ad-hoc signed. macOS ties permissions to the signature of each build, so a rebuild invalidates them. `build_app.sh` clears LittleBox's own stale entries; on the next launch, click **Enable…** in Settings to grant them again. If a switch is on but still doesn't take effect, Settings will suggest removing LittleBox from the list with − and dragging it back in.

To use it on another Mac, unzip `LittleBox.zip`, move it to Applications, then run:

```bash
xattr -dr com.apple.quarantine /Applications/LittleBox.app
```

Grant the permissions in the Settings window on first launch.

## Permissions

- **Accessibility** (required): to find menu bar icons and open them for you.
- **Screen Recording** (recommended): so the icons in the strip look exactly as in the menu bar, including text and numbers such as `971` or `A 57 · B 67`. Without it, the strip shows the app icon plus the item's own text.

## How it works

- LittleBox reads every app's `AXExtrasMenuBar` through the Accessibility API and uses CGWindowList to see which icons the system has hidden on which display. On macOS 26 each display has its own copy of every icon window, and copies covered by the notch are moved off screen. Copies are paired across displays with a width-based sequence alignment, because their order isn't always identical.
- Icons are opened with Accessibility actions: `AXPress`/`AXShowMenu` to open, `AXCancel` to close. The pointer never moves, and icons behind the notch can be opened too. Only when an app ignores Accessibility does it fall back to a synthetic click.
- A menu or popover is recognised by comparing the on-screen windows before and after the press, not by guessing from window levels.

## Debugging

```bash
open "littlebox://diagnose"   # writes ~/Library/Logs/LittleBox/diagnostics.txt
open "littlebox://open"       # opens the strip
open "littlebox://settings"   # opens Settings
.build/release/LittleBox --preview out.png [--dark] [--wide] [--footer]   # render the strip offscreen to check the layout
.build/release/LittleBox --selftest                                        # self-test, no permissions needed
```

Every icon LittleBox opens or closes is recorded in `~/Library/Logs/LittleBox/events.log` (cleared automatically past 500 KB), so problems can be diagnosed afterwards.

```bash
tail -50 ~/Library/Logs/LittleBox/events.log
```
