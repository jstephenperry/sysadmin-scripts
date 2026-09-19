# sysadmin-scripts

Personal sysadmin scripts for my own systems, organized by OS.

## AI Disclosure

These are my own personal scripts, written for my own systems. AI assistance
(Claude) is used to help generate and test them. I review everything before
it runs, and I take responsibility for what's in this repo, but you should
review any script yourself before running it, especially anything that
touches disks, partitions, or encryption. Use at your own risk.

## Layout

- `linux/disk-cloning/`: scripts for cloning a LUKS-encrypted Linux disk to a
  larger drive from a live USB session (identify drives, then clone/resize).
- `linux/disk-tools/`: a scoped sudoers drop-in for disk diagnostics/repair,
  and a setup script that repurposes secondary drives as bulk storage,
  container image storage, and a restic-backed backup target.
