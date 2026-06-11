#!/bin/sh

set -eu

log() {
   printf '%s\n' "setup-kube-netplan: $*" >&2
}

host=$(hostname -s)
node_ip=""
prefixlen="__KHOSTS_PREFIXLEN__"

case "$host" in
__KHOSTS_CASES__
esac

if [ -z "$node_ip" ]; then
   log "hostname $host not found in configured KHOSTS map, skipping"
   exit 0
fi

default_if=$(ip route show default 2>/dev/null | awk '
   /default/ {
      for (i = 1; i <= NF; i++) {
         if ($i == "dev") {
            print $(i + 1)
            exit
         }
      }
   }')

if [ -z "$default_if" ]; then
   log "no default-route interface found, skipping KHOSTS alias"
   exit 0
fi

default_mac=$(cat "/sys/class/net/$default_if/address")

mkdir -p /etc/netplan/setup-kube.disabled
for f in /etc/netplan/*.yaml /etc/netplan/*.yml; do
   [ -e "$f" ] || continue
   [ "$(basename "$f")" = "99-setup-kube.yaml" ] && continue
   mv "$f" /etc/netplan/setup-kube.disabled/
done

cat >/etc/netplan/99-setup-kube.yaml <<EOF
network:
  version: 2
  ethernets:
    primary:
      match:
        macaddress: "$default_mac"
      dhcp4: true
      addresses:
        - "$node_ip/$prefixlen"
EOF

chmod 600 /etc/netplan/99-setup-kube.yaml

if ! netplan generate; then
   log "netplan validation failed, restoring previous netplan files"
   rm -f /etc/netplan/99-setup-kube.yaml
   for f in /etc/netplan/setup-kube.disabled/*; do
      [ -e "$f" ] || continue
      mv "$f" /etc/netplan/
   done
   exit 1
fi

ip addr replace "$node_ip/$prefixlen" dev "$default_if"
log "$default_if configured with KHOSTS alias $node_ip/$prefixlen; persistent netplan written"
