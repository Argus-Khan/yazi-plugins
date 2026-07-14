# trash-manager.yazi

An interactive trash manager for Yazi with filtering, bulk operations, and thumbnail previews.

## Features

- Browse all trashed items across volumes
- Filter items by path substring (case-insensitive)
- Multi-select with mark all/none
- Restore, permanently delete, or empty trash
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
```

### Keybindings

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
| `d`       | Delete selected (press twice to confirm) |
| `e`       | Empty entire trash                       |
| `v`       | Preview details + thumbnail              |
| `q`/`Esc` | Quit                                     |

## Dependencies

- `gio` (GLib) - required for trash operations
- `ffmpeg` - optional, for video thumbnails
- `imagemagick` - optional, for image thumbnails

## License

UNDERCAT 1.0
