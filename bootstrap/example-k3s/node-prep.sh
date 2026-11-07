#!/usr/bin/env bash
# Prepare a node of the example k3s cluster for k3s + Cilium + Longhorn.
# Run as root on EVERY node, before installing k3s. Safe to run again.
#
#   sudo bash node-prep.sh
#
# Supports Debian/Ubuntu (apt) and RHEL-family/Fedora (dnf).
# Guide: https://aglelectronics.github.io/con-services/deploy/cluster/
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo bash $0" >&2
  exit 1
fi

log() { printf '\n==> %s\n' "$*"; }

log "Installing packages (open-iscsi, NFS client, cryptsetup, tools)"
if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -q
  apt-get install -y -q open-iscsi nfs-common cryptsetup curl jq util-linux
elif command -v dnf >/dev/null 2>&1; then
  dnf install -y -q iscsi-initiator-utils nfs-utils cryptsetup curl jq util-linux
  # RHEL names the initiator file differently on first install.
  [[ -s /etc/iscsi/initiatorname.iscsi ]] || \
    echo "InitiatorName=$(/sbin/iscsi-iname)" > /etc/iscsi/initiatorname.iscsi
else
  echo "Unsupported distribution: install open-iscsi, nfs-common/nfs-utils and cryptsetup by hand." >&2
  exit 1
fi

log "Enabling iscsid"
systemctl enable --now iscsid

log "Loading kernel modules now and at boot"
# iscsi_tcp: Longhorn volumes. dm_crypt: encrypted Longhorn volumes.
# wireguard: Cilium transparent encryption. The netfilter modules are needed
# by Cilium's L7 proxy (Gateway API) TPROXY rules.
modules=(iscsi_tcp dm_crypt wireguard xt_socket xt_TPROXY xt_mark xt_CT nf_tproxy_ipv4)
: > /etc/modules-load.d/conservices.conf
for m in "${modules[@]}"; do
  if modprobe "$m" 2>/dev/null; then
    echo "$m" >> /etc/modules-load.d/conservices.conf
  else
    echo "WARNING: kernel module $m not available (check your kernel)" >&2
  fi
done

log "Keeping multipathd away from Longhorn devices"
# multipathd grabs Longhorn's iSCSI block devices and breaks mounts
# ("already mounted or mount point busy"). Blacklist sd* devices if multipath
# is installed; disable it entirely if you do not use multipath storage.
if systemctl cat multipathd.service >/dev/null 2>&1; then
  mkdir -p /etc/multipath/conf.d
  cat > /etc/multipath/conf.d/longhorn.conf <<'EOF'
blacklist {
    devnode "^sd[a-z0-9]+"
}
EOF
  systemctl restart multipathd || true
  echo "multipathd found: blacklisted sd* devices (/etc/multipath/conf.d/longhorn.conf)."
  echo "If you do not use multipath storage, you may also run: systemctl disable --now multipathd multipathd.socket"
else
  echo "multipathd not installed: nothing to do."
fi

log "Raising inotify limits (Cilium, Longhorn and many pods watch files)"
cat > /etc/sysctl.d/90-conservices.conf <<'EOF'
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches = 524288
EOF
sysctl --system >/dev/null

log "Disabling swap (the kubelet expects no swap)"
swapoff -a
sed -ri 's@^([^#].*\sswap\s.*)$@# \1@' /etc/fstab

log "Done. Check the node with Longhorn's preflight tool:"
cat <<'EOF'

  curl -fsSL -o /usr/local/bin/longhornctl \
    https://github.com/longhorn/cli/releases/download/v1.13.0/longhornctl-linux-amd64
  chmod +x /usr/local/bin/longhornctl
  # Needs a running cluster (KUBECONFIG); run after k3s and Cilium are up:
  longhornctl check preflight --kubeconfig /etc/rancher/k3s/k3s.yaml

EOF
