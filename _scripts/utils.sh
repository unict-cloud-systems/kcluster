# shellcheck shell=bash
TO_BE_SOURCED=1
# NB: ssh and scp here are the functions exported by set_env.sh -- they carry
# SSHOPTS automatically. Use 'command ssh' / '/usr/bin/ssh' to reach the system binary directly.

sshx() {
(
    usage() {
      local first_node rest_nodes
      first_node=${NODES%% *}
      rest_nodes=${NODES#* }
      [[ "$rest_nodes" == "$NODES" ]] && rest_nodes=""

      echo "Usage: sshx [-l layout] <host1> <host2> [<host3> ...] [-<master-host>]"
      echo "  -l layout: Optional layout (tiled, even-horizontal, even-vertical,"
      echo "             main-horizontal, main-vertical)"
      echo "Hint: Open a new (large) bash window ready, then run,"
      printf '    e.g.:  %b%-18s%b %b# via tmux, open synchronized panes, one per host%b\n' \
         "$BOLD" 'sshx $NODES' "$NC" "$GRAY" "$NC"
      if [[ -n "$first_node" ]]; then
         printf 'or, e.g.:  %b%-18s%b %b# also puts %b%s%b in its own master window%b\n' \
            "$BOLD" "sshx \$NODES -$first_node" "$NC" "$GRAY" "$NC$BOLD" "$first_node" "$GRAY" "$NC"
      fi
      if [[ -n "$rest_nodes" ]]; then
         printf 'or, e.g.:  %b%-18s%b %b# opens synchronized panes for: %b%s%b%b\n' \
            "$BOLD" "sshx $rest_nodes" "$NC" "$GRAY" "$NC$BOLD" "$rest_nodes" "$GRAY" "$NC"
      fi
      echo ""
      read -p "Want K8s specific directions to run on each host via tmux? (y/n) " -n 1 -r
      echo
      if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo ""
        echo "Useful tmux key bindings (prefix is ${BOLD}Ctrl+b${NC}):"
        echo "   ${BOLD}Ctrl+b q + number${NC}              ${GRAY}select pane by number${NC}"
        echo "   ${BOLD}Ctrl+b !${NC}                       ${GRAY}break current pane into its own window${NC}"
        echo "   ${BOLD}Ctrl+b n${NC}                       ${GRAY}cycles to next window${NC}"
        echo "   ${BOLD}Ctrl+b [${NC}                       ${GRAY}scroll/copy mode (arrows to scroll, Q to quit)${NC}"
        echo "   ${BOLD}Ctrl+b x${NC}                       ${GRAY}kill current pane${NC}"
        echo "   ${BOLD}Ctrl+b :kill-session${NC}           ${GRAY}kill all panes and exit${NC}"
        echo "   ${BOLD}Ctrl+b d${NC}                       ${GRAY}detach window from session (still runs, to go back: tmux attach)${NC}"
        echo ""
        local motd_tmp
        motd_tmp=$(mktemp)
        ./_scripts/render_template.sh --motd --output "$motd_tmp" &&
           SETUP_KUBE_HOME="/home/$KUSER" SETUP_KUBE_SHOW_TMUX_HINT=1 /bin/sh "$motd_tmp"
        rm -f "$motd_tmp"
      fi
    }

    local layout="tiled"
    local master_node=""
    local host
    local -a hosts=()
    local -a worker_hosts=()

    if [[ "$1" == "-l" ]]; then
      if [[ ! "$2" =~ ^(even-horizontal|even-vertical|main-horizontal|main-vertical|tiled)$ ]]; then
        echo "Invalid layout: $2" >&2
        usage
        return 1
      fi
      layout="$2"
      shift 2
    fi

    if [[ $# -eq 0 ]]; then
      usage
      return 1
    fi

    for host in "$@"; do
      if [[ "$host" == --* ]]; then
        echo "Invalid sshx host/master marker: $host" >&2
        usage
        return 1
      elif [[ "$host" == -* ]]; then
        if [[ -n "$master_node" ]]; then
          echo "Only one -<master-host> marker is supported" >&2
          return 1
        fi
        master_node=${host#-}
        [[ -n "$master_node" ]] || { echo "Empty master marker '-'" >&2; return 1; }
      else
        hosts+=("$host")
      fi
    done

    if [[ ${#hosts[@]} -eq 0 ]]; then
      usage
      return 1
    fi

    if [[ -n "$master_node" ]]; then
      local found_master=0
      for host in "${hosts[@]}"; do
        if [[ "$host" == "$master_node" ]]; then
          found_master=1
        else
          worker_hosts+=("$host")
        fi
      done
      if [[ $found_master -ne 1 ]]; then
        echo "Master marker -$master_node does not match any host argument" >&2
        return 1
      fi
      if [[ ${#worker_hosts[@]} -eq 0 ]]; then
        echo "Master marker leaves no worker hosts for synchronized panes" >&2
        return 1
      fi
    else
      worker_hosts=("${hosts[@]}")
    fi

    sshx_cmd_for_host() {
      printf 'ssh -t %s "marker=/tmp/setup-kube-tmux-hint.\\$(tty | sed s#[^A-Za-z0-9_.-]#_#g); touch \\$marker; SETUP_KUBE_CLEAR_SCREEN=1 SETUP_KUBE_SHOW_TMUX_HINT=1 /etc/update-motd.d/99-setup-kube; exec \\${SHELL:-/bin/bash} -l"' "$1"
    }

    local sshx_cmd
    local -a tmux_args
    if [[ -n "$master_node" ]]; then
      sshx_cmd=$(sshx_cmd_for_host "$master_node")
      tmux_args=(new-session -s multi-ssh -n master ';' send-keys "$sshx_cmd" C-m ';' new-window -n multi-ssh)
    else
      tmux_args=(new-session -s multi-ssh)
    fi

    sshx_cmd=$(sshx_cmd_for_host "${worker_hosts[0]}")
    tmux_args+=(';' send-keys "$sshx_cmd" C-m)

    # gli host worker successivi ottengono ciascuno un pane aggiuntivo
    for host in "${worker_hosts[@]:1}"; do
      sshx_cmd=$(sshx_cmd_for_host "$host")
      tmux_args+=(';' split-window -h ';' send-keys "$sshx_cmd" C-m)
    done

    tmux_args+=(';' select-layout "$layout" ';' set-window-option synchronize-panes on)
    tmux "${tmux_args[@]}"
  )
}

all_nodes ()
{
   if [[ $1 == "" ]]; then
      echo "Usage: all_nodes <command-on-all-nodes>";
      return;
   fi;
   for n in $NODES ; do
      printf "%b%5s%b " "${KRED[$n]}" "[$n]" "$NC"
      ssh ${KHOSTS[$n]} "$*";
   done
}

remote_access_hints() {
   echo -e "${RED}Per operare su un ${NC}${IT}host${NC}${RED} tra ${NC}${IT}${NODES}${NC}${RED}               ${NC}${BOLD}ssh $NC${IT}host${NC}"
   echo -e "${RED}Info per operare su multi-host in sync con tmux      ${NC}${BOLD}sshx -h${NC}"
   echo -e "${RED} o (meglio da nuova finestra bash) direttamente      ${NC}${BOLD}sshx${NC} ${IT}${NODE_ARR[0]} ${NODE_ARR[1]}${NC} ..."
}

k8s_setup_hints() {
   echo -ne "\n${RED}Gli host $BOLDRED${NODES// /,}$RED hanno $NC"
   echo -e "${RED}IP KHOSTS \n$BOLDRED${KHOSTIPS// /,}$NC"

   echo -ne "$RED"
   echo -e " 1. ogni host deve avere un utente $NC${IT}$KUSER$NOIT$RED (KUSER in ${NC}${IT}config.sh$NC$RED)"
   echo -e " 2. l'utente $NC${IT}$KUSER$NOIT$RED di ogni host deve essere sudoer senza password (NOPASSWD)"
   echo -e " 3. su ogni host gli script si trovano in $NC${IT}/home/$KUSER/$BASESETUPDIR$NC$RED"
   echo -e " 4. l'utente $NC${IT}$KUSER$NOIT$RED di ogni host deve poter eseguire ssh e scp senza password verso ogni "
   echo -e "    altro host (incluso se stesso) usando la chiave privata di $NC${IT}$KEYFILE$NOIT${RED}"
   echo -e "    - deve quindi avere $NC${IT}$KEYFILE$NOIT${RED} (KEYFILE in ${NC}${IT}config.sh$NC$RED) e avere la chiave pubblica "
   echo -e  "      in $NC${IT}${KEYFILE}.pub$NOIT${RED} tra quelle autorizzate in $NC${IT}/home/$KUSER/.ssh/authorized_keys$NOIT${RED} ${NC}"
   echo -e  "      su ogni host (incluso se stesso)${NC}"
   echo -e "${BOLDRED}I vincoli 1 (utente) e 2 (NOPASSWD sudo) sono prerequisiti: vanno soddisfatti manualmente.$NC$NC"
   echo -e "${RED}I vincoli 3 (directory per script) e 4 (chiavi ssh) sono garantiti da ${NC}${IT}upload_kcluster_setup.sh${NC}${RED} e ${NC}${IT}set_env.sh${NC}${RED}:"
   echo -e "  - ${NC}${IT}upload_kcluster_setup.sh${NC}${RED} crea la directory sugli host, se mancante, e vi copia i file, inclusa la chiave configurata in KEYFILE"
   echo -e "  - ${NC}${IT}set_env.sh${NC}${RED} inserisce la chiave pubblica tra quelle autorizzate su tutti i nodi e aggiorna /etc/hosts quando serve${NC}"
}

khosts_ssh_reachability() {
   local allow_auth_failure=0 require_auth=0 quiet=0 timeout=2
   local n err rc

   while [[ $# -gt 0 ]]; do
      case "$1" in
         --allow-auth-failure) allow_auth_failure=1 ;;
         --require-auth) require_auth=1 ;;
         --quiet) quiet=1 ;;
         --timeout) timeout=$2; shift ;;
         *) echo "Usage: ${FUNCNAME[0]} [--allow-auth-failure|--require-auth] [--quiet] [--timeout seconds]" >&2; return 2 ;;
      esac
      shift
   done

   KHOSTS_SSH_OK=0
   KHOSTS_SSH_AUTH_FAILED=0
   KHOSTS_SSH_UNREACHABLE=0
   KHOSTS_SSH_REACHABLE=0
   KHOSTS_SSH_UNREACHABLE_NODES=""
   KHOSTS_SSH_AUTH_FAILED_NODES=""

   [[ $quiet -eq 1 ]] || echo -e "${RED}Checking whether configured nodes are reachable by ssh${NC}"
   for n in $NODES ; do
      err=$(command ssh $SSHOPTS -o BatchMode=yes -o ConnectTimeout="$timeout" "$n" true 2>&1 >/dev/null)
      rc=$?
      if [[ $rc -eq 0 ]]; then
         KHOSTS_SSH_OK=$((KHOSTS_SSH_OK + 1))
         KHOSTS_SSH_REACHABLE=$((KHOSTS_SSH_REACHABLE + 1))
         [[ $quiet -eq 1 ]] || echo -e "${KRED[$n]}$n reachable by ssh${NC}"
      elif [[ "$err" == *"Permission denied"* ]]; then
         KHOSTS_SSH_AUTH_FAILED=$((KHOSTS_SSH_AUTH_FAILED + 1))
         KHOSTS_SSH_AUTH_FAILED_NODES="$KHOSTS_SSH_AUTH_FAILED_NODES $n"
         [[ $allow_auth_failure -eq 1 ]] && KHOSTS_SSH_REACHABLE=$((KHOSTS_SSH_REACHABLE + 1))
         [[ $quiet -eq 1 ]] || echo -e "${KRED[$n]}$n reachable, but ssh key is not accepted yet${NC}"
      else
         KHOSTS_SSH_UNREACHABLE=$((KHOSTS_SSH_UNREACHABLE + 1))
         KHOSTS_SSH_UNREACHABLE_NODES="$KHOSTS_SSH_UNREACHABLE_NODES $n"
         [[ $quiet -eq 1 ]] || echo -e "${KRED[$n]}$n not reachable yet (${KHOSTS[$n]})${NC}"
      fi
   done
   [[ $quiet -eq 1 ]] || echo -n

   if [[ $require_auth -eq 1 ]]; then
      [[ $KHOSTS_SSH_OK -eq $(wc -w <<< "$NODES") ]]
   else
      [[ $KHOSTS_SSH_REACHABLE -gt 0 ]]
   fi
}

khosts_ping_reachability() {
   local quiet=0 timeout=1 n host_ip

   while [[ $# -gt 0 ]]; do
      case "$1" in
         --quiet) quiet=1 ;;
         --timeout) timeout=$2; shift ;;
         *) echo "Usage: ${FUNCNAME[0]} [--quiet] [--timeout seconds]" >&2; return 2 ;;
      esac
      shift
   done

   KHOSTS_PING_OK=0
   KHOSTS_PING_FAILED=0
   KHOSTS_PING_OK_NODES=""
   KHOSTS_PING_FAILED_NODES=""

   [[ $quiet -eq 1 ]] || echo -e "${RED}Checking whether configured nodes answer ping${NC}"
   for n in $NODES ; do
      host_ip=${KHOSTS[$n]}
      if ping -c 1 -W "$timeout" "$host_ip" >/dev/null 2>&1 ; then
         KHOSTS_PING_OK=$((KHOSTS_PING_OK + 1))
         KHOSTS_PING_OK_NODES="$KHOSTS_PING_OK_NODES $n"
         [[ $quiet -eq 1 ]] || echo -e "${KRED[$n]}$n reachable by ping (${host_ip})${NC}"
      else
         KHOSTS_PING_FAILED=$((KHOSTS_PING_FAILED + 1))
         KHOSTS_PING_FAILED_NODES="$KHOSTS_PING_FAILED_NODES $n"
         [[ $quiet -eq 1 ]] || echo -e "${KRED[$n]}$n not reachable by ping (${host_ip})${NC}"
      fi
   done
   [[ $quiet -eq 1 ]] || echo

   [[ $KHOSTS_PING_OK -gt 0 ]]
}

is_master() {
   local kargs
   kargs="-l 'node-role.kubernetes.io/control-plane' -o jsonpath='{.items[0].metadata.name}'"
   if [[ $1 == "" ]] ; then
      echo "Usage: ${FUNCNAME[0]} <node> (one of $NODES)"
      return 2
   fi
   ssh ${KHOSTS[$1]} "cd $BASESETUPDIR; kubectl get nodes $kargs" >& /dev/null
}

get_master() {
   for n in $NODES ; do
      if is_master $n ; then
         echo $n
         return
      fi
   done
}

get_kconf(){
   local master
   local master_node
   master_node=$(get_master)
   if [[ ! $master_node ]] ; then
      echo No cluster
      return
   fi
   master=${KHOSTS[$master_node]}
   run_checked_at $master_node /dev/null scp $master:.kube/config ${TMPDIR}config.$master_node || {
      echo -e "${BOLDRED}Failed to fetch kubeconfig from $master_node; $HOME/.kube/config left untouched${NC}"
      return 1
   }
   cp -b ${TMPDIR}config.$master_node $HOME/.kube/config
   rm ${TMPDIR}config.$master_node
   echo -e "remote master's config is now in $HOME/.kube/config,\n\$KUBECONFIG will be unset"
   echo "you may run kubectl from this client towards the cluster"
   unset KUBECONFIG
}

all_reset() {
   local master
   local nodes1
   local appendix
   if [[ $1 == "-q" ]] ; then
      appendix=" > /dev/null"
   fi
   master=$(get_master)
   if [[ ! $master ]] ; then
      echo No cluster
      master=none
   fi
   for n in $NODES ; do
      if [[ $n != "$master" ]] ; then
         nodes1="$nodes1 $n"
         ssh ${KHOSTS[$n]} "cd $BASESETUPDIR; sudo ./reset_kube.sh" $appendix &
      fi
   done
   wait
   echo -e "\n${BOLDGREEN}[$THIS_SET_CLNT_SCRIPT] nodes$nodes1 in the cluster reset${NC}"
   if [[ $master != none ]] ; then
      ssh ${KHOSTS[$master]} "cd $BASESETUPDIR; sudo ./reset_kube.sh" $appendix
      echo -e "\n${BOLDGREEN}[$THIS_SET_CLNT_SCRIPT] master $master reset ${NC}"
   fi
}

all_boot() {
   local master
   local nodes1
   local appendix

   unset master
   if ( [[ $1 == "" ]] || [[ $1 == "-q" ]] ) && [[ $THISNODE == none ]] ; then
      if [[ -n "$MASTER_NODE" ]] ; then
         set -- "$MASTER_NODE" "$@"
      else
         echo "This host cannot be a k8s master and MASTER_NODE is not set."
         echo "Usage: ${FUNCNAME[0]} [-q]             (to be run on the future master)"
         echo "       ${FUNCNAME[0]} master-node [-q] (one of ${NODES})"
         echo "       set MASTER_NODE=<node> in your shell or in config.sh, then retry"
         return
      fi
   fi
   if [[ $1 != "" ]] && [[ $1 != "-q" ]] ; then
      for n in $NODES ; do
         if [[ $n == "$1" ]] ; then
            master=$n
            break
         fi
      done
      if [[ ! $master ]] ; then
         echo -e "${FUNCNAME[0]} was just invoked as \"${FUNCNAME[0]} $1\" but $1 is not one of ${NODES}\n"
         return
      fi
   else
      master=$THISNODE
   fi
   if [[ $1 == "-q" ]] || [[ $2 == "-q" ]] ; then
      appendix=" > /dev/null"
   fi
   ssh ${KHOSTS[$master]} "cd $BASESETUPDIR; sudo ./boot_master.sh"
   local retVal
   retVal=$?
   if [ $retVal -ne 0 ]; then
      echo "Failed booting master, will not try to boot workers"
      return $retVal
   fi
   echo -e "\n${BOLDGREEN}[$THIS_SET_CLNT_SCRIPT] master $master is up${NC}"
   if [[ $master != "$THISNODE" ]] ; then
      unset KUBECONFIG
      mkdir -p "$SETUPDIR/_kube"
      scp ${KHOSTS[$master]}:.kube/config "$SETUPDIR/_kube/config.$master"
      export KUBECONFIG="$SETUPDIR/_kube/config.$master"
   fi
   for n in $NODES ; do
      if [[ $n != "$master" ]] ; then
         nodes1="$nodes1 $n"
         ssh ${KHOSTS[$n]} "cd $BASESETUPDIR; sudo ./boot_worker.sh" $appendix &
      fi
   done
   wait
   echo -e "\n${BOLDGREEN}[$THIS_SET_CLNT_SCRIPT] workers nodes$nodes1 in the cluster are up${NC}"
   echo -ne "\n${RED}local kubectl on this client ($LOCALIP) will connect to "
   echo -e "k8s API on master node $master (${KHOSTS[$master]})${NC}"
}
