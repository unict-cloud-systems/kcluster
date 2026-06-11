# shellcheck shell=bash
TO_BE_SOURCED=1
# Includere questo script in altri con "source"
# Per debugging si puo' eseguire con "source" anche direttamente da bash

# determina non via sourcing di config.sh, ma *calcolandole*, le variabili
##BASENAME|CRI_RUNTIMES|NODES0|NODES|KHOSTIPS0|KHOSTIPS|UNIXNAME|MYIPS|\
##THISNODE|THISIP|THISINDEX|EGREP|FGREP|GREP|SETUPDIR|BASESETUPDIR|\
##LOCALIP|LOCALNETINTFC|MYPUBIP|KHOME
# se se ne definiscono di nuove, conviene aggiungerle all'elenco qui sopra

get_my_vars() {
   grep '^##' ${BASH_SOURCE[0]} | \
   sed -e 's/##//g' -e 's/\\//g' | \
   tr -d '\n'
   echo
}

. ./_scripts/colors.sh

BASENAME=$0
if [[ $0 != "-bash" && $0 != "bash" ]] ; then
BASENAME=$(basename $0)
fi

if [[ ("$BASENAME" != "upload_kcluster_setup.sh") && ("$BASENAME" != "render_template.sh") && ("$BASENAME" != "prova.sh")  &&  ("$BASENAME" != "-bash") && ("$BASENAME" != "bash")  && \
      ( "$0" != ./aws_kcluster_* ) && ( "$0" != ./mp_* ) ]] ; then
if [ "$EUID" -ne 0 ] ; then
   echo -e "${BOLDRED}Please run as root$NC (BASENAME==$BASENAME, \$0==$0)" 1>&2
   exit 1
fi
fi

if [[ "$BASENAME" == "upload_kcluster_setup.sh" || "$BASENAME" == "prova.sh" || "$BASENAME" == "prova" ]] ; then
if [ "$EUID" -eq 0 ] ; then
   echo -e "${BOLDRED}Please do not run as root$NC" 1>&2
   exit 1
fi
fi

PROMPT_SRC="${RED}[$(basename ${BASH_SOURCE[0]})"
[[ ${#BASH_SOURCE[@]} == 1 ]] && \
PROMPT_SRC="$PROMPT_SRC $*"
PROMPT_SRC="$PROMPT_SRC @$(hostname)]${NC}"

# debug
#echo -e $PROMPT_SRC
#echo jumping out of set_vars.sh early
#return
#end debug

#if [[ $0 == -bash || $0 == bash ]] ; then
# Direi seempre utile
echo -e "$PROMPT_SRC ${IT}${BASH_SOURCE[0]}${NOIT} sourced" 1>&2
#fi

if [[ $OSTYPE == 'darwin'* ]]; then
EGREP="/usr/bin/egrep"
FGREP="/usr/bin/fgrep"
GREP="/usr/bin/grep"
else
EGREP="egrep"
FGREP="fgrep"
GREP="grep"
fi

CONF_VARS=$($EGREP -e '^[A-Za-z][A-Za-z0-9_]*=' ./config.sh | cut -d'=' -f1 | tr '\n' ' ')

# clear variables defined in config.sh

unset KHOSTS
declare -A KHOSTS
unset -v $CONF_VARS KEYFILE
CRI_RUNTIMES="containerd crio"

source ./config.sh
echo -ne "\n$PROMPT_SRC Variabili lette in config.sh: "
echo -e $CONF_VARS
unset KEYFILE_DEFINED_IN
# prossima smart, quando set_vars.sh faceva da backup se config.sh non definiva KEYFILE, ma era contorto
#KEYFILE_DEFINED_IN=$(test -n "$KEYFILE" && echo "config.sh" || echo ${BASH_SOURCE[0]})
KEYFILE_DEFINED_IN="config.sh"
echo -n "KEYFILE=" ; test -n "$KEYFILE" && echo $KEYFILE || echo '<NOT SET IN config.sh>'

NODES0="${!KHOSTS[*]}"
NODES=$(echo $NODES0 | xargs -n1 | sort -V | xargs)
# sort -V mette (p. es.) s9 prima di s10
NODE_ARR=($NODES)

KHOSTIPS0="${KHOSTS[*]}"
KHOSTIPS=$(echo $KHOSTIPS0 | xargs -n1 | sort -V | xargs)

# KNAMES is KHOSTS inverted
unset KNAMES
unset KINDEX
declare -A KNAMES
declare -A KINDEX

build_names_indexes() {
   local i
   i=0
   for N in ${NODES}; do
      IPN=${KHOSTS[$N]}
      KNAMES[$IPN]=$N
      KINDEX[$N]=$i
      let i+=1
   done
}

build_names_indexes

UNIXNAME=$( uname -s )
if [[ "$UNIXNAME" == @(Linux|GNU|GNU/*) ]]; then
MYIPS=$(hostname -I)
elif [[ "$UNIXNAME" =~ "MINGW" ]]; then
MYIPS=$(ipconfig //all | grep -B4 'Default Gateway.*: .' | head -1 | cut -d':' -f2 | tr -dc 0-9.)
else
MYIPS=$(for name in $(/sbin/ifconfig -l) ; do \
   /sbin/ifconfig $name | awk -v name=$name '/inet / {printf "%s ", $2; }'; \
done)
fi

THISNODE=none
THISIP=none
THISINDEX=none
for N in ${NODES}; do
   IPN=${KHOSTS[$N]}
   INDXN=${KINDEX[$N]}
   for A in $MYIPS; do
      if [[ "$IPN" == "$A" ]]; then
         THISNODE=$N
         THISIP=$IPN
         THISINDEX=$INDXN
         break 2
      fi
   done
done

# su ogni host, troviamo l'IP dell'host stesso
#THISIP=$(grep ${THISHOST} /etc/hosts | grep -v 127.0. | cut -f1 -d' ')

SETUPDIR=$(pwd)
BASESETUPDIR=$(basename $SETUPDIR)
if [[ "$UNIXNAME" =~ "MINGW" ]]; then
LOCALIP=$MYIPS
else
LOCALNETINTFC=$(ip route | grep default | head -1 | cut -d' ' -f5)
LOCALIP=$(ip addr show dev $LOCALNETINTFC | $EGREP '^[[:blank:]]*inet ' | tr -dc '0-9. /' | tr -s ' ' | cut -d' ' -f 2)
LOCALIP=${LOCALIP/\/[0-9]*/}
fi
echo -ne "\n$PROMPT_SRC "

if [[ "$THISNODE" == "none" ]] ; then
   : ${MYPUBIP:=$(curl -s --max-time 2 https://ipinfo.io/ip)}
   printf "Questo cliente ($(hostname) - $LOCALIP - $MYPUBIP) non e\` \ndestinato a essere un nodo del cluster composto da:\n[%s] / [%s]\ne definito in ./config.sh\n" "${NODES// /,}" "${KHOSTIPS// /,}"
else
   printf "Questo host e\` il nodo %s (IP %s) del cluster definito in $SETUPDIR/config.sh\n" "$THISNODE" "$THISIP"
fi

# Color rotation per node -- skips Black(30) Red(31) Green(32) White(37)
# Green(32) reserved for key-action highlighting (see TODO)
# Blue Magenta Cyan Yellow; wraps if nodes > 4
KCOLORS=(34 35 36 33)

if [[ $THISNODE != none ]] ; then
   KCOLOR=${KCOLORS[$THISINDEX % ${#KCOLORS[@]}]}
   RED="\033[0;${KCOLOR}m"
fi

unset KRED KBRED
declare -A KRED KBRED
for N in ${NODES}; do
   NCOLOR=${KCOLORS[${KINDEX[$N]} % ${#KCOLORS[@]}]}
   KRED[$N]="\033[0;${NCOLOR}m"
   KBRED[$N]="\033[1;${NCOLOR}m"   # bold variant (attribute 1)
done

if [[ $THISNODE != none ]]; then
KHOME=/home/$KUSER
else
KHOME=$HOME
fi

echo -e "\n$PROMPT_SRC Variabili principali qui determinate (definite nella tua shell):"
echo 'CRI_RUNTIMES
NODES / KHOSTIPS / MYIPS
THISNODE THISIP THISINDEX
SETUPDIR BASESETUPDIR KHOME
LOCALIP LOCALNETINTFC MYPUBIP'

echo -e "\n$PROMPT_SRC Variabili ${BOLD}fondamentali$NC per questi script da ${IT}config.sh${NC}: "

# KEYFILE must be set in config.sh; both private and .pub must exist locally.
keyfile_unset=""
if [[ -z "$KEYFILE" ]]; then
   echo -e "${BOLDRED}KEYFILE   # not set in config.sh -- please set it to a project-local SSH private key${NC}" 1>&2
elif [[ ! -f "$KEYFILE" || ! -f "${KEYFILE}.pub" ]]; then
   echo -e "${BOLDRED}KEYFILE=$KEYFILE   # definition in ${IT}config.sh${NOIT}, file ${KEYFILE}[.pub] not found, ignoring it${NC}" 1>&2
   echo -e "Provide files or generate them with: \n${IT}ssh-keygen -t rsa -N '' -C 'k8s' -f $KEYFILE${NOIT}\n" 1>&2
   keyfile_unset="${BOLDRED}<SET TO NULL>${NC}${RED} --- anche se "
   KEYFILE=""   # signal "no key" to downstream
fi

# if KEYFILE is defined and exists, print it
if [[ -n "$KEYFILE" ]]; then
   KEYFILE_LINE="KEYFILE=$KEYFILE"
   echo -e "$KEYFILE_LINE  ${RED}# ${keyfile_unset}definito in $NC$IT$KEYFILE_DEFINED_IN$NC$RED -- contiene la $NC"
   echo -e "${KEYFILE_LINE//?/ }  ${RED}# chiave ssh per accesso agli host del cluster$NC"
fi

# if KUSER is defined, print it
if [[ -z "$KUSER" ]]; then
   echo -e "${BOLDRED}KUSER     # not set in config.sh -- please set it to a remote user account${NC}" 1>&2
   KUSER=""   # signal "no user" to downstream
else
   KUSER_LINE="KUSER=$KUSER"
   echo -e "$KUSER_LINE  ${RED}# definito in ${NC}${IT}config.sh$NC$RED -- utente previsto sui nodi del cluster$NC"
fi

if [[ "z$KUSER" == "zubuntu" ]] ; then
   echo -e "${KUSER_LINE//?/ }  ${RED}# NB: ${NC}$IT$KUSER${NOIT}${RED} is the target user on the cluster nodes.$NC"
   echo -e "${KUSER_LINE//?/ }  ${RED}# OK if this is intended and that user exists on them$NC"
fi

# CONTAINER_RUNTIME must be set in config.sh (containerd or crio)
if [[ -z "$CONTAINER_RUNTIME" ]]; then
   echo -e "${BOLDRED}CONTAINER_RUNTIME   # not set in config.sh -- set to 'containerd' or 'crio'${NC}" 1>&2
elif [[ "$CONTAINER_RUNTIME" != "containerd" && "$CONTAINER_RUNTIME" != "crio" ]]; then
   echo -e "${BOLDRED}CONTAINER_RUNTIME=$CONTAINER_RUNTIME   # unknown value -- expected 'containerd' or 'crio'${NC}" 1>&2
fi

# KHOSTS_NETWORK must be set in config.sh (cluster subnet).
# With Multipass these IPs are configured as aliases on the VM primary NIC.
# The client host needs a route to this subnet through the Multipass bridge.
if [[ -z "$KHOSTS_NETWORK" ]]; then
   echo -e "${BOLDRED}KHOSTS_NETWORK   # not set in config.sh -- needed for cluster subnet (e.g. 192.168.55.0/24)${NC}" 1>&2
else
   # Verify every KHOSTS[] IP falls within KHOSTS_NETWORK
   _knet="${KHOSTS_NETWORK%/*}" _kpfx="${KHOSTS_NETWORK#*/}"
   _kmask=$(( (0xFFFFFFFF << (32 - _kpfx)) & 0xFFFFFFFF ))
   { IFS=. read -r _a _b _c _d <<< "$_knet"; }
   _knet_int=$(( (_a<<24) + (_b<<16) + (_c<<8) + _d ))
   for N in ${NODES}; do
      { IFS=. read -r _a _b _c _d <<< "${KHOSTS[$N]}"; }
      _hip=$(( (_a<<24) + (_b<<16) + (_c<<8) + _d ))
      if (( (_hip & _kmask) != (_knet_int & _kmask) )); then
         echo -e "${BOLDRED}KHOSTS[$N]=${KHOSTS[$N]} non appartiene a KHOSTS_NETWORK=$KHOSTS_NETWORK${NC}" 1>&2
      fi
   done
   unset _knet _kpfx _kmask _knet_int _a _b _c _d _hip
fi

# Update /etc/hosts file with cluster node entries

update_etc_hosts() {
  sed -i '/# inserted by/d' /etc/hosts
  for N in ${NODES}; do
    HOSTIP=${KHOSTS[$N]//./\\.}
  # NN="[[:space:]]+$N([[:space:]]+|$)"
  # precedente impreciso
    NN=".*$N.*"
    HOSTLINE="^${HOSTIP}[[:space:]]"
    if ! grep -q -e "$HOSTLINE$NN" /etc/hosts ; then
  # if ! host $N 127.0.0.53 >/dev/null ; then
      printf "%s\t%s\t# inserted by %s\n" ${KHOSTS[$N]} $N $0 >> /etc/hosts
      printf "${RED}%s (${KHOSTS[$N]}) just inserted into /etc/hosts${NC}\n" $N
    else
      printf "${RED}%s (${KHOSTS[$N]}) already in /etc/hosts${NC}\n" $N
  #   printf "${RED}% at lines:${NC}\n"
  #   $EGREP -nT -e "$NN" /etc/hosts
    fi
  done
}

echo -e "\n$PROMPT_SRC finito\n"

# se questo script set_vars.sh e' stato sourced direttamente (come in 
# set_env.sh) e non dentro un altro script, con il trucco sotto 
# si può eseguire questo script con un argomento nome di
# funzione, p. es. update_etc_hosts (come in set_env.sh)

if [[ ${#BASH_SOURCE[@]} == 1 ]] ; then
   "$@"
fi
