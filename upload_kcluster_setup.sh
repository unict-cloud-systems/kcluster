#!/usr/bin/env bash

OPT1=$1

if [[ x$1 == x-h || ( x$1 != x-n && x$1 != x-N && \
      "x${OPT1#--dry-run}" == "x$OPT1" && \
      x$1 != x--zip && x$1 != x-z && \
      x$1 != x--send-to-khosts && x$1 != x-y && x$1 != x-k ) ]] ; then
   echo "Usage (each -- long option has equivalent short options):" 1>&2
   echo "     $0 --send-to-khosts|-y|-k | --dry-run-send-to-khosts|-n" 1>&2
   echo "     $0 --zip|-z" 1>&2
   echo "     $0 [-h]" 1>&2
   exit
fi

# NB: si suppone che gli * nella def. di FILES vengano espansi da bash a nomi di
# file esistenti nella dir. corrente!

# Only the configured SSH key is uploaded: hosts need KEYFILE (IdentityFile in
# xhosts_ssh_config) to ssh to each other.
# Do not upload every *.pem/*.pub file in the working directory.
[[ -f ./config.sh ]] && . ./config.sh
KEY_FILES=()
if [[ -n "$KEYFILE" ]] ; then
   [[ -f "$KEYFILE" ]] && KEY_FILES+=("$KEYFILE")
   [[ -f "${KEYFILE}.pub" ]] && KEY_FILES+=("${KEYFILE}.pub")
fi

COMMON_FILES=(
   README.md
   config.sh
   set_vars.sh
   set_env.sh
   upload_kcluster_setup.sh
   install_kube.sh
   reset_kube.sh
   boot_master.sh
   boot_worker.sh
   boot_worker.sample.log
)

CLIENT_ONLY_FILES=(
   mp_kcluster_launch.sh
)

OPTIONAL_FILES=()
for f in *.toml *.json ; do
   [[ -e "$f" ]] && OPTIONAL_FILES+=("$f")
done

FILE_DIRS=()
[[ -d _templates ]] && FILE_DIRS+=("_templates")
[[ -d _scripts ]] && FILE_DIRS+=("_scripts")

FILES=()
for f in "${COMMON_FILES[@]}" "${CLIENT_ONLY_FILES[@]}" "${OPTIONAL_FILES[@]}" ; do
   [[ -e "$f" ]] && FILES+=("$f")
done

FILES_ZIP=("${FILES[@]}" "${FILE_DIRS[@]}")
FILES_RSYNC=()
for f in "${COMMON_FILES[@]}" "${OPTIONAL_FILES[@]}" ; do
   [[ -e "$f" ]] && FILES_RSYNC+=("$f")
done
FILES_RSYNC+=("${KEY_FILES[@]}" "${FILE_DIRS[@]}")

chmod -x "${FILES[@]}" 2>/dev/null || true
chmod +x *.sh
chmod -x set_vars.sh config.sh

if [[ x$1 == x-z || x$1 == x--zip ]] ; then
   [[ -f setup_kube.zip ]] && rm setup_kube.zip
   mkdir -p setup_kube
   cp -pR "${FILES_ZIP[@]}" setup_kube
   zip setup_kube.zip -r setup_kube
   rm -rf setup_kube
   exit
fi

if [[ x$1 != x-y && x$1 != x-k && x$1 != x--send-to-khosts && \
      x$1 != x-n && x$1 != x-N && "x${OPT1#--dry-run}" == "x$OPT1" ]] ; then
   echo -e "\nThis script was invoked by:${IT} $0 $* $NC"
   echo -e "${BOLDRED}This should not happen!$NC"
   exit 1
fi

if [[ ! $SSHOPTS ]] ; then
   echo -e "Before invoking this script, you should first "
   echo -e "source \". ./set_env.sh\" \033[0;41;1mfrom a bash\033[0m\n"
   exit 1
fi

[[ -f ./set_vars.sh ]] || { echo "set_vars.sh not found -- wrong directory?" >&2; exit 1; }
source ./set_vars.sh > /dev/null || \
{ echo "Failed to source set_vars.sh -- check for errors in that file" >&2; exit 1; }

[[ -z "$NODES" ]] && {
   echo -e "${BOLDRED}Nessun host configurato in config.sh -- se il target è un cluster multipass, eseguire prima mp_kcluster_launch.sh (o impostare KHOSTS manualmente)${NC}" >&2
   exit 1
}

[[ -z "$KEYFILE" ]] && { echo -e "${BOLDRED}Aborting: KEYFILE invalid (see above)${NC}" 1>&2; exit 1; }

source ./_scripts/utils.sh

if [[ x$1 == x-n || x$1 == x-N || "x${OPT1#--dry-run}" != "x$OPT1" ]] ; then
   echo -ne "${BOLDRED}DRY RUN:${NC} "
   DRYRUN="-n"
fi

echo -e "${RED}Upload degli script sugli host ${NC}${IT}${NODES}${NCR} con${NC}"
echo -e "${RED}IP KHOSTS ${NC}${IT}${KHOSTIPS}${NC}\n"
#echo -e "${RED}(futuri master e worker k8s)$NC"

khosts_ssh_reachability --require-auth --timeout 4 || {
   echo -e "${BOLDRED}Upload requires every host to be reachable by ssh with the configured key.${NC}" >&2
   if [[ $KHOSTS_SSH_REACHABLE -eq 0 && $KHOSTS_SSH_AUTH_FAILED -eq 0 ]]; then
      echo -e "${RED}If this is a Multipass cluster, create/start it first:${NC}" >&2
      echo -e "  ${BOLD}${IT}./mp_kcluster_launch.sh${NC}" >&2
   else
      echo -e "${RED}If hosts exist but keys or /etc/hosts need refresh, run:${NC}" >&2
      echo -e "  ${BOLD}${IT}. ./set_env.sh -f${NC}" >&2
   fi
   exit 1
}

# NB: anche se di norma questo script si esegue dopo il source di set_env.sh, quando si passa "-e ssh" a rsync, 
# rsync genera un processo esterno, quindi questo sarà il vero eseguibile ssh, non la funzione
# quindi dobbiamo passare esplicitamente SSHOPTS a rsync
export RSYNC_RSH="ssh $SSHOPTS"    # export per farla vedere a rsync che è un processo figlio della bash che esegue questo script 
for n in $NODES ; do
   host_ip=${KHOSTS[$n]}
   if [[ $host_ip != "$THISIP" ]] ; then
      echo -e "\n${KRED[$n]}>>> $host_ip ($n) >>>$NC"
      tmp_upload_dir=$(mktemp -d)
      tmp_upload_root="$tmp_upload_dir/$(basename "$PWD")"
      mkdir -p "$tmp_upload_root"
      cp -pR "${FILES_RSYNC[@]}" "$tmp_upload_root/"
      [[ -f "$tmp_upload_root/set_env.sh" ]] && chmod -x "$tmp_upload_root/set_env.sh"
      rsync $DRYRUN -rPtu "$tmp_upload_root/" "$n:$(basename $PWD)/" | tr '\n' ' ' ; echo
      rm -rf "$tmp_upload_dir"
      unset tmp_upload_dir tmp_upload_root
      [[ -z "$DRYRUN" ]] && ssh "$n" "chmod -x $(basename "$PWD")/set_env.sh 2>/dev/null || true"
      # delete-only pass: --existing+--ignore-existing transfer nothing, --delete removes stale remote files
      echo -e "${KRED[$n]}>>> delete-only pass to remove stale remote files $NC"
      RSYNC_DEL_EXCLUDES=(--exclude='_generated/' --exclude='calico*.yaml' --exclude='containerd-net-*.conflist' --exclude='cloud_init.yaml' --exclude='mp_*.sh' --exclude='/*/')
      rsync $DRYRUN -rP ./ "$n:$(basename $PWD)/" "${RSYNC_DEL_EXCLUDES[@]}" --delete --existing --ignore-existing \
         | grep -vi 'sending incremental file list' | tr '\n' ' ' ; echo
      for d in "${FILE_DIRS[@]}" ; do
         rsync $DRYRUN -rP "$d/" "$n:$(basename "$PWD")/$d/" --delete --existing --ignore-existing \
            | grep -vi 'sending incremental file list' | tr '\n' ' ' ; echo
      done
   fi
done

echo -ne "\n${RED}Gli host ${NC}${IT}${NODES}${NCR} hanno ${NC}"
echo -e "${RED}IP KHOSTS \n${NC}${IT}${KHOSTIPS}${NC}"
echo -e "${RED}Upload completato in ${NC}${IT}/home/$KUSER/$(basename "$PWD")${NC}${RED} su ogni host raggiungibile.${NC}\n"
echo -e "${RED}Se devi rinfrescare chiavi SSH o /etc/hosts remoti   ${NC}${BOLD}. ./set_env.sh -f${NC}"
echo -e "${RED}Per la checklist estesa dei prerequisiti, esegui     ${NC}${BOLD}k8s_setup_hints${NC}\n"
remote_access_hints
