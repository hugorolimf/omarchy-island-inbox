<div align="center">

# Island Inbox

**Your notification history, in a bell on the bar.**
Grouped by app, newest first, with the app's icon, and a click takes you back to where
the notification came from.

![Island Inbox](preview.png)

</div>

## Why this one

- 🔔 **A bell with a count** of what you haven't seen. With
  [Island Bar](https://github.com/hugorolimf/omarchy-bar) it's drawn in the bar's stroke style.
- 🗂️ **Grouped by app**, the last ones first; open a group to see them all, clear one app or
  everything.
- ↩️ **Click to go back**: to the app, or to the exact terminal and tmux pane for Claude
  Code's notifications when they carry it.
- 📱 iPhone notifications from [Island iPhone](https://github.com/hugorolimf/omarchy-island-iphone)
  show with the app's real icon.
- 🌍 English or Portuguese, following your system language.

## See it

Recorded on a real desktop, mouse and clicks included, with sample notifications.
The panel follows the system language; this take is in Portuguese.

**Do Not Disturb, clearing a group, showing every notice of an app**, from the bell.

![Island Inbox](assets/inbox.gif)

## Requirements

- [Island Kit](https://github.com/hugorolimf/omarchy-island-kit): the panel is drawn with it.
  Without it, the plugin shows an "Install Island Kit" button on the bar (in
  Portuguese, "Instale o Island Kit"); clicking it installs the Kit and restarts
  the shell.
- Omarchy's notifications (or [Island Notch](https://github.com/hugorolimf/omarchy-island-notch), which serves them in the notch):
  it reads their history in `~/.local/state/omarchy/notifications/history`.
- `inotifywait` (inotify-tools) to follow new notifications live.

## Install

```bash
omarchy plugin add https://github.com/hugorolimf/omarchy-island-kit --enable
omarchy plugin add https://github.com/hugorolimf/omarchy-island-inbox --enable
```

`omarchy-shell io.github.hugorolimf.inbox toggle` opens it.

## Files it writes

`~/.local/state/omarchy/io.github.hugorolimf.inbox/seen.json`: which notifications you've
already seen (for the count).

## Remove

```bash
omarchy plugin remove io.github.hugorolimf.inbox
rm -rf ~/.local/state/omarchy/io.github.hugorolimf.inbox
```

## License

[MIT](LICENSE)
