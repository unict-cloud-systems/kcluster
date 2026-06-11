# shellcheck shell=bash
# Eseguire con "source"

echo -e "${BASH_SOURCE[0]} sourced\n" 1>&2

should_be_bash() {
   echo "It should instead be sourced on the bash:" 1>&2
   echo "     . $1" 1>&2
}

if [[ $0 != "-bash" && $0 != "bash" ]] ; then
   if [[ $ZSH_EVAL_CONTEXT ]] ; then
      echo "This script was sourced on zsh, so failed to reset your environment" 1>&2
      should_be_bash $0
      return
   else
      echo "This script was invoked directly (\$0 is $0)" 1>&2
      should_be_bash $0
      exit
   fi
fi

_scripts_defs_undone=$(grep -l '^TO_BE_SOURCED=1' *.sh | grep -v "$(basename "${BASH_SOURCE[0]}")")

funs_set() {
    /usr/bin/grep -h '^[A-Za-z][A-Za-z0-9+_-]*()' $_scripts_defs_undone | \
    sed 's/().*//'
}

vars_set() {
    /usr/bin/grep -Eh \
      -e '(^|&&) *[A-Za-z_][A-Za-z_0-9]*=' \
      -e '(^|&&) *: .*[$][{][A-Za-z_][A-Za-z_0-9]*:=' \
      $_scripts_defs_undone | grep -v '^ *#' | \
    sed \
        -e 's/.*[$]{\([A-Za-z_][A-Za-z_0-9]*\):=.*/\1/; t' \
        -e 's/^[^&]*&&[[:space:]]*//' \
        -e 's/^[[:space:]]*//' \
        -e 's/\([A-Za-z_][A-Za-z_0-9]*\)=.*/\1/' | \
    sort -u
}

vars_local_set() {
    /usr/bin/grep -h '^ *local' $_scripts_defs_undone | \
    sed -e 's/^ *local //' | cut -d'=' -f1 | \
    sort -u
}
# we do not use vars_local, as of now (locals need not be unset)

export_vars_set() {
    /usr/bin/grep -h '^ *export  *[0-9A-Za-z_]*=' $_scripts_defs_undone | \
    sed -e 's/export//' | tr -d ' ' | cut -d'=' -f1 | \
    sort -u
}

arrays_set() {
    /usr/bin/grep -h '^ *[0-9A-Za-z_]*\[.*\]=' $_scripts_defs_undone | tr -d ' ' | cut -d'[' -f1 | \
    sort -u

}

aliases_set() {
    /usr/bin/grep -h '^ *alias ' $_scripts_defs_undone | \
    sed -e 's/^ *alias //' | \
    cut -d '=' -f1
}

check_items() {
    local items_set="${1}_set"
    for i in $($items_set); do [[ -v "$i" ]] && echo "$i=YES" || echo "$i=NO" ; done
}

_red=$'\033[0;31m'
_nc=$'\033[0m'

# shellcheck disable=SC2046
echo -e "${_red}\n>>>" unsetting functions defined in $_scripts_defs_undone -- ${_nc}$(funs_set)
# shellcheck disable=SC2046
unset -f $(funs_set)
# shellcheck disable=SC2046
echo -e "${_red}\n>>>" unsetting aliases defined in $_scripts_defs_undone -- ${_nc}$(aliases_set)
# shellcheck disable=SC2046
unalias $(aliases_set) 2> /dev/null
# actually above also tries to unset locals
vars_before=$( { vars_set; export_vars_set; arrays_set; } | sort -u)

# shellcheck disable=SC2046
echo -e "${_red}\n>>>" unsetting exported variables defined in $_scripts_defs_undone -- ${_nc}$(export_vars_set)
# shellcheck disable=SC2046
unset $(export_vars_set)
# shellcheck disable=SC2046
echo -e "${_red}\n>>>" unsetting arrays defined in $_scripts_defs_undone -- ${_nc}$(arrays_set)
# shellcheck disable=SC2046
unset $(arrays_set)

# shellcheck disable=SC2046
echo -e "${_red}\n>>>" unsetting variables defined in $_scripts_defs_undone -- ${_nc}$(vars_set)
# shellcheck disable=SC2046
unset $(vars_set)

still_set=$(while IFS= read -r v; do [[ -v $v ]] && echo "$v"; done <<< "$vars_before")
[[ -n "$still_set" ]] && \
    echo -e "${_red}\n>>> WARNING: still set: $still_set${_nc}" || \
    echo -e "${_nc}\n>>> All variables unset OK"
