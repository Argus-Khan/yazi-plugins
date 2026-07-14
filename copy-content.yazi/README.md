# copy-content.yazi

Copy the contents of the hovered file to the system clipboard. Text and empty files only — binary files are rejected.

## Features

- Detects text vs. binary by sniffing for NUL bytes in the first 4 KiB
- Empty files are treated as text and copied as an empty string
- Clipboard backend fallback: `wl-copy` → `xclip` → `xsel`
- Falls back to yazi's built-in `code` previewer for binary files
- Status notifications on success or failure

## Installation

```sh
ya pkg add Argus-Khan/yazi-plugins:copy-content
```

## Usage

Add this to your `~/.config/yazi/keymap.toml`:

```toml
[[mgr.prepend_keymap]]
on   = ["c", "c"]
run  = "plugin copy-content"
desc = "Copy file content (text/empty)"
```

## Dependencies

- One of: `wl-copy` (Wayland), `xclip` (X11), or `xsel` (X11)

## License

[UNDERCAT 1.0](../LICENSE)
