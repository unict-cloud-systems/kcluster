#!/usr/bin/env bash

[[ -f ./set_vars.sh ]] || { echo "set_vars.sh not found -- run upload_kcluster_setup.sh -y from the client first" >&2; exit 1; }
. ./set_vars.sh

# set -e + pipefail: any failure exits via the trap below (line number shown).
# Add explicit '|| { echo ...; exit 1; }' only for critical failures that need context.
# Use '|| true' for non-critical steps that must not abort the script.
set -e -o pipefail
trap 'echo -e "${BOLDRED}install_kube.sh: error on line $LINENO, exiting${NC}" >&2' ERR

#KEYDIR=/usr/share/keyrings
KEYDIR=/etc/apt/keyrings
mkdir -p $KEYDIR
chmod 755 $KEYDIR

echo -e "${RED}[TASK 1] Reset apt and install utilities $NC"

export DEBIAN_FRONTEND=noninteractive
#apt-get clean
rm -f /var/lib/man-db/auto-update
apt-get update || \
  { echo -e "${BOLDRED}apt-get update failed, exiting${NC}" >&2; exit 1; }
apt-get install --reinstall -y ca-certificates
# abbiamo aggiornati i certificati della CA, importante per successive installazioni
apt-get install -y apt-transport-https software-properties-common net-tools curl gnupg lsb-release rdate rsync procps lsof psmisc

echo -e "${RED}[TASK 1.1] Fix clocks $NC"

# clocks must be correct
install -m 0755 _templates/rdate-hwclock.sh /etc/cron.daily/rdate-hwclock.sh
/etc/cron.daily/rdate-hwclock.sh || true   # non-fatal: time server may be unreachable

echo -e "${RED}[TASK 2] Initialize keys in $IT$KEYDIR/$NOIT and sources lists in $IT/etc/apt/sources.list.d/ $NC"

# Add keys for docker and docker sources list (needed for containerd.io)

curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o $KEYDIR/docker.asc
chmod a+r $KEYDIR/docker.asc

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=$KEYDIR/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  tee /etc/apt/sources.list.d/docker.list > /dev/null

# Add keys for CRI-O and its sources list
# This will work without errors because we already updated ca-certificates

curl -fsSL https://pkgs.k8s.io/addons:/cri-o:/prerelease:/main/deb/Release.key |
    gpg --dearmor --batch --yes -o $KEYDIR/cri-o-apt-keyring.gpg
echo "deb [signed-by=$KEYDIR/cri-o-apt-keyring.gpg] https://pkgs.k8s.io/addons:/cri-o:/prerelease:/main/deb/ /" |
    tee /etc/apt/sources.list.d/cri-o.list

# qui sopra nella URL e` importante "prerelease:" (credo per usare il nuovo repo su pkgs.k8s)
# al posto di "main" si puo` mettere "v1.28" o "v1.29"

# Add keys for k8s and k8s sources list

VERSION_K8S=1.33

curl -fsSL https://pkgs.k8s.io/core:/stable:/v${VERSION_K8S}/deb/Release.key |
    gpg --dearmor --batch --yes -o ${KEYDIR}/kubernetes-apt-keyring.gpg
echo "deb [signed-by=${KEYDIR}/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${VERSION_K8S}/deb/ /" |
    tee /etc/apt/sources.list.d/kubernetes.list

# Update only new source lists
# subshell so the cd does not affect the rest of the script
(cd /etc/apt/sources.list.d && for f in *.list; do
    apt-get update -o Dir::Etc::sourcelist="sources.list.d/$f" \
      -o Dir::Etc::sourceparts="-" -o APT::Get::List-Cleanup="0"
done)

echo -e "${RED}[TASK 3] Installing containerd$NC"
apt-get install -y containerd.io || \
  { echo -e "${BOLDRED}Could not install containerd, exiting${NC}" >&2; exit 1; }

# $POD_NETWORK_CIDR inherited from set_vars.sh
# keep _templates/containerd-net.conflist pristine; generate a named copy for fallback CNI config
sed "s+10.10.0.0/16+$POD_NETWORK_CIDR+" _templates/containerd-net.conflist \
  > containerd-net-${POD_NETWORK_CIDR/\//_}.conflist

# Il .deb containerd.io installato qui sopra contiene runc, ma non i plugin CNI
# che sono in kubernetes-cni.deb (richiesto dagli altri pacchetti k8s)

# il pacchetto .deb containerd.io ha un problema nel suo /etc/containerd/config.toml
# perche' disattiva il plugin cri (CRI e` l'interfaccia standard tra k8s e il container runtime)
#sed -i 's/^disabled_plugins *= *\["cri"\]/#disabled_plugins = \["cri"\]/' /etc/containerd/config.toml
# pero` disattivo la riga sopra perche' /etc/containerd/config.toml pare comunque insufficiente

# quindi la correzione sotto, per il config.toml nel .deb, è insufficiente
#
#if ! grep -q "SystemdCgroup = true" /etc/containerd/config.toml; then
#cat >>/etc/containerd/config.toml<<EOF
#[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
#[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
#SystemdCgroup = true
# above because for cgroup kubeadm defaults to systemd which is recommended
#EOF
#fi

# Alla fine, quindi, genero /etc/containerd/config.toml di default e lo correggo:
containerd config default > /etc/containerd/config.toml
sed -e 's/SystemdCgroup = false/SystemdCgroup = true/' -i /etc/containerd/config.toml
# DA VERIFICARE NEL TEMPO SE SUFFICIENTE
#sed -e 's/systemd_cgroup = false/systemd_cgroup = true/' -i /etc/containerd/config.toml
#La riga sopra parrebbe ragionevole, ma in effetti causa problemi!

echo -e "${RED}[TASK 4] Install CRI-O container runtime$NC"

apt-get install -y cri-o || \
  { echo -e "${BOLDRED}Could not install cri-o, exiting${NC}" >&2; exit 1; }

echo -e "${RED}[TASK 5] Installing crictl, the container runtime monitor $NC"

gen_crictl_conf() {
   ./_scripts/render_template.sh --file _templates/crictl.runtime.yaml \
      --var RUNTIME="$1" --output "/etc/crictl.$1.yaml"
}

# $CONTAINER_RUNTIME and $CRI_RUNTIMES inherited from set_vars.sh
for cri in $CRI_RUNTIMES ; do
  gen_crictl_conf $cri
done

cp /etc/crictl.$CONTAINER_RUNTIME.yaml /etc/crictl.yaml

echo -e "${RED}[TASK 6] Add sysctl settings$NC"
if ! grep -q net.bridge.bridge-nf-call-ip6tables /etc/sysctl.d/kubernetes.conf; then
cat >>/etc/sysctl.d/kubernetes.conf<<EOF
net.bridge.bridge-nf-call-ip6tables = 1
EOF
fi

if ! grep -q net.bridge.bridge-nf-call-iptables /etc/sysctl.d/kubernetes.conf; then
cat >>/etc/sysctl.d/kubernetes.conf<<EOF
net.bridge.bridge-nf-call-iptables = 1
EOF
fi

if ! grep -q net.ipv4.ip_forward /etc/sysctl.d/kubernetes.conf; then
cat >>/etc/sysctl.d/kubernetes.conf<<EOF
net.ipv4.ip_forward = 1
EOF
fi

# ma i sysctl precedenti sono attivi solo se c'è il modulo br_netfilter
modprobe overlay
modprobe br_netfilter
# i modprobe servono all'installazione, poi, a ogni boot vale br_nf_kube.conf
if ! grep -q overlay /etc/modules-load.d/br_nf_kube.conf; then
cat >>/etc/modules-load.d/br_nf_kube.conf<<EOF
overlay
br_netfilter
EOF
fi

sysctl --system
# precedente serve all'installazione, non al boot

# Install Kubernetes
echo -e "${RED}[TASK 7] Install Kubernetes kubeadm, kubelet and kubectl$NC"
apt-get install -y kubelet kubeadm kubectl || \
  { echo -e "${BOLDRED}Could not install k8s, exiting${NC}" >&2; exit 1; }
# dovrebbe installare anche kubernetes-cni (per le reti virtuali)
# e questo a sua volta cri-tools (con crictl)

#apt-mark hold kubelet kubeadm kubectl kubernetes-cni
# above excludes k8s from upgrades, because special attention is needed
# https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-upgrade/
kubeadm completion bash > /etc/bash_completion.d/kubeadm || echo -e "${RED}Warning: kubeadm completion failed${NC}" >&2
kubectl completion bash > /etc/bash_completion.d/kubectl || echo -e "${RED}Warning: kubectl completion failed${NC}" >&2
crictl completion bash > /etc/bash_completion.d/crictl   || echo -e "${RED}Warning: crictl completion failed${NC}" >&2

echo -e "${RED}[TASK 8] Install more utilities${NC}"
#apt-get install -y sshpass
# ho eliminato sshpass da boot_worker.sh
# Install a k8s user (now unnecessary)
#echo -e "${RED}[TASK] Install user $JUSER$NC"
#useradd -m $JUSER && (echo -e "kubeadmin\nkubeadmin" | passwd $JUSER) || echo "(this failure is ok)"

touch /var/lib/man-db/auto-update || true

echo -e "${RED}[TASK 9] Set up .inputrc for root and $KUSER${NC}"
_inputrc_file=_templates/cloud_init.inputrc
if [[ ! -r "$_inputrc_file" ]]; then
   echo -e "${BOLDRED}Warning: $_inputrc_file missing -- .inputrc not set${NC}" >&2
else
   for _home in /root /home/$KUSER; do
      [[ -d "$_home" ]] && cp "$_inputrc_file" "$_home/.inputrc"
   done
fi
unset _inputrc_file _home

echo -e "${RED}Preparing to boot a cluster: reset_kube.sh${NC}"
./reset_kube.sh
