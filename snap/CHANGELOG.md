# Slyy Snap changelog

## 1.2.1

- Signed with the Slyy Snap certificate: macOS keeps the Screen Recording
  permission across updates from now on (allow it one last time after this
  update). Updates are only accepted if signed with the same certificate.
- Screen Recording: if an update made macOS forget the permission (the old
  entry stays switched on but no longer applies), Slyy Snap removes the stale
  entry and asks again; switch it on once and choose "Quit & Reopen".
- No capture without the permission (it would only record the wallpaper);
  instead a short explanation with a button to System Settings.

## 1.2.0

- Snaps are named slyy-00001.png, slyy-00002.png, … (no spaces, no date;
  numbers are never reused).
- After a capture: floating thumbnail with Edit / Copy / Show / close (click
  the image to edit too). The editor opening right away is now an option
  (Options > "Open Editor After Capture", off by default).
- Editor: click the file name in the title bar to rename the file.
- Editor: Move tool (V): drag any arrow, box, text, highlight … to move it.
- Editor: text is typed in place where you click (Return or click elsewhere
  places it, Esc cancels).
- Prepared for a stable signing certificate (keeps the Screen Recording
  permission across updates once release builds are signed with it); signed
  builds then only accept updates signed with the same certificate.
- Screen Recording prompt at most once per launch; new Options >
  "Reset Screen Recording Permission…" for a stuck entry.

## 1.1.1

- Slyy logo as app icon; menu bar icon: Slyy dot in a viewfinder.

## 1.1.0

- Editor: opens after each capture (switch off under Options) or via
  "Edit Last Snap" (⌃⇧E) / "Open Image in Editor…".
  Tools: arrow, box, ellipse, pen, highlight, text, pixelate, crop
  (keys A R O P H T X C), color, 3 line widths, undo (⌘Z),
  copy (⌘C), save (⌘S), save as (⇧⌘S).
- Release pipeline ready for Developer ID signing + notarization; once active,
  updates are only accepted from the same signing team.

## 1.0.1

- DMG download: double-click, drag Slyy Snap to Applications.

## 1.0.0

- Menu bar screenshot tool: area (⌃⇧1), window (⌃⇧2), screen (⌃⇧3).
- Saves PNGs to ~/Pictures/Slyy Snap (changeable) and copies them to the clipboard.
- Options: clipboard, sound, launch at login, automatic update checks.
- Self-update from github.com/simplify-erp/slyy-releases (SHA-256 + signature checked).
