# mounter.yazi

Interactive device mounter for Yazi. Native yazi UI replacement for the
`mounter` shell script. Mount and unmount USB drives, phones (MTP/PTP/AFC), and
network shares (SFTP/SMB).

## Features

- Native yazi modal UI — no `whiptail`/ncurses
- USB drives: list, mount, unmount via `lsblk` + `udisksctl`
- Phones: mount/unmount MTP/PTP/AFC via `gio`, with `~/mtp:host=...` symlinks
- SFTP/SMB: mount/unmount existing shares, discover hosts via `avahi-browse`,
  or manually enter an address
- Username/password prompts handled by yazi's `ya.input`

## Installation

```sh
ya pkg add Argus-Khan/yazi-plugins:mounter
```

## Usage

Add this to your `~/.config/yazi/keymap.toml`:

```toml
[[mgr.prepend_keymap]]
on   = "M"
run  = "plugin mounter"
desc = "Open mounter interface"
```

Press `M` inside yazi to open the mounter modal, then:

| Key | Action |
|-----|--------|
| `j`/`k` or `↑`/`↓` | Move up/down |
| `g`/`G` | Top/bottom |
| `<Enter>` or `l` | Activate selected item |
| `r` | Refresh the device list |
| `q` or `<Esc>` | Quit |

For SMB mounts, you will be prompted for username and password (leave blank for
guest).

## Dependencies

- `lsblk` — list USB drives
- `udisksctl` — mount/unmount drives
- `gio` — phones and network shares (required for everything except USB drives)
- `avahi-browse` — network discovery (optional)
- `timeout` — avahi scan timeout (optional)

## License

[UNDERCAT 1.0](../LICENSE)
