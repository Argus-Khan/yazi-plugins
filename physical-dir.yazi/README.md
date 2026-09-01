# physical-dir.yazi

Resolve the current directory's symlink to its physical (real) path. Equivalent to `cd -P .` in the shell.

## Features

- Resolves symlinked directories to their real path using `realpath`
- Notification with the resolved path
- No-op notification if already at the physical path

## Installation

```sh
ya pkg add Argus-Khan/yazi-plugins:physical-dir
```

## Usage

Add this to your `~/.config/yazi/keymap.toml`:

```toml
[[mgr.prepend_keymap]]
on   = ["g", "p"]
run  = "plugin physical-dir"
desc = "Cd to physical (resolved) dir"
```

## Dependencies

- `realpath`

## License

[UNDERCAT 1.0](../LICENSE)
