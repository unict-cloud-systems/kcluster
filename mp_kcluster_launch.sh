#!/usr/bin/env bash
# Launches one Multipass VM per node defined in config.sh,
# using the stable KHOSTS[] IPs from config.sh as aliases inside each VM.
#
# Behaviour:
#   All configured KHOSTS IPs answer ping -> exits successfully without touching them
#   No configured KHOSTS IP answers ping  -> launches VMs, unless stale VMs exist
#   Some KHOSTS IPs answer and some don't -> exits with an explicit error
#
# Run from the client directory (same as config.sh), BEFORE set_env.sh.
# Run as a regular user (NOT root) -- multipass is a user-space command.
# Safe to re-run: if the cluster already exists, nothing is changed.
#
# After this script:  . ./set_env.sh
#
# Override VM sizing via env vars:
#   CPUS=4 MEM=4G DISK=20G IMAGE=24.04 ./mp_kcluster_launch.sh
#

usage() {
   echo "Usage: $0 [-n|--dry-run] [-h]" >&2
   echo "  Env vars: CPUS (def 2)  MEM (def 2G)  DISK (def 10G)  IMAGE (def 22.04)" >&2
}

DRYRUN=0
case "$1" in
   -h|--help) usage; exit 0 ;;
   -n|--dry-run) DRYRUN=1 ;;
   "") ;;
   *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
esac

echo -e "Sourcing di set_vars.sh ... "
. ./set_vars.sh > /dev/null || \
{ echo "Failed to source set_vars.sh -- check for errors in that file" >&2; exit 1; }

set -e -o pipefail
trap 'echo -e "${BOLDRED}mp_kcluster_launch.sh: error on line $LINENO, exiting${NC}" >&2' ERR

if ! command -v multipass >/dev/null 2>&1; then
   echo -e "${BOLDRED}multipass not found -- install from https://multipass.run${NC}" >&2
   exit 1
fi

[[ -z "$KEYFILE" ]] && exit 1  # set_vars.sh already reported the error

if [[ "$KUSER" != "ubuntu" ]]; then
   echo -e "${BOLDRED}Warning: KUSER=$KUSER but Multipass VMs default to user 'ubuntu'.${NC}" >&2
   echo -e "${BOLDRED}Either set KUSER=ubuntu in config.sh or add user creation to _templates/cloud_init.yaml.${NC}" >&2
fi

[[ -f _templates/cloud_init.yaml ]] || { echo -e "${BOLDRED}_templates/cloud_init.yaml non trovato -- file richiesto (dovrebbe essere in git)${NC}" >&2; exit 1; }
[[ -x _scripts/render_template.sh ]] || { echo -e "${BOLDRED}_scripts/render_template.sh non trovato o non eseguibile${NC}" >&2; exit 1; }

CPUS=${CPUS:-2}
MEM=${MEM:-2G}
DISK=${DISK:-10G}
IMAGE=${IMAGE:-22.04}
GENERATED_DIR=_generated
GENERATED_CLOUD_INIT="$GENERATED_DIR/cloud_init.yaml"

first_node=$(echo "$NODES" | cut -d' ' -f1)

# Running Multipass VMs: name -> IP (populated by read_mp_vms)
declare -A mp_vms
mp_nodes=""   # sorted (sort -V) space-separated VM names; use instead of "${!mp_vms[@]}"

read_mp_vms() {
   mp_vms=()
   local name ip
   while read -r name ip; do
      [[ " $NODES " == *" $name "* ]] || continue
      mp_vms[$name]=$ip
   done < <(multipass list 2>/dev/null | awk 'NR>1 && $2=="Running" {print $1, $3}')
   mp_nodes=$(printf '%s\n' "${!mp_vms[@]}" | sort -V | tr '\n' ' ')
   local _kcolors=(34 35 36 33) _i=0 _n
   for _n in $mp_nodes; do
      KRED[$_n]="\033[0;${_kcolors[$((_i % ${#_kcolors[@]}))]}m"
      _i=$((_i + 1))
   done
   unset _kcolors _i _n
}

mp_existing_names() {
   local out

   if ! out=$(multipass list 2>/dev/null); then
      return 1
   fi
   awk 'NR>1 {print $1}' <<< "$out"
}

mp_configured_existing_nodes() {
   local n found="" existing_names
   existing_names=$(mp_existing_names)

   for n in $NODES; do
      if grep -Fxq "$n" <<< "$existing_names"; then
         found="$found $n"
      fi
   done

   echo "$found" | xargs
}

configured_node_count() {
   wc -w <<< "$NODES" | xargs
}

print_next_step() {
   echo -e "${RED}${BOLD}Per definire ambiente locale e completare setup (non K8s) host remoto:${NC} ${IT}. ./set_env.sh${NC}"
}

ping_one_khost() {
   local ip=$1 timeout=${2:-2}

   if command -v perl >/dev/null 2>&1; then
      perl -e '
         my $timeout = shift @ARGV;
         my @cmd = @ARGV;
         my $pid = fork();
         die "fork failed\n" unless defined $pid;
         if ($pid == 0) {
            exec @cmd;
            exit 127;
         }
         local $SIG{ALRM} = sub {
            kill "TERM", $pid;
            select undef, undef, undef, 0.2;
            kill "KILL", $pid;
            exit 124;
         };
         alarm $timeout;
         waitpid $pid, 0;
         alarm 0;
         exit(($? == 0) ? 0 : 1);
      ' "$timeout" ping -c 1 "$ip" >/dev/null 2>&1
      return $?
   fi

   ping -c 1 -W "$timeout" "$ip" >/dev/null 2>&1
}

read_khosts_ping_state() {
   local n ip timeout=${KHOSTS_PING_TIMEOUT:-2}

   KHOSTS_PING_OK=0
   KHOSTS_PING_FAILED=0
   KHOSTS_PING_OK_NODES=""
   KHOSTS_PING_FAILED_NODES=""

   echo -e "${RED}Verifico reachability degli IP KHOSTS da config.sh...${NC}"
   for n in $NODES; do
      ip=${KHOSTS[$n]}
      if ping_one_khost "$ip" "$timeout"; then
         KHOSTS_PING_OK=$((KHOSTS_PING_OK + 1))
         KHOSTS_PING_OK_NODES="$KHOSTS_PING_OK_NODES $n"
         echo -e "${KRED[$n]:-$RED}$n: ${ip} risponde${NC}"
      else
         KHOSTS_PING_FAILED=$((KHOSTS_PING_FAILED + 1))
         KHOSTS_PING_FAILED_NODES="$KHOSTS_PING_FAILED_NODES $n"
         echo -e "${KRED[$n]:-$RED}$n: ${ip} non risponde${NC}"
      fi
   done
   KHOSTS_PING_OK_NODES=$(echo "$KHOSTS_PING_OK_NODES" | xargs)
   KHOSTS_PING_FAILED_NODES=$(echo "$KHOSTS_PING_FAILED_NODES" | xargs)
}

print_reachable_cluster_and_exit() {
   local ok_nodes=$1

   echo -e "\n${RED}Cluster KHOSTS gia' raggiungibile: ${BOLDRED}${ok_nodes}${NC}"
   echo -e "${RED}Nessuna VM creata o modificata.${NC}"
   echo -e "${RED}Per verificare lo stato Multipass, se serve:${NC} ${IT}multipass list${NC}"
   echo -e "${RED}Per ripartire da zero:${NC} ${IT}multipass delete --purge ${ok_nodes}${NC}"
   print_next_step
   exit 0
}

abort_inconsistent_khosts() {
   local ok_nodes=$1 failed_nodes=$2 existing_nodes=${3:-}

   echo -e "\n${BOLDRED}Cluster KHOSTS assente o parziale: non proseguo.${NC}" >&2
   echo -e "${RED}Nodi che rispondono:${NC} ${IT}${ok_nodes:-<nessuno>}${NC}" >&2
   echo -e "${RED}Nodi che non rispondono:${NC} ${IT}${failed_nodes:-<nessuno>}${NC}" >&2
   if [[ -n "$existing_nodes" ]]; then
      echo -e "${RED}Multipass vede gia' VM configurate:${NC} ${IT}${existing_nodes}${NC}" >&2
   fi
   echo -e "${RED}Percorso consigliato:${NC}" >&2
   echo -e "  ${IT}multipass delete --purge ${NODES}${NC}" >&2
   echo -e "  ${IT}./mp_kcluster_launch.sh${NC}" >&2
   exit 1
}

# Injects KEYFILE into pre-existing VMs that were not created by this script.
# New VMs get the key via cloud-init; this covers the pre-existing case only.
# Idempotent: won't duplicate the key in authorized_keys on re-runs.
inject_key_into_vms() {
   local n keyname="${KEYFILE##*/}"
   for n in $mp_nodes; do
      echo -e "${KRED[$n]:-$RED}$n: iniezione chiave SSH${NC}"
      multipass transfer "$KEYFILE" "${KEYFILE}.pub" "$n:/home/$KUSER/.ssh/"
      multipass exec "$n" -- bash -c "
         chmod 600 ~/.ssh/${keyname}
         grep -qF \"\$(cat ~/.ssh/${keyname}.pub)\" ~/.ssh/authorized_keys 2>/dev/null ||
            cat ~/.ssh/${keyname}.pub >> ~/.ssh/authorized_keys
         mkdir -p ~/$BASESETUPDIR
         cp ~/.ssh/${keyname} ~/$BASESETUPDIR/
         chmod 600 ~/$BASESETUPDIR/${keyname}
      "
      echo -e "${KRED[$n]:-$RED}$n: chiave OK${NC}"
      local tmp_motd; tmp_motd=$(mktemp)
      ./_scripts/render_template.sh --motd --output "$tmp_motd"
      multipass transfer "$tmp_motd" "$n:/tmp/99-setup-kube"
      rm -f "$tmp_motd"
      multipass exec "$n" -- sudo bash -c \
         "chmod -x /etc/update-motd.d/* 2>/dev/null || true; mv /tmp/99-setup-kube /etc/update-motd.d/99-setup-kube; chmod 0755 /etc/update-motd.d/99-setup-kube; : > /etc/motd"
      echo -e "${KRED[$n]:-$RED}$n: MOTD dinamico installato${NC}"
   done
}

render_cloud_init_file() {
   local tmp_ci

   mkdir -p "$GENERATED_DIR"
   tmp_ci=$(mktemp)
   ./_scripts/render_template.sh --cloud-init --output "$tmp_ci"
   mv "$tmp_ci" "$GENERATED_CLOUD_INIT"
   echo -e "${RED}Cloud-init generato in ${IT}$GENERATED_CLOUD_INIT${NOIT}${RED} da ${IT}_templates/cloud_init.yaml${NC}"
}

launch_vms() {
   [[ -z "$NODES" ]] && { echo -e "${BOLDRED}Nessun host in config.sh (KHOSTS vuoto)${NC}" >&2; exit 1; }

   local n to_launch="" existing_names
   if ! existing_names=$(mp_existing_names); then
      echo -e "${BOLDRED}multipass list non risponde: impossibile sapere se le VM esistono gia'.${NC}" >&2
      exit 1
   fi
   for n in $NODES; do
      grep -Fxq "$n" <<< "$existing_names" || to_launch="$to_launch $n"
   done

   if [[ -z "$to_launch" ]]; then
      echo -e "${RED}Tutte le VM configurate esistono gia' -- nessun lancio necessario.${NC}"
      return 0
   fi

   to_launch=$(echo "$to_launch" | xargs)
   echo -e "${RED}Lancio VM: ${BOLDRED}${to_launch// /,}${RED} | Ubuntu $IMAGE | ${CPUS} CPU | $MEM RAM | $DISK disco${NC}"

   render_cloud_init_file

   for n in $to_launch; do
      if [[ $DRYRUN -eq 1 ]]; then
         echo -e "${BOLDRED}DRY RUN:${NC} multipass launch $IMAGE --name $n --cpus $CPUS --memory $MEM --disk $DISK --cloud-init $GENERATED_CLOUD_INIT"
      else
         echo -e "${KRED[$n]}Lancio $n...${NC}"
         multipass launch "$IMAGE" --name "$n" \
            --cpus "$CPUS" --memory "$MEM" --disk "$DISK" \
            --cloud-init "$GENERATED_CLOUD_INIT"
         echo -e "${KRED[$n]}$n avviato${NC}"
         wait_cloud_init_node_or_abort "$n"
      fi
   done
}

check_khosts_aliases_or_abort() {
   local n node_ip prefixlen missing=0
   prefixlen="${KHOSTS_NETWORK#*/}"

   echo -e "\n${RED}Verifico alias KHOSTS sulle VM...${NC}"
   for n in $NODES; do
      [[ -n "${mp_vms[$n]}" ]] || continue
      node_ip="${KHOSTS[$n]}"
      if multipass exec "$n" -- sh -c "ip -o -4 addr show | grep -qF '$node_ip/$prefixlen'" </dev/null; then
         echo -e "${KRED[$n]:-$RED}$n: alias ${node_ip}/${prefixlen} OK${NC}"
      else
         echo -e "${BOLDRED}$n: alias ${node_ip}/${prefixlen} mancante${NC}" >&2
         missing=1
      fi
   done

   if [[ $missing -ne 0 ]]; then
      echo -e "\n${BOLDRED}Almeno una VM non ha l'alias KHOSTS configurato.${NC}" >&2
      echo -e "${RED}Probabilmente e' stata creata prima del cloud-init attuale.${NC}" >&2
      echo -e "${RED}Percorso pulito:${NC}" >&2
      echo -e "  ${IT}multipass delete --purge ${NODES}${NC}" >&2
      echo -e "  ${IT}./mp_kcluster_launch.sh${NC}" >&2
      exit 1
   fi
}

print_cloud_init_recovery_hint() {
   local n=$1
   local nodes_to_delete="${mp_nodes:-$n}"

   echo -e "\n${BOLDRED}Cloud-init fallito su una o piu' VM: fermo il setup.${NC}" >&2
   echo -e "${RED}Di solito la strada piu' pulita e':${NC}" >&2
   echo -e "  ${IT}multipass delete --purge ${nodes_to_delete}${NC}" >&2
   echo -e "  ${IT}# correggi _templates/cloud_init.yaml${NC}" >&2
   echo -e "  ${IT}./mp_kcluster_launch.sh${NC}" >&2
   echo -e "\n${RED}Per diagnosi del problema cloud-init su $n:${NC}" >&2
   echo -e "  ${IT}multipass exec $n -- sudo cloud-init status --long${NC}" >&2
   echo -e "  ${IT}multipass exec $n -- sudo tail -200 /var/log/cloud-init-output.log${NC}" >&2
   echo -e "  ${IT}multipass exec $n -- sudo tail -200 /var/log/cloud-init.log${NC}" >&2
}

wait_cloud_init_node_or_abort() {
   local n=$1

   echo -e "${KRED[$n]:-$RED}$n: cloud-init status --wait${NC}"
   if multipass exec "$n" -- cloud-init status --wait </dev/null; then
      echo -e "${KRED[$n]:-$RED}$n: cloud-init OK${NC}"
   else
      echo -e "${BOLDRED}$n: cloud-init FALLITO${NC}" >&2
      multipass exec "$n" -- sudo cloud-init status --long </dev/null 2>/dev/null || true
      print_cloud_init_recovery_hint "$n"
      exit 1
   fi
}

wait_cloud_init_or_abort() {
   local n

   echo -e "\n${RED}Attendo completamento cloud-init sulle VM...${NC}"
   for n in $mp_nodes; do
      wait_cloud_init_node_or_abort "$n"
   done
}

detect_multipass_route_iface() {
   local n ip iface

   for n in $NODES; do
      ip=${mp_vms[$n]}
      [[ -n "$ip" ]] || continue
      iface=$(route_iface_for_ip "$ip")
      if [[ -n "$iface" ]]; then
         echo "$iface"
         return 0
      fi
   done

   return 1
}

route_iface_for_ip() {
   local ip=$1 iface

   if command -v ip >/dev/null 2>&1; then
      iface=$(ip route get "$ip" 2>/dev/null | awk '
         {
            for (i = 1; i <= NF; i++) {
               if ($i == "dev") {
                  print $(i + 1)
                  exit
               }
            }
         }')
      [[ -n "$iface" ]] && { echo "$iface"; return 0; }
   fi

   if [[ "$UNIXNAME" == "Darwin" ]]; then
      iface=$(route -n get "$ip" 2>/dev/null | awk '/interface:/{print $2; exit}')
      [[ -n "$iface" ]] && { echo "$iface"; return 0; }
   fi

   return 1
}

check_host_khosts_alias_conflicts() {
   local mp_iface=$1 network_prefix addr dev found=0

   [[ "$UNIXNAME" == "Darwin" ]] || return 0

   if [[ "$KHOSTS_NETWORK" =~ ^([0-9]+\.[0-9]+\.[0-9]+)\.0/24$ ]]; then
      network_prefix="${BASH_REMATCH[1]}."
   else
      return 0
   fi

   while read -r addr dev; do
      [[ -n "$addr" && -n "$dev" ]] || continue
      [[ "$dev" == "$mp_iface" ]] && continue
      [[ "$addr" == "$network_prefix"* ]] || continue

      if [[ $found -eq 0 ]]; then
         echo -e "\n${BOLDRED}Conflitto rete host: ${KHOSTS_NETWORK} e' configurata anche fuori da ${mp_iface}.${NC}" >&2
         echo -e "${RED}Su macOS questo puo' rompere la NAT Multipass: pf puo' usare quell'IP come sorgente esterna.${NC}" >&2
      fi
      found=1
      echo -e "${RED}Indirizzo sospetto: ${BOLDRED}${addr}${RED} su ${BOLDRED}${dev}${NC}" >&2
      echo -e "${RED}Se e' un alias rimasto dai test, rimuovilo con:${NC}" >&2
      echo -e "  ${BOLDRED}sudo ifconfig ${dev} inet ${addr} -alias${NC}" >&2
   done < <(/sbin/ifconfig 2>/dev/null | awk '
      /^[a-zA-Z0-9_.:-]+:/ {
         dev=$1
         sub(/:.*/, "", dev)
      }
      $1 == "inet" {
         print $2, dev
      }')

   [[ $found -eq 0 ]]
}

ensure_host_route() {
   local iface kh_route_iface err

   echo -e "\n${RED}IP di cluster da config.sh: ${BOLDRED}${KHOSTS_NETWORK}${NC}"

   iface=$(detect_multipass_route_iface || true)
   if [[ -z "$iface" && "$UNIXNAME" == "Darwin" ]]; then
      iface=bridge100
   fi
   if [[ -z "$iface" ]]; then
      echo -e "${BOLDRED}Impossibile determinare l'interfaccia host Multipass.${NC}" >&2
      echo -e "${RED}Verifica manualmente la route verso ${BOLDRED}${KHOSTS_NETWORK}${RED}.${NC}" >&2
      return 1
   fi

   kh_route_iface=$(route_iface_for_ip "${KHOSTS[$first_node]}" || true)
   if [[ "$kh_route_iface" == "$iface" ]]; then
      echo -e "${RED}Route client verso ${BOLDRED}${KHOSTS_NETWORK}${RED} OK (interfaccia ${BOLDRED}${iface}${RED}).${NC}"
      if ! check_host_khosts_alias_conflicts "$iface"; then
         exit 1
      fi
      return 0
   fi

   echo -e "${RED}Aggiungo route client verso ${BOLDRED}${KHOSTS_NETWORK}${RED} via ${BOLDRED}${iface}${RED}.${NC}"
   echo -e "${BOLDRED}Potrebbe servire la password sudo: la route e' una tantum e serve solo al client per raggiungere gli IP KHOSTS.${NC}"
   err=$(mktemp)

   if command -v ip >/dev/null 2>&1; then
      if sudo ip route replace "$KHOSTS_NETWORK" dev "$iface" 2>"$err"; then
         rm -f "$err"
         echo -e "${RED}Route aggiunta con ${IT}ip route replace${NOIT}.${NC}"
         if ! check_host_khosts_alias_conflicts "$iface"; then
            exit 1
         fi
         return 0
      fi
      if sudo ip route add "$KHOSTS_NETWORK" dev "$iface" 2>"$err"; then
         rm -f "$err"
         echo -e "${RED}Route aggiunta con ${IT}ip route add${NOIT}.${NC}"
         if ! check_host_khosts_alias_conflicts "$iface"; then
            exit 1
         fi
         return 0
      fi
   fi

   if [[ "$UNIXNAME" == "Darwin" ]]; then
      if sudo route -n add -net "$KHOSTS_NETWORK" -interface "$iface" 2>"$err"; then
         rm -f "$err"
         echo -e "${RED}Route aggiunta con ${IT}route -n add${NOIT}.${NC}"
         if ! check_host_khosts_alias_conflicts "$iface"; then
            exit 1
         fi
         return 0
      fi
   fi

   echo -e "${BOLDRED}Non sono riuscito ad aggiungere automaticamente la route.${NC}" >&2
   [[ -s "$err" ]] && sed 's/^/  /' "$err" >&2
   rm -f "$err"
   echo -e "${RED}Prova manualmente:${NC}" >&2
   if command -v ip >/dev/null 2>&1; then
      echo -e "  ${BOLDRED}sudo ip route replace ${KHOSTS_NETWORK} dev ${iface}${NC}" >&2
   fi
   if [[ "$UNIXNAME" == "Darwin" ]]; then
      echo -e "  ${BOLDRED}sudo route -n add -net ${KHOSTS_NETWORK} -interface ${iface}${NC}" >&2
   fi
   return 1
}

# ─── main ───────────────────────────────────────────────────────────────────

configured_count=$(configured_node_count)
read_khosts_ping_state

if [[ "$KHOSTS_PING_OK" -eq "$configured_count" && "$configured_count" -gt 0 ]]; then
   print_reachable_cluster_and_exit "$KHOSTS_PING_OK_NODES"
fi

if [[ "$KHOSTS_PING_OK" -gt 0 ]]; then
   abort_inconsistent_khosts "$KHOSTS_PING_OK_NODES" "$KHOSTS_PING_FAILED_NODES"
fi

if ! existing_nodes=$(mp_configured_existing_nodes); then
   echo -e "\n${BOLDRED}Nessun IP KHOSTS risponde, ma Multipass non risponde a 'multipass list'.${NC}" >&2
   echo -e "${RED}Non creo VM alla cieca: potrebbero esistere gia' istanze con gli stessi nomi.${NC}" >&2
   echo -e "${RED}Ripristina Multipass o ripulisci manualmente, poi riesegui:${NC}" >&2
   echo -e "  ${IT}./mp_kcluster_launch.sh${NC}" >&2
   exit 1
fi
if [[ -n "$existing_nodes" ]]; then
   abort_inconsistent_khosts "$KHOSTS_PING_OK_NODES" "$KHOSTS_PING_FAILED_NODES" "$existing_nodes"
fi

echo -e "\n${RED}Nessun IP KHOSTS risponde e nessuna VM Multipass configurata esiste: creo il cluster.${NC}"
launch_vms
[[ $DRYRUN -eq 1 ]] && exit 0
read_mp_vms
wait_cloud_init_or_abort
check_khosts_aliases_or_abort
ensure_host_route
echo -e "${RED}Puoi rieseguire in qualsiasi momento: se il cluster esiste gia', non verra' modificato.${NC}"

echo -e "\n${BOLDGREEN}VMs attive:${NC}"
multipass list

print_next_step
