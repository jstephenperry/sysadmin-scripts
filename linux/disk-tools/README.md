# disk-tools

Scripts for diagnosing and repurposing internal drives on `z840-devcore`.

- `claude-disk-tools.sudoers`: a `/etc/sudoers.d/` drop-in granting a narrow,
  command-scoped NOPASSWD list for disk diagnostics (`smartctl`, `lsblk`,
  `fdisk -l`, `dmesg`, etc.) and repair (`fsck`, `mount`, `resize2fs`, etc.).
  Destroy-capable tools (`dd`, `mkfs*`, `wipefs`, `sgdisk`, `parted` write
  subcommands) are deliberately excluded and still require an interactive
  password. Validate with `visudo -c -f claude-disk-tools.sudoers` before
  installing to `/etc/sudoers.d/`.
- `setup-drives.sh`: one-time root setup that mounts three secondary drives
  by UUID (`/mnt/bulk`, `/mnt/backup`, `/mnt/containers`), installs and
  configures Docker + rootless Podman with image storage on `/mnt/containers`,
  and sets up a daily `restic` backup of `/home` + `/etc` to `/mnt/backup`
  with a systemd timer and 7-daily/4-weekly/6-monthly retention. Generates
  a random restic repo password on first run and prints it once — save it
  to a password manager immediately; losing it makes the backup unreadable.
