# trash-manager.yazi

An interactive trash manager for Yazi with filtering, bulk operations, and thumbnail previews.

## Features

- Browse all trashed items across volumes
- Filter items by path substring (case-insensitive)
- Multi-select with mark all/none
- Restore, permanently delete, or empty trash
- Undo the last trash operation (single keypress, with confirmation)
- Preview file details and thumbnails (images/videos)

## Installation

```sh
ya pkg add Argus-Khan/yazi-plugins:trash-manager
```

## Usage

Add this to your `~/.config/yazi/keymap.toml`:

```toml
[[mgr.prepend_keymap]]
on   = "U"
run  = "plugin trash-manager"
desc = "Trash manager"

[[mgr.prepend_keymap]]
on   = "u"
run  = "plugin trash-manager -- undo-last"
desc = "Restore last trashed batch"
```

### Keybindings (inside the modal)

| Key       | Action                                   |
| --------- | ---------------------------------------- |
| `j`/`k`   | Move up/down                             |
| `g`/`G`   | Top/bottom                               |
| `<Space>` | Toggle mark                              |
| `a`       | Mark all (filtered)                      |
| `c`       | Clear marks                              |
| `/`       | Filter by path                           |
| `\`       | Clear filter                             |
| `r`       | Restore selected                         |
| `u`       | Undo last trash (restore newest batch)   |
| `d`       | Delete selected (press twice to confirm) |
| `e`       | Empty entire trash                       |
| `v`       | Preview details + thumbnail              |
| `q`/`Esc` | Quit                                     |

### Headless mode

`plugin trash-manager -- undo-last` skips the modal and prompts to restore
every item sharing the most recent deletion timestamp. Useful as a
one-keystroke "undo" binding.

## Credits

The "undo last trash" action is inspired by
[boydaihungst/restore](https://github.com/boydaihungst/restore) (MIT,
Copyright (c) 2024 boydaihungst). Reimplemented here on top of `gio trash
--restore` so it shares the same backend as the rest of the manager.

## Dependencies

- `gio` (GLib) - required for trash operations
- `ffmpeg` - optional, for video thumbnails
- `imagemagick` - optional, for image thumbnails

## License

[UNDERCAT 1.0](../LICENSE)
