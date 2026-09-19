#!/bin/bash
set -euo pipefail

echo "== 1. Persistent mounts (sdb=bulk, sdc=backup, sdd=containers) =="
mkdir -p /mnt/bulk /mnt/containers/docker /mnt/containers/podman /mnt/backup

if ! grep -q "sdb/sdc/sdd repurposing" /etc/fstab; then
cat >> /etc/fstab <<'EOF'

# --- Added for sdb/sdc/sdd repurposing (2026-09-19) ---
UUID=bdf20ac1-12bd-4ac1-bc2f-f20f1d791c3e  /mnt/bulk        ext4  defaults,noatime,nofail  0  2
UUID=0430cb59-4f62-47f3-90fe-f7a59a0584c1  /mnt/backup      ext4  defaults,noatime,nofail  0  2
UUID=f154e9f7-6f70-4108-b916-6f1d863f0245  /mnt/containers  ext4  defaults,noatime,nofail  0  2
EOF
fi

umount /run/media/stephen-perry/dev1 2>/dev/null || true
umount /run/media/stephen-perry/data1 2>/dev/null || true
umount /run/media/stephen-perry/dev2 2>/dev/null || true
mount -a

chown stephen-perry:stephen-perry /mnt/bulk
chown stephen-perry:stephen-perry /mnt/containers/podman

echo "== 2. Docker (data-root -> /mnt/containers/docker) =="
apt-get install -y docker.io
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'EOF'
{
  "data-root": "/mnt/containers/docker"
}
EOF
systemctl enable --now docker
usermod -aG docker stephen-perry

echo "== 3. Podman (rootless, graphroot -> /mnt/containers/podman) =="
apt-get install -y podman
sudo -u stephen-perry mkdir -p /home/stephen-perry/.config/containers
cat > /home/stephen-perry/.config/containers/storage.conf <<'EOF'
[storage]
driver = "overlay"
graphroot = "/mnt/containers/podman"
EOF
chown -R stephen-perry:stephen-perry /home/stephen-perry/.config/containers

echo "== 4. Restic backup (home + /etc -> sdc, daily, 7d/4w/6m retention) =="
apt-get install -y restic
mkdir -p /etc/restic
if [ ! -f /etc/restic/password ]; then
  openssl rand -base64 32 > /etc/restic/password
fi
chmod 600 /etc/restic/password

cat > /etc/restic/excludes.txt <<'EOF'
/home/stephen-perry/.cache
/home/stephen-perry/.local/share/Trash
EOF

if [ ! -d /mnt/backup/restic-repo ]; then
  restic -r /mnt/backup/restic-repo --password-file /etc/restic/password init
fi

cat > /etc/systemd/system/restic-backup.service <<'EOF'
[Unit]
Description=Restic backup of home + /etc to sdc

[Service]
Type=oneshot
ExecStart=/usr/bin/restic -r /mnt/backup/restic-repo --password-file /etc/restic/password backup /home/stephen-perry /etc --exclude-file=/etc/restic/excludes.txt
ExecStartPost=/usr/bin/restic -r /mnt/backup/restic-repo --password-file /etc/restic/password forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune
EOF

cat > /etc/systemd/system/restic-backup.timer <<'EOF'
[Unit]
Description=Daily restic backup to sdc

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now restic-backup.timer

echo
echo "===================================================================="
echo "Setup complete."
echo "RESTIC PASSWORD (save this to a password manager NOW, then never look at this output again):"
cat /etc/restic/password
echo "===================================================================="
echo "NOTE: you must log out/in (or run 'newgrp docker') for the docker group membership to take effect."
