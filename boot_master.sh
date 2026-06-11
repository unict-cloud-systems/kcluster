#!/usr/bin/env bash

. ./_scripts/transcript.sh ; transcript_boot_init "$0" || exit 1

. ./set_vars.sh
transcript_boot_ready "$?" || exit 1

# MTAG_PAD: blanks the width of the "[Master $THISNODE]" tag, to align continuation lines
MTAG_PAD="[Master $THISNODE]"
MTAG_PAD="${MTAG_PAD//?/ }"

KADMOPTS="--node-name $THISNODE"
KADMOPTS="$KADMOPTS --apiserver-advertise-address=$THISIP"
KADMOPTS="$KADMOPTS --pod-network-cidr=$POD_NETWORK_CIDR"
KADMOPTS="$KADMOPTS --service-cidr=$SERVICE_CIDR"

GENERATED_DIR=_generated
CALICO_MANIFEST="$GENERATED_DIR/calico-${POD_NETWORK_CIDR/\//_}.yaml"
FLANNEL_MANIFEST="$GENERATED_DIR/flannel-${POD_NETWORK_CIDR/\//_}.yml"

transcript_start

# Initialize Kubernetes
echo -e "\n${RED}[Master $THISNODE] Initialize Kubernetes Cluster and kubelet$NC"

#@ Ensure container runtime and kubelet are enabled/running
systemctl is-active $CONTAINER_RUNTIME --quiet || \
   systemctl restart $CONTAINER_RUNTIME #@ if not already active
systemctl is-enabled $CONTAINER_RUNTIME --quiet || \
   systemctl enable $CONTAINER_RUNTIME #@ if not already enabled
systemctl is-enabled kubelet --quiet || \
   systemctl enable kubelet #@ if not already enabled

#kubeadm config images pull
# kubeadm init will pull images anyway, might complain about etcd version

#@ Remove stale kubeadm failure marker
rm -f /tmp/kadmfail #@
echo executing kubeadm init $KADMOPTS

#@ Initialize the Kubernetes control plane
#@ kubeadm init $KADMOPTS
(kubeadm init $KADMOPTS 2>&1 || touch /tmp/kadmfail) | tee -a /root/kubeinit.log
# kubeadm inizializza il control-plane e (importante!) genera la configurazione
# (in /etc/kubernetes/kubelet.conf) per il daemon kubelet che poi avvia
if [ -f /tmp/kadmfail ] ; then
   echo -e "\n${BOLDRED}Failed to start kubeadm (a required port in use? some kubelet running?)${NC}"
   for port in 6443 2379 2380 10250 10259 10257; do
      lsof -i :${port} | tail -1 || true
   done
   echo -e "${BOLDRED}check /root/kubeinit.log ... exiting${NC}"
   exit 2
fi

echo -e "\n${RED}[Master $THISNODE] Will now carry out the above instructions for you$NC"

# Copy Kube admin config
echo -e "\n${RED}[Master $THISNODE] Copy kube admin config to common user's .kube directory$NC"
#@ Install kubeconfig for root and the common user
mkdir -p /home/$KUSER/.kube #@
mkdir -p /root/.kube #@
cp /etc/kubernetes/admin.conf /home/$KUSER/.kube/config #@
cp /etc/kubernetes/admin.conf /root/.kube/config #@
chown -R $KUSER:$KUSER /home/$KUSER/.kube #@

# Generate Cluster join command
echo -e "\n${RED}[Master $THISNODE] Generate and save cluster join command to /joincluster.sh$NC"
#@ Generate kubeadm join command for worker nodes
kubeadm token create --print-join-command > /joincluster.sh #@
echo cat /joincluster.sh
cat /joincluster.sh

# NB: il token ha una scadenza e va rigenerato se il master diventa "vecchio"
#@ Publish join command where worker nodes can fetch it
cp /joincluster.sh /tmp #@
chmod a+r /tmp/joincluster.sh #@

# Deploy (SDN) network (can also be done after nodes have joined, until then nodes will be NotReady)
echo -e "\n${RED}[Master $THISNODE] Deploy Calico network (can be done after worker nodes have joined,"
echo -e "$MTAG_PAD but, before the network has been deployed, worker nodes will be NotReady)$NC"

# _templates/calico.yaml committed in the repo is a snapshot that will go stale (see !!TODO.txt).
# To refresh manually, then run upload_kcluster_setup.sh -y to redistribute to nodes:
#   wget -O _templates/calico.yaml https://docs.projectcalico.org/manifests/calico.yaml        # latest
#   wget -O _templates/calico.yaml https://docs.projectcalico.org/v3.23/manifests/calico.yaml  # last known working
# old approach -- apply directly from network, abandoned because it does not allow
# patching CALICO_IPV4POOL_CIDR with the custom POD_NETWORK_CIDR from config.sh:
#   su - $KUSER -c "kubectl apply -f https://docs.projectcalico.org/v3.9/manifests/calico.yaml"

#@ Render CNI manifests from templates
mkdir -p "$GENERATED_DIR" #@
./_scripts/render_template.sh --calico --output "$CALICO_MANIFEST" #@
./_scripts/render_template.sh --flannel --output "$FLANNEL_MANIFEST" #@

# files are created by root; give ownership to $KUSER for manageability
chown $KUSER:$KUSER "$CALICO_MANIFEST" "$FLANNEL_MANIFEST" #@

#su - $KUSER -c "kubectl apply -f $SETUPDIR/$CALICO_MANIFEST"
# may run as root, because now kubectl has config file for root
#@ Deploy Calico as CNI
if ! kubectl apply -f "$SETUPDIR/$CALICO_MANIFEST"; then #@
   echo -e "${BOLDRED}Failed to deploy Calico network, exiting${NC}" >&2
   exit 1
fi

#su - $KUSER -c "kubectl apply -f $SETUPDIR/_templates/calico.yaml"
#su - $KUSER -c "kubectl apply -f $SETUPDIR/$FLANNEL_MANIFEST"

#@ Master is ready. Verify node registration:
#@ kubectl get nodes
#@ Worker nodes can now run ./boot_worker.sh

echo -e "${RED}[Master $THISNODE] k8s cluster up, Rete dei nodi $KHOSTS_NETWORK$NC"
echo -e "${RED}[Master $THISNODE] Rete dei POD:$NC ${POD_NETWORK_CIDR}," "${RED}Rete dei servizi:$NC ${SERVICE_CIDR}\n"
echo -e "${RED}[Master $THISNODE] Come superuser esegui sui worker nodes: ${NC}cd $(pwd)$RED, poi $NC./boot_worker.sh$NC\n"
echo -e "${RED}[Master $THISNODE] infine opera come user \"$KUSER\" (${BOLDRED}NON da super-user$NC$RED) su questo host - "
echo -e "$MTAG_PAD prova:$NC kubectl get nodes\n"
