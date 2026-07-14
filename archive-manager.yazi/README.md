# archive-manager.yazi

An archive toolkit for Yazi: preview, extract, and compress. Backed by `7z` (and `tar` for non-7z formats).

## Features

- **Preview** — inline file listing for archives in the preview pane, scrollable
- **Extract** — `7z x` in the background with auto-naming of the output directory
- **Compress** — `7z`/`zip`/`tar`/`tar.{gz,bz2,xz,zst}` of the current selection, auto-named, collision-safe (`_1`, `_2`, …)
- All operations run in the background — yazi stays responsive

## Installation

```sh
ya pkg add Argus-Khan/yazi-plugins:archive-manager
```

## Usage

Add the previewer to your `~/.config/yazi/yazi.toml` so yazi calls this plugin for archive mimes:

```toml
[plugin]
prepend_previewers = [
    { mime = "application/zip",              run = "archive-manager" },
    { mime = "application/x-7z-compressed",  run = "archive-manager" },
    { mime = "application/x-rar",            run = "archive-manager" },
    { mime = "application/vnd.rar",          run = "archive-manager" },
    { mime = "application/x-tar",            run = "archive-manager" },
    { mime = "application/x-bzip2",          run = "archive-manager" },
    { mime = "application/x-xz",             run = "archive-manager" },
    { mime = "application/xz",               run = "archive-manager" },
    { mime = "application/x-zstd",           run = "archive-manager" },
    { mime = "application/zstd",             run = "archive-manager" },
    { mime = "application/java-archive",     run = "archive-manager" },
    { mime = "application/x-xapk",           run = "archive-manager" },
]
```

Add an opener so `Enter` on an archive extracts + opens it in a GUI:

```toml
[opener]
extract = [
    { run = 'plugin archive-manager', desc = "Extract with 7z (Background)" }
]

[open]
rules = [
    { mime = "application/*zip",            use = ["extract", "open_gui"] },
    { mime = "application/x-7z-compressed", use = ["extract", "open_gui"] },
    { mime = "application/x-rar",           use = ["extract", "open_gui"] },
    { mime = "application/x-tar",           use = ["extract", "open_gui"] },
    { mime = "application/x-bzip2",         use = ["extract", "open_gui"] },
    { mime = "application/x-xz",            use = ["extract", "open_gui"] },
]
```

Add keybinds to `~/.config/yazi/keymap.toml`:

```toml
[[mgr.prepend_keymap]]
on   = "E"
run  = "plugin archive-manager"
desc = "Extract selected archives (background)"

[[mgr.prepend_keymap]]
on   = "C"
run  = "plugin archive-manager --compress"
desc = "Compress selection as 7z"
```

## Compress formats

| Arg `--format=` | Extension | Tool |
|-----------------|-----------|------|
| `7z` *(default)* | `.7z`     | `7z a` |
| `zip`            | `.zip`    | `7z a -tzip` |
| `tar`            | `.tar`    | `tar -cf` |
| `tar.gz`         | `.tar.gz` | `tar -czf` |
| `tar.bz2`        | `.tar.bz2`| `tar -cjf` |
| `tar.xz`         | `.tar.xz` | `tar -cJf` |
| `tar.zst`        | `.tar.zst`| `tar --zstd -cf` |

Examples:

```sh
plugin archive-manager --compress
plugin archive-manager --compress --format=zip
plugin archive-manager --compress zip     # positional also works
```

The output filename is `<basename-of-first-selected-item>.<ext>`, written to the current directory, with `_1`, `_2`, … appended if a file with that name already exists.

## Dependencies

- `7z` — for extraction and 7z/zip compression
- `tar` — for tar-family compression
- `zstd` — only needed for `--format=tar.zst`

## License

[UNDERCAT 1.0](../LICENSE)
