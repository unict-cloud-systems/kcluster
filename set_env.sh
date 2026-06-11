# shellcheck shell=bash
# Eseguire con "source"
TO_BE_SOURCED=1

should_be_bash() {
   echo "It should instead be sourced on the bash:" 1>&2
   echo "     . $1" 1>&2
}

if [[ $0 != "-bash" && $0 != "bash" ]] ; then
   if [[ $ZSH_EVAL_CONTEXT ]] ; then
      echo "This script was sourced on zsh, so failed to set up your environment" 1>&2
      should_be_bash $0
      return
   else
      echo "This script was invoked directly (\$0 is $0)" 1>&2
      should_be_bash $0
      exit
   fi
fi

#unset ALREADY_RUN
if [[ "$1" == "-r" ]] ; then
   source "$(dirname "${BASH_SOURCE[0]}")/_scripts/reset_clnt_env.sh"
   return $?
fi

[[ $THIS_SET_CLNT_SCRIPT ]] && touch "/tmp/_kenv_rerun_$$"

source "$(dirname ${BASH_SOURCE[0]})/_scripts/reset_clnt_env.sh" >/dev/null
THIS_SET_CLNT_SCRIPT=$(basename ${BASH_SOURCE[0]})
[[ -f "/tmp/_kenv_rerun_$$" ]] && ALREADY_RUN=1 && rm -f "/tmp/_kenv_rerun_$$"

# -l: set up local environment only, skip remote key distribution and /etc/hosts update
# -f: force full re-run even if environment was already set up
# -r: reset local client environment only
LOCAL_ONLY=0
FORCE=0
[[ "$1" == "-l" ]] && LOCAL_ONLY=1
[[ "$1" == "-f" ]] && FORCE=1

source ./set_vars.sh > /dev/null || {
   echo -e "${BOLDRED}Failed to source set_vars.sh, cannot continue${NC}"
   return 1
}

if [[ -z "$KEYFILE" ]]; then
   echo -e "${BOLDRED}KEYFILE missing or invalid -- define it properly in config.sh and/or regenerate it with:${NC}" 1>&2
   echo -e "${IT}ssh-keygen -t rsa -N '' -C 'k8s' -f <KEYFILE>${NC}" 1>&2
   echo -e "${BOLDRED}then re-source ${BASH_SOURCE[0]}${NC}" 1>&2
   return 1
fi

if [[ -z "$KUSER" ]]; then
   echo -e "${BOLDRED}KUSER missing --- define it properly in config.sh" 1>&2
   echo -e "${BOLDRED}then re-source ${BASH_SOURCE[0]}${NC}" 1>&2
   return 1
fi

write_ssh_config() {
   unset ssh_entry
   echo "Host *"                     > xhosts_ssh_config 
   echo "PasswordAuthentication No" >> xhosts_ssh_config
   echo "StrictHostKeyChecking No"  >> xhosts_ssh_config
   echo "UserKnownHostsFile /dev/null" >> xhosts_ssh_config
   echo "GlobalKnownHostsFile /dev/null" >> xhosts_ssh_config
   echo "CheckHostIP No"            >> xhosts_ssh_config
   echo "LogLevel ERROR"            >> xhosts_ssh_config
   echo "User $KUSER"               >> xhosts_ssh_config
   echo "IdentityFile $KEYFILE"     >> xhosts_ssh_config
   echo ""                          >> xhosts_ssh_config
   for n in $NODES ; do
      ssh_entry="Host $n\n"
      ssh_entry="${ssh_entry}Hostname ${KHOSTS[$n]}\n"
      echo -e $ssh_entry >> xhosts_ssh_config
   done
}

write_ssh_config

_send_key_to_all() {
   local pubkey="$1"
   local sshopts_copy_id="-i $KEYFILE -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -o CheckHostIP=no -o LogLevel=ERROR -o User=$KUSER"

   
   for n in $NODES ; do
      # Pipe key via stdin to avoid quoting issues; LogLevel=ERROR silences warnings
      _result=$(echo "$pubkey" | command ssh $sshopts_copy_id ${KHOSTS[$n]} \
         "read k
          grep -qF \"\$k\" ~/.ssh/authorized_keys 2>/dev/null && echo exists || \
          { mkdir -p ~/.ssh; chmod 700 ~/.ssh
            echo \"\$k\" >> ~/.ssh/authorized_keys; chmod 600 ~/.ssh/authorized_keys
            echo added; }" 2>/dev/null)
      if [[ "$_result" == "added" ]]; then
         echo -e "${KRED[$n]}Public key newly copied to $n${NC}"
      elif [[ "$_result" == "exists" ]]; then
         echo -e "${KRED[$n]}Public key already authorized for $KUSER@$n${NC}"
      else
         echo -e "${BOLDRED}Copying key to $n failed (ssh error? wrong password? user '$KUSER' does not exist on $n?${NC}"
         echo -e "${BOLDRED}    or: key not yet authorized on $n and password login forbidden by remote host -- e.g. EC2 instance)${NC}"
         return 1
      fi
   done
   echo
}

# currently unused, ssh-copy-id too verbose
_send_keys_1() {
   local sshopts_id_copy="-i $KEYFILE -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -o CheckHostIP=no -o LogLevel=ERROR -o User=$KUSER"
   for n in $NODES ; do
      echo -e "${KRED[$n]}Copying public key to remote node ${n}${NC}"
      ssh-copy-id $sshopts_id_copy $n
      echo -e "${KRED[$n]}Public key should be on remote node ${n}${NC}\n"
   done
}

# run_checked_at <node> <stdout-sink> <cmd...>
# Runs cmd with stdout sent to <stdout-sink>; on failure prints cmd's stderr in
# the node's bold+underlined color. Returns cmd's exit status.
run_checked_at() {
   local n=$1 sink=$2; shift 2
   local err
   err=$("$@" 2>&1 >"$sink") || {
      [[ -n "$err" ]] && echo -e "${KBRED[$n]}${UL}${err}${NC}"
      echo -e "${BOLDRED}command intended for node $n failed: $*${NC}\n"
      return 1
   }
}

SSHOPTS="-F ${PWD}/xhosts_ssh_config"
export SSHOPTS

# ssh and scp are redefined as bash functions (not aliases) so that $SSHOPTS
# (-F xhosts_ssh_config, which carries the identity file, user, and host entries)
# is injected automatically in every context: interactive shell, sourced scripts,
# and executed subprocesses (export -f makes the function visible to child bash
# processes).
#
# Important: in bash, \ssh and \scp only bypass aliases, not functions. Use
# `command ssh` / `command scp` here to avoid recursive calls to these wrappers.
ssh()  { command ssh  $SSHOPTS "$@"; }
scp()  { command scp  $SSHOPTS "$@"; }
export -f ssh scp

remote_hosts_preflight() {
   khosts_ping_reachability --timeout 1 && return 0

   echo
   echo -e "${BOLDRED}No configured node answers ping; remote setup cannot start.${NC}"
   echo -e "${RED}Create/start the configured hosts first, or fix KHOSTS/client routing in ${IT}config.sh${NOIT}${RED}.${NC}"
   if [[ -x ./mp_kcluster_launch.sh ]]; then
      echo -e "${RED}Multipass helper available, if relevant: ${BOLD}${IT}./mp_kcluster_launch.sh${NC}"
   fi
   echo -e "${RED}Then source the environment again:${NC}"
   echo -e "  ${BOLD}${IT}. ./set_env.sh${NC}"
   return 1
}

remote_set() {

   echo -e "${RED}Public key in file ${NC}${IT}${KEYFILE}.pub${NC}"
   echo -e "${RED}must be authorized on nodes ${NC}${IT}$NODES${NC}${RED} for user ${NC}${IT}${KUSER}${NC}"
   echo -e "${RED}let's check and, if it's not already done, we'll try to set that up for you${NC}\n"
   _pubkey=$(cat "${KEYFILE}.pub" 2>/dev/null)
   if [[ -z "$_pubkey" ]]; then
      echo -e "${BOLDRED}Cannot read ${KEYFILE}.pub${NC}"; return 1
   fi
   remote_hosts_preflight || return 1
   _send_key_to_all "$_pubkey" || {
      echo -e "${BOLDRED}Failed to copy key to all nodes, cannot continue${NC}"
      return 1
   }

   # Check that KUSER can run passwordless sudo on all nodes, required for setup and reset scripts
   echo -e "${RED}Checking if user ${IT}$KUSER${NOIT}${RED} can run passwordless sudo on all nodes${NC}"
   for n in $NODES ; do
      run_checked_at $n /dev/null ssh $n "sudo -n true" || {
         echo -e "${BOLDRED}$n: $KUSER cannot run passwordless sudo${NC}" >&2
         echo -e "${BOLDRED}KUSER must have NOPASSWD sudo on all nodes -- standard Ubuntu VMs have this by default${NC}" >&2
         echo -ne "${BOLDRED}Fix on $n: as root $NC"
         echo -e "${BOLDRED}(overrides any conflicting rule that may appear later in /etc/sudoers)${NC}" >&2
         echo -e "${IT}echo '$KUSER ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/99-${KUSER}-nopasswd && chmod 440 /etc/sudoers.d/99-${KUSER}-nopasswd${NC}" >&2
         return 1
      }
   done

   for n in $NODES ; do
      echo -e "${KRED[$n]}Checking if remote setup files exist on ${IT}$n${NOIT}${NC}"
      if ! ssh $n "test -d $BASESETUPDIR && test -f $BASESETUPDIR/config.sh" 2>/dev/null ; then
         echo -e "${KRED[$n]}Setup file absent on $n: expected ${IT}$BASESETUPDIR/config.sh${NOIT}${NC}"
         echo -e "${KRED[$n]}This is normal just after creating a fresh cluster.${NC}"
         return 1
      fi

      echo -e "${KRED[$n]}Checking if ${IT}config.sh${NOIT} is stale at remote node ${IT}$n${NOIT}, retrieving ${IT}$n:$BASESETUPDIR/config.sh${NOIT}${NC}"
      run_checked_at $n /dev/null scp $n:$BASESETUPDIR/config.sh config.$n || {
         echo -e "${BOLDRED}Unexpected failure retrieving $n:$BASESETUPDIR/config.sh after remote existence check passed.${NC}"
         return 1
      }
      if diff -q config.$n config.sh &> /dev/null ; then
         echo -ne "${KRED[$n]}Remote (@$n) config.sh matches local one, ${NC}"
         echo -e  "${KRED[$n]}need not change remote /etc/hosts at $n$NC\n"
      else
         echo -e "${KRED[$n]}remote (@$n) and local config.sh differ -- sending updated config.sh to $n:$BASESETUPDIR/${NC}"
         run_checked_at $n /dev/null scp config.sh $n:$BASESETUPDIR/ || {
            rm -f config.$n; return 1
         }
         run_checked_at $n /dev/null ssh $n "cd $BASESETUPDIR; sudo bash set_vars.sh update_etc_hosts" || {
            rm -f config.$n; return 1
         }
         echo -e "${KRED[$n]}Updated /etc/hosts at remote node $n with any new nodes from config.sh$NC"
      fi
      rm -f config.$n
   done
}

what_did() {
   local cmd_style="${NC}${BOLD}${IT}"
   local cmd_col=53
   local cmd_ind=2
   echo -e "${RED}Bash functions available in the environment:${NC}"
   echo -e "  ${BOLD}${IT}  all_boot   all_nodes   all_reset${NC}"
   echo -e "  ${BOLD}${IT}get_master   get_kconf${NC}"
#  echo -e "  ${BOLD}${IT}k8s_setup_hints${NC}"
   echo -e "  ${BOLD}${IT}      scp    ssh${NC}         ${GRAY}# scp/ssh (injecting \"${SSHOPTS/${PWD}/\$PWD}\") to a remote host in $NC${BOLD}${IT}$NODES${NC}$GRAY$NC"
   echo -e "  ${BOLD}${IT}             sshx${NC}        ${GRAY}# get directions to multi-ssh to all nodes simultaneously$NC"
   echo -e "call any of them with no args to get usage instructions\n"
   printf "%b%-${cmd_col}s%b. %s -f%b\n" "$RED" "force remote key/hosts setup again:" "$cmd_style" "$THIS_SET_CLNT_SCRIPT" "$NC"
   printf "%b%-${cmd_col}s%b. %s -l%b\n" "$RED" "(re)-set up local env (no remote key/hosts setup):" "$cmd_style" "$THIS_SET_CLNT_SCRIPT" "$NC"
   printf "%b%-${cmd_col}s%b. %s -r%b\n\n" "$RED" "reset/undefine local env only:" "$cmd_style" "$THIS_SET_CLNT_SCRIPT" "$NC"
   echo -ne "${RED}or, if you need to, you may now run:       ${NC}"
   printf "%${cmd_ind}s%b%s%b\n" "" "$cmd_style" "./upload_kcluster_setup.sh --zip|-z " "$NC"
   printf "${RED}or${NC}%${cmd_ind}s%b%s%b\n\n" "" "$cmd_style" "./upload_kcluster_setup.sh --send-to-khosts|-y | --dry-run-send-to-khosts|-n" "$NC"
}

upload_hint() {
   local cmd_style="${NC}${BOLD}${IT}"
   echo -e "${RED}To upload K8s setup scripts to hosts:${NC} ${cmd_style}./upload_kcluster_setup.sh -y${NC}"
}

already_set_legacy_message() {
   echo -e "${RED}environment already set up -- nothing done.${NC}"
   echo -e "  local environment refresh only:    ${IT}. $THIS_SET_CLNT_SCRIPT -l${NC}"
   echo -e "  as above and redo remote settings: ${IT}. $THIS_SET_CLNT_SCRIPT -f${NC}"
   echo -e "  clear local environment:           ${IT}. $THIS_SET_CLNT_SCRIPT -r${NC}  # makes way for a new \`. $THIS_SET_CLNT_SCRIPT\`"
}

already_set_notice() {
   echo -e "${BOLDRED}environment already set up -- no remote settings redone (force/redefine with -f or -l, reset with -r)${NC}\n"
   what_did
   remote_access_hints
}

source _scripts/utils.sh

if [[ $ALREADY_RUN && $LOCAL_ONLY -eq 0 && $FORCE -eq 0 ]] ; then
   already_set_notice
   return 0
elif [[ $LOCAL_ONLY -eq 1 ]] ; then
   what_did
   echo -e "${RED}local client environment set up (remote key/hosts setup skipped)${NC}\n"
   remote_access_hints
else
   remote_set
   if [ $? = 0 ] ; then
      what_did
      echo -e "${RED}client environment successfully set up${NC}"
      echo -e "${RED}you can re-source this script any time (won't redo remote setup)${NC}\n"
      upload_hint
      remote_access_hints
   else
      echo
      echo -e "${RED}Could not complete setting up remote hosts environment, fix above pending issues and run this script again${NC}"
      upload_hint
      remote_access_hints
      unset ALREADY_RUN THIS_SET_CLNT_SCRIPT
      return 1
   fi
fi
