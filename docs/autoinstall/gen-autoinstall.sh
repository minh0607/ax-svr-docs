#!/usr/bin/env bash
# ============================================================================
# AX Svr — Generator autoinstall Ubuntu 24.04 (NoCloud seed ISO mỗi host)
# Sinh user-data + meta-data + seed.iso cho từng VM Linux từ bảng host.
# Scope: OS + mạng 2 NIC + LVM + đĩa /data (+ /backup cho DB3) + admin + SSH.
# Phần mềm theo vai trò cài SAU theo Phase docs.
# ----------------------------------------------------------------------------
# Yêu cầu: cloud-image-utils (cung cấp 'cloud-localds')   ->  sudo apt install cloud-image-utils
# Chạy:    ./gen-autoinstall.sh
# Kết quả: ./out/<host>/{user-data,meta-data}  và  ./out/<host>-seed.iso
# ============================================================================
set -euo pipefail

# ----- THAM SỐ CHUNG (chỉnh cho đúng môi trường) ----------------------------
ADMIN_USER="axadmin"
WAN_IF="ens3"                 # tên NIC dải WAN 107.118.210.x (kiểm tra: ip -br link)
LAN_IF="ens4"                 # tên NIC dải LAN 10.1.1.x
WAN_GW="107.118.210.1"
DNS="107.118.210.1 1.1.1.1"
SSH_PUBKEY_FILE="${SSH_PUBKEY_FILE:-$HOME/.ssh/id_ed25519.pub}"
OUT_DIR="./out"

# Mật khẩu admin (hash). Tạo: openssl passwd -6  hoặc  mkpasswd -m sha-512
# (để rỗng -> script sẽ hỏi và tự hash)
PWHASH="${PWHASH:-}"

# ----- BẢNG HOST: hostname  wan_ip  lan_ip  data_disk  backup_disk ----------
# lan_ip = "-"  nghĩa là chỉ 1 NIC (vd DevDB).  data/backup = yes|no
read -r -d '' HOST_TABLE <<'EOF' || true
ax-proxy01   107.118.210.98   10.1.1.98    no   no
ax-proxy02   107.118.210.99   10.1.1.99    no   no
nas      107.118.210.97   10.1.1.97    yes  no
ax-db01   107.118.210.103  10.1.1.103   yes  no
ax-db02   107.118.210.104  10.1.1.104   yes  no
ax-db03   107.118.210.105  10.1.1.105   yes  yes
mon      107.118.210.96   10.1.1.96    yes  no
devdb    107.118.210.90   -            yes  no
EOF

# Khối /etc/hosts chung cho mọi node
read -r -d '' HOSTS_BLOCK <<'EOF' || true
107.118.210.98   ax-proxy01
107.118.210.99   ax-proxy02
10.1.1.97      nas
10.1.1.101     ax-web01
10.1.1.102     ax-web02
10.1.1.103     ax-db01
10.1.1.104     ax-db02
10.1.1.105     ax-db03
10.1.1.96      mon
EOF

# ----- Kiểm tra phụ thuộc ----------------------------------------------------
command -v cloud-localds >/dev/null || { echo "Thiếu cloud-localds: sudo apt install cloud-image-utils"; exit 1; }
[ -f "$SSH_PUBKEY_FILE" ] || { echo "Không thấy SSH pubkey: $SSH_PUBKEY_FILE"; exit 1; }
SSH_PUBKEY="$(cat "$SSH_PUBKEY_FILE")"

if [ -z "$PWHASH" ]; then
  echo "Nhập mật khẩu admin để hash (sha-512):"
  PWHASH="$(openssl passwd -6)"
fi

mkdir -p "$OUT_DIR"
DNS_YAML="$(printf '%s' "$DNS" | sed 's/ /, /g')"

# ----- Sinh từng host --------------------------------------------------------
while read -r HOST WAN_IP LAN_IP DATA_DISK BACKUP_DISK; do
  [ -z "${HOST:-}" ] && continue
  case "$HOST" in \#*) continue;; esac
  echo ">> $HOST  (WAN=$WAN_IP LAN=$LAN_IP data=$DATA_DISK backup=$BACKUP_DISK)"
  HDIR="$OUT_DIR/$HOST"; mkdir -p "$HDIR"

  # --- network: WAN luôn có; LAN chỉ khi lan_ip != "-" ---
  NET_LAN=""
  if [ "$LAN_IP" != "-" ]; then
    NET_LAN=$(cat <<EOF
      ${LAN_IF}:
        addresses: [${LAN_IP}/24]
EOF
)
  fi

  # --- late-commands cho đĩa /data và /backup (dùng LABEL, không phụ thuộc tên đĩa) ---
  DATA_CMD=""
  if [ "$DATA_DISK" = "yes" ]; then
    DATA_CMD=$(cat <<'EOF'
    - |
      if [ -b /dev/sdb ]; then
        mkfs.ext4 -F -L axdata /dev/sdb
        mkdir -p /target/data
        echo "LABEL=axdata /data ext4 defaults,noatime 0 2" >> /target/etc/fstab
      fi
EOF
)
  fi
  BACKUP_CMD=""
  if [ "$BACKUP_DISK" = "yes" ]; then
    BACKUP_CMD=$(cat <<'EOF'
    - |
      if [ -b /dev/sdc ]; then
        mkfs.ext4 -F -L axbackup /dev/sdc
        mkdir -p /target/backup
        echo "LABEL=axbackup /backup ext4 defaults,noatime 0 2" >> /target/etc/fstab
      fi
EOF
)
  fi

  # --- user-data ---  (heredoc KHÔNG quote để ${VAR} expand; $ trong PWHASH an toàn vì là giá trị biến)
  cat > "$HDIR/user-data" <<EOF
#cloud-config
autoinstall:
  version: 1
  locale: en_US.UTF-8
  keyboard: {layout: us}
  ssh:
    install-server: true
    allow-pw: false
    authorized-keys:
      - ${SSH_PUBKEY}
  identity:
    hostname: ${HOST}
    username: ${ADMIN_USER}
    password: "${PWHASH}"
  network:
    version: 2
    ethernets:
      ${WAN_IF}:
        addresses: [${WAN_IP}/24]
        routes:
          - to: default
            via: ${WAN_GW}
        nameservers:
          addresses: [${DNS_YAML}]
${NET_LAN}
  storage:
    layout:
      name: lvm
      match:
        path: /dev/sda
  packages:
    - qemu-guest-agent
    - chrony
    - ufw
    - curl
    - vim
  user-data:
    disable_root: true
  late-commands:
    - |
      cat >> /target/etc/hosts <<'HOSTS'
${HOSTS_BLOCK}
HOSTS
${DATA_CMD}
${BACKUP_CMD}
    - curtin in-target --target=/target -- systemctl enable qemu-guest-agent chrony
    - curtin in-target --target=/target -- timedatectl set-ntp true
EOF

  # --- meta-data ---
  cat > "$HDIR/meta-data" <<EOF
instance-id: ax-${HOST}
local-hostname: ${HOST}
EOF

  # --- seed ISO ---
  cloud-localds "$OUT_DIR/${HOST}-seed.iso" "$HDIR/user-data" "$HDIR/meta-data"
  echo "   -> $OUT_DIR/${HOST}-seed.iso"
done <<< "$HOST_TABLE"

echo
echo "XONG. Mỗi host có 1 seed ISO trong $OUT_DIR/"
echo "Gắn KÈM ISO cài Ubuntu 24.04 + seed ISO tương ứng, boot là tự cài."
