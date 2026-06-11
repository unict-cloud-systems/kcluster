#!/usr/bin/env bash

[[ -f ./set_vars.sh ]] || { echo "set_vars.sh not found -- run upload_kcluster_setup.sh -y from the client first" >&2; exit 1; }
. ./set_vars.sh

# set -e + pipefail: any failure exits via the trap below (line number shown).
# Add explicit '|| { echo ...; exit 1; }' only for critical failures that need context.
# Use '|| true' for non-critical steps that must not abort the script.
set -e -o pipefail
trap 'echo -e "${BOLDRED}reset_kube.sh: error on line $LINENO, exiting${NC}" >&2' ERR

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------

gen_crictl_conf() {
   ./_scripts/render_template.sh --file _templates/crictl.runtime.yaml \
      --var RUNTIME="$1" --output "/etc/crictl.$1.yaml"
}

setup_kube_tmux_marker_path() {
   local tty_path tty_id

   tty_path=$(tty 2>/dev/null || true)
   [[ -n "$tty_path" && "$tty_path" != "not a tty" ]] || return 1

   tty_id=$(printf '%s' "$tty_path" | tr -c 'A-Za-z0-9_.-' '_')
   printf '/tmp/setup-kube-tmux-hint.%s\n' "$tty_id"
}

running_under_tmux_or_sshx() {
   local pid comm marker

   [[ -n "${TMUX:-}" || -n "${SETUP_KUBE_SHOW_TMUX_HINT:-}" ]] && return 0
   case "${TERM:-}" in
      *tmux*|screen*) return 0 ;;
   esac

   marker=$(setup_kube_tmux_marker_path || true)
   [[ -n "$marker" && -f "$marker" ]] && return 0

   pid=$PPID
   while [[ -n "$pid" && "$pid" -gt 1 ]]; do
      comm=$(ps -o comm= -p "$pid" 2>/dev/null || true)
      [[ "${comm##*/}" == tmux* ]] && return 0
      pid=$(ps -o ppid= -p "$pid" 2>/dev/null | awk '{print $1}')
   done

   return 1
}

show_setup_motd_if_tmux() {
   running_under_tmux_or_sshx || return 1
   [[ -x /etc/update-motd.d/99-setup-kube ]] || return 1

   SETUP_KUBE_HOME="/home/$KUSER" SETUP_KUBE_DIR="$BASESETUPDIR" \
      SETUP_KUBE_SKIP_ENTER_HINT=1 \
      SETUP_KUBE_UNDER_TMUX_TITLE=1 \
      SETUP_KUBE_SHOW_TMUX_HINT=1 /etc/update-motd.d/99-setup-kube
}

msgerr1() {
   local URL1="https://kubernetes.io/docs/tasks/administer-cluster/migrating-from-dockershim/troubleshooting-cni-plugin-related-errors"
   local URL2="https://kubernetes.io/docs/tasks/administer-cluster/migrating-from-dockershim/troubleshooting-cni-plugin-related-errors/#failed-to-destroy-network-for-sandbox-error"
   echo -e "
${RED}[$THISNODE] Per l'errore: ${BOLDRED}Failed to remove containers: failed to stop running pod...
  StopPodSandbox from runtime service failed... rpc error: code = Unknown desc...
  failed to destroy network for sandbox... cni plugin not initialized${NC}
${RED}v.   ${NC}${IT}${URL1}${NC}
${RED}v.   ${NC}${IT}${URL2}${NC}
${RED}in breve, puoi provare:${NC}
     ${IT}cp -i containerd-net-${POD_NETWORK_CIDR/\//_}.conflist /etc/cni/net.d/10-containerd-net.conflist${NC}
${RED}(il rimedio sopra vale solo per containerd; per cri-o non esiste un file equivalente in questo progetto)${NC}
${RED}oppure:${NC}
     ${IT}rm -rf /var/{lib,run}/$CONTAINER_RUNTIME${NC}
${RED}poi (?):${NC}
     ${IT}systemctl restart containerd${NC}
${RED}infine rilancia questo script:${NC}
     ${IT}$0${NC}"
}

msgerr2() {
   echo -e "
${RED}[$THISNODE] Errore rilevato: ${BOLDRED}failed to stop running pod...
  StopPodSandbox from runtime service failed... rpc error: code = NotFound desc...
  an error occurred when try to find sandbox... stopping the pod sandbox${NC}
${RED}Accade perché ${NC}${IT}kubeadm reset${NC}${RED} chiede a ${CONTAINER_RUNTIME}, e specificatamente
al sandbox pod, l'elenco dei pod attraverso ${NC}${IT}crictl${NC}${RED}, ma questi sono già fermi.
Se ${NC}${IT}/etc/crictl.yaml${NC}${RED} pone ${NC}${IT}Debug: false${NC}${RED} non succede niente, ma se il debug è
attivato per ${NC}${IT}crictl${NC}${RED}, questo restituisce un errore (che logicamente non è tale)
e si propaga, come abbiamo visto qui, a ${NC}${IT}kubeadm reset${NC}${RED}.${NC}"
}

msgerr3() {
   echo -e "
${RED}[$THISNODE] Warning rilevato: ${BOLDRED}... No kubeadm config, using etcd pod spec to get data directory...${NC}
${RED}Su un ex-master accade perché k8s è già spento.${NC}"
}

msgerr4() {
   echo -e "
${RED}[$THISNODE] Errore rilevato: ${BOLDRED}... Failed to remove containers... Error while dialing dial unix...${NC}
${RED}Accade perché l'engine ${CONTAINER_RUNTIME} è già spento.${NC}"
}

msgerr5() {
   echo -e "
${RED}[$THISNODE] Errore rilevato: ${BOLDRED}Failed to remove containers: failed to stop running pod...
  StopPodSandbox from runtime service failed... rpc error: code = Deadline exceeded...
  stopping the pod sandbox... context deadline exceeded${NC}
${RED}Non dovrebbe ripresentarsi a un'ulteriore esecuzione di ${NC}${IT}$0${NC}${RED}.${NC}"
}

# ---------------------------------------------------------------------------

echo -e "\n${RED}[TASK 1 @$THISNODE] Reset container runtimes (we do not expect docker)\n$NC"
#systemctl stop docker
#systemctl stop docker.socket
# Docker now (should be) unnecessary, maybe harmful
# see https://www.jetstack.io/blog/cri-migration/

# we stop any "other" container runtime, in case it is on (e.g. if we just changed
# it); the current one should not be stopped until we deal with k8s stuff

for cri in $CRI_RUNTIMES ; do
if [[ $cri != "$CONTAINER_RUNTIME" ]] && systemctl is-active $cri --quiet ; then
   echo -e "${RED}stopping $cri (may fail if $cri not installed) ${NC}"
   systemctl stop $cri
fi
done

# make sure /etc/crictl*.yaml exist

for cri in $CRI_RUNTIMES ; do
if [[ ! -f /etc/crictl.$cri.yaml ]] ; then
   gen_crictl_conf $cri
fi
done

# reset /etc/cricctl.yaml if necessary

if [[ ! -f /etc/crictl.yaml ]] || \
   ! { head -1 /etc/crictl.yaml | grep -q  "^# /etc/crictl.$CONTAINER_RUNTIME.yaml"; } ; then
   CPCMD="cp /etc/crictl.$CONTAINER_RUNTIME.yaml /etc/crictl.yaml"
   echo $CPCMD
   $CPCMD
fi

# Add sysctl settings
echo -e "\n${RED}[TASK 2 @$THISNODE] Check sysctl settings$NC"

sysctl net.bridge.bridge-nf-call-ip6tables || true
sysctl net.bridge.bridge-nf-call-iptables  || true
sysctl net.ipv4.ip_forward                 || true
echo "if three previous lines do not end in '... = 1', check sysctl setting in install_kube.sh"

# Disable swap
echo -e "\n${RED}[TASK 3 @$THISNODE] Turn off SWAP$NC"
#sed -i '/swap/d' /etc/fstab
swapoff -a

# Reset kubernetes software

echo -e "\n${RED}[TASK 4 @$THISNODE] Reset k8s, remove k8s config files, stop k8s programs$NC"

## v. https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/#tear-down
## Per un tear-down ordinato, servirebbero, sul master, per ogni worker node:
#kubectl drain <node name> --delete-emptydir-data --force --ignore-daemonsets
#kubectl delete <node name>
## poi, su <node>, "kubeadm reset"
## e, alla fine, "kubeadm reset" sul master
## ma, per i nostri scopi di apprendimento, basta (forse?) un reset "hard", come segue

# "kubeadm reset" su un worker puo` causare alcuni errori legati al pod Sandbox (che
# dovrebbe risiedere su ogni nodo con kubelet, lo si puo` vedere con "sudo crictl pods")
# qui si cerca di "gestire" o spiegare questi errori... msgerr1 e` raro, in effetti

echo -e "\n${RED}[TASK 4 @$THISNODE] Calling 'kubeadm reset' ... ${NC}"
echo -e "      ${RED}At times this appears to hang on:${NC}"
echo -e "${RED}${IT}[reset] Unmounting mounted directories in \"/var/lib/kubelet\"${NC}${NC}"
echo -ne "     ${RED}This is yet unexplained and usually resolves itself after a while "
echo -e "but, if it takes too long, you may try to interrupt and run by hand:${NC}"
echo -e "  ${IT}rm -rf /etc/cni/net.d${NC}"
echo -e "${RED}or${NC}"
echo -e "  ${IT}rm -rf \"/var/lib/kubelet\"${NC}"
echo -e "${RED}before retrying this script ($0)${NC}\n"

# Pre-cleanup: stop the container runtime so its overlayfs mount activity cannot
# hold the kernel mount lock and block kubeadm's read of /proc/mounts.
# (kubeadm reset will just skip container removal if the socket is gone, which
# is fine -- we already cleaned pods/containers above.)
echo -e "${RED}Stopping $CONTAINER_RUNTIME before kubeadm reset to avoid /proc/mounts hang...${NC}"
systemctl stop $CONTAINER_RUNTIME 2>/dev/null || true

# Force-remove all pods and containers so kubeadm reset does not hang trying
# to stop NotReady sandboxes via the container runtime.
if crictl pods -q 2>/dev/null | grep -q .; then
    echo -e "${RED}Pre-removing pods via crictl (if this hangs, interrupt and run by hand:${NC}"
    echo -e "${IT}  crictl stopp \$(crictl pods -q) 2>/dev/null${NC}"
    echo -e "${IT}  crictl rmp --force \$(crictl pods -q) 2>/dev/null${NC}"
    echo -e "${RED}then rerun $0)${NC}"
    # shellcheck disable=SC2046
    crictl rmp --force $(crictl pods -q 2>/dev/null) 2>/dev/null || true
fi
if crictl ps -aq 2>/dev/null | grep -q .; then
    echo -e "${RED}Pre-removing containers via crictl...${NC}"
    # shellcheck disable=SC2046
    crictl rm --force $(crictl ps -aq 2>/dev/null) 2>/dev/null || true
fi

# manual_kube_reset: fallback when kubeadm reset times out.
# Replicates the essential cleanup kubeadm would have done.
manual_kube_reset() {
    echo -e "${RED}kubeadm reset timed out -- running manual cleanup${NC}"
    pkill -9 kubeadm 2>/dev/null || true
    awk '$2 ~ /\/var\/lib\/kubelet/ {print $2}' /proc/mounts | sort -r | xargs -r umount -lf 2>/dev/null || true
    iptables -F && iptables -t nat -F && iptables -t mangle -F && iptables -X 2>/dev/null || true
    ip6tables -F && ip6tables -t nat -F && ip6tables -t mangle -F && ip6tables -X 2>/dev/null || true
    ipvsadm --clear 2>/dev/null || true
    rm -rf /etc/kubernetes/manifests /etc/kubernetes/pki \
           /etc/kubernetes/admin.conf /etc/kubernetes/kubelet.conf \
           /etc/kubernetes/bootstrap-kubelet.conf /etc/kubernetes/controller-manager.conf \
           /etc/kubernetes/scheduler.conf
    rm -rf /var/lib/etcd
}

rm -f /tmp/kubeadm.err
timeout 60 kubeadm reset -f 2>/tmp/kubeadm.err || manual_kube_reset
if [[ -s /tmp/kubeadm.err ]] ; then
echo -e "\n${RED}[/tmp/kubeadm.err]${NC}" 1>&2
ERRLINES=$(wc -l /tmp/kubeadm.err | cut -d' ' -f1)
if [[ $ERRLINES -lt 5 ]] ; then
   cat /tmp/kubeadm.err
else
   head -2 /tmp/kubeadm.err 1>&2
   echo -e "${RED}[...]${NC}" 1>&2
   tail -n +3 /tmp/kubeadm.err | head -n -2 | grep -m1 --color 'code = NotFound' 1>&2 &&
      echo -e "${RED}[...]${NC}" 1>&2
   tail -2 /tmp/kubeadm.err 1>&2
fi
echo -e "${RED}[/tmp/kubeadm.err ended]${NC}" 1>&2
fi

grep -q  "cni plugin not initialized" /tmp/kubeadm.err && msgerr1
grep -q  "code = NotFound"            /tmp/kubeadm.err && msgerr2
grep -qi "No kubeadm config"          /tmp/kubeadm.err && msgerr3
grep -qi "Error while dialing"        /tmp/kubeadm.err && msgerr4
grep -qi "context deadline exceeded"  /tmp/kubeadm.err && msgerr5

## apparently "kubeadm reset" also stops the kubelet daemon, so following should be useless
#systemctl stop kubelet

## presumably, "kubeadm reset" needs some configuration files, to undo cleanly, so following
## "rm -rf" are useless, even harmful before I added "sleep 2", because "kubeadm reset"
## is slow to set in and without "sleep 2" would not find the configuration to remove!
#sleep 2
#echo -e "\n${RED}Removing k8s config files$NC"
#rm -rf /etc/kubernetes/*
#rm /etc/kubernetes/pki/ca.crt
# a volte si ritrova il precedente file...
#mkdir -p /etc/kubernetes/manifests
#rm -rf /var/lib/etcd

# sometimes an older k8s process survives, so...
killall_kub() {
   echo -e "${RED}"
   for kubproc in kubelet kubeadm kubectl kube-proxy kube-controller kube-scheduler kube-apiserver ; do
      killall $kubproc >& /dev/null && echo killed $kubproc
   done
   echo -e "${NC}"
}

pgrep -l kub && killall_kub

# following important, otherwise on nodes with a stale config, kubectl will hang
rm -f /root/.kube/config
rm -f /home/$KUSER/.kube/config

reset_cri_daemon() {
   echo -e "\n${RED}$(basename $0): Stopping $CONTAINER_RUNTIME${NC}"
   systemctl stop $CONTAINER_RUNTIME
   # I due "rm -rf" seguenti risolvono l'errore cni plugin not initialized (v. msgerr1),
   # ma interviene poi l'errore code = NotFound (v. msgerr2)
   #rm -rf /var/lib/containerd/*
   #rm -rf /var/run/containerd/*

   echo -e "${RED}$(basename $0): Removing /etc/cni/net.d${NC}"
   rm -rf /etc/cni/net.d

   # /var/lib/cni/networks e /var/lib/cni/results contengono lo stato delle allocazioni IP
   # dei pod (lease IPAM). Se non vengono rimossi, al riavvio del cluster il CNI plugin
   # può rifiutarsi di assegnare IP già "occupati" secondo i suoi record, causando pod in
   # ContainerCreating o errori "no IP addresses available". D'altra parte, kubeadm reset non li tocca.
   rm -rf /var/lib/cni/networks
   rm -rf /var/lib/cni/results
   # "rm -rf" sopra è necessario per un reset "completo" di CNI, come sembra suggerire "kubeadm reset":
   #    [reset] ... The reset process does not clean CNI configuration... remove /etc/cni/net.d
   # Ma a questo punto si deve rilanciare containerd/crio perche' (forse) il containerd/crio
   # preesistente considera ancora il precedente stato CNI e non potra` quindi supportare
   # il nuovo kubelet che partira`, che, infatti, dira` (da systemctl kubelet status):
   #    kubelet[18911]: E0603 08:45:27.530646   18911 kubelet.go:2344]
   #    "Container runtime network not ready" networkReady="NetworkReady=false reason:
   #    NetworkPluginNotReady message:Network plugin returns error: cni plugin not initialized"
   # Rimedio: containerd/crio va riavviato dopo "rm -rf /etc/cni/net.d", cioè dopo
   # l'invocazione di questa funzione, e prima che "kubeadm init" (script boot_master.sh)
   # e boot_worker.sh (esplicitamente) avviino un nuovo kubelet
   #
   # Inoltre, presumibilmente, questa funzione, che spegne il container engine
   # $CONTAINER_RUNTIME, dovrebbe essere invocata dopo "kubeadm reset", ma e` accaduto
   # che "kubeadm reset" andasse in stallo e riuscisse a terminare solo dopo
   # avere spento il container engine...
   #
}

reset_cri_daemon
# la funzione sopra spegne il container engine, v. commenti nel codice della funzione per
# capire perche' la si invocava prima, ma penso sia meglio dopo avere chiuso il cluster

echo -e "\n${RED}[TASK 5 @$THISNODE] Finalizing$NC"

rm -f /tmp/joincluster.sh /joincluster.sh

# non so perche' si dovrebbe fare il restart qui... lo lascerei ai boot_*.sh
#systemctl restart $CONTAINER_RUNTIME

# kubeadm requires these ports to be free: 6443 API server, 2379-2380 etcd,
# 10250 kubelet, 10259 scheduler, 10257 controller-manager
for port in 6443 2379 2380 10250 10259 10257; do
    busy=$(lsof -i :${port} | tail -1 || true)
    if [[ -n "$busy" ]]; then
        echo -e "\n${BOLDRED}port ${port} busy -- stop microk8s or other k8s before booting${NC}"
        echo "$busy"
        exit 1
    fi
done
pgrep -l kub && echo -e "${RED}WARNING: there are k8s processes${NC}" || echo -e "${RED}OK: no k8s processes${NC}"

echo -e "\n${RED}[TASK 6 @$THISNODE] Update and clean /etc/hosts$NC"
update_etc_hosts || { echo -e "${BOLDRED}update_etc_hosts failed, exiting${NC}" >&2; exit 1; }

echo
show_setup_motd_if_tmux || \
   echo -e "${RED}Ora esegui qui (nodo [$THISNODE]) ./boot_master.sh oppure ./boot_worker.sh (deve esserci prima un master)\n$NC"
