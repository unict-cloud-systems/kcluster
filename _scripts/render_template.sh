#!/usr/bin/env bash

set -e -o pipefail

usage() {
   echo "Usage:" >&2
   echo "  $0 --cloud-init [--pubkey-file <file>] [--kuser <user>] [--base-setup-dir <dir>] [--output <file>]" >&2
   echo "  $0 --motd [--output <file>]" >&2
   echo "  $0 --calico [--pod-network-cidr <cidr>] [--output <file>]" >&2
   echo "  $0 --flannel [--pod-network-cidr <cidr>] [--output <file>]" >&2
   echo "  $0 --file <template> [--var NAME=value ...] [--output <file>]" >&2
}

script_dir=$(builtin cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && command pwd -P)
project_dir=$(builtin cd "$(dirname "$script_dir")" >/dev/null && command pwd -P)
cloud_config="$project_dir/_templates/cloud_init.yaml"
inputrc_template="$project_dir/_templates/cloud_init.inputrc"
motd_template="$project_dir/_templates/cloud_init.motd.sh"
netplan_script_template="$project_dir/_templates/setup-kube-netplan.sh"
calico_template="$project_dir/_templates/calico.yaml"
flannel_template="$project_dir/_templates/flannel.yml"

mode=file
template_file=""
pubkey_file=""
kuser=""
base_setup_dir=""
pod_network_cidr=""
output=""
vars=()
loaded_set_vars=0
render_nodes=""
render_khosts_network=""
render_khosts_cases_text=""

while [[ $# -gt 0 ]]; do
   case "$1" in
      --cloud-init) mode=cloud_init ;;
      --motd) mode=motd ;;
      --calico) mode=calico ;;
      --flannel) mode=flannel ;;
      --file) shift; mode=file; template_file=$1 ;;
      --var) shift; vars+=("$1") ;;
      --pubkey-file) shift; pubkey_file=$1 ;;
      --kuser) shift; kuser=$1 ;;
      --base-setup-dir) shift; base_setup_dir=$1 ;;
      --pod-network-cidr) shift; pod_network_cidr=$1 ;;
      --output) shift; output=$1 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
   esac
   shift
done

sed_escape() {
   printf '%s' "$1" | sed 's/[&|\\]/\\&/g'
}

load_set_vars_defaults() {
   [[ $loaded_set_vars -eq 0 ]] || return 0
   [[ -f "$project_dir/set_vars.sh" ]] || return 0

   local old_pwd
   old_pwd=$PWD
   builtin cd "$project_dir" >/dev/null
   if ! source ./set_vars.sh >/dev/null 2>/dev/null ; then
      builtin cd "$old_pwd" >/dev/null
      echo "Failed to source $project_dir/set_vars.sh" >&2
      exit 1
   fi
   builtin cd "$old_pwd" >/dev/null

   kuser=${kuser:-${KUSER:-}}
   base_setup_dir=${base_setup_dir:-${BASESETUPDIR:-}}
   pubkey_file=${pubkey_file:-${KEYFILE:+${KEYFILE}.pub}}
   pod_network_cidr=${pod_network_cidr:-${POD_NETWORK_CIDR:-}}
   render_nodes=$NODES
   render_khosts_network=$KHOSTS_NETWORK
   render_khosts_cases_text=""
   local n
   for n in $NODES; do
      render_khosts_cases_text="${render_khosts_cases_text}   $n) node_ip='${KHOSTS["$n"]}' ;;
"
   done
   loaded_set_vars=1
}

render_file_template() {
   [[ -n "$template_file" ]] || { echo "Missing --file <template>" >&2; exit 1; }
   [[ -f "$template_file" ]] || { echo "Missing $template_file" >&2; exit 1; }

   local -a sed_args
   local var name value
   sed_args=()
   for var in "${vars[@]}"; do
      [[ "$var" == *=* ]] || { echo "Invalid --var '$var' (expected NAME=value)" >&2; exit 1; }
      name=${var%%=*}
      value=${var#*=}
      [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { echo "Invalid variable name '$name'" >&2; exit 1; }
      sed_args+=(-e "s|__${name}__|$(sed_escape "$value")|g")
   done

   if [[ ${#sed_args[@]} -gt 0 ]]; then
      sed "${sed_args[@]}" "$template_file"
   else
      cat "$template_file"
   fi
}

indent_yaml_content() {
   sed 's/^/      /' "$1"
}

render_text_template() {
   local file=$1
   local -a sed_args
   sed_args=(
      -e "s|__KUSER__|$(sed_escape "$kuser")|g"
      -e "s|__BASESETUPDIR__|$(sed_escape "$base_setup_dir")|g"
   )
   sed "${sed_args[@]}" "$file"
}

render_netplan_script() {
   local tmp_cases

   tmp_cases=$(mktemp)
   printf '%s' "$render_khosts_cases_text" > "$tmp_cases"
   while IFS= read -r line || [[ -n "$line" ]]; do
      case "$line" in
         __KHOSTS_CASES__) cat "$tmp_cases" ;;
         *) printf '%s\n' "$line" ;;
      esac
   done < "$netplan_script_template" | sed \
      -e "s|__KHOSTS_PREFIXLEN__|$(sed_escape "${render_khosts_network#*/}")|g"
   rm -f "$tmp_cases"
}

render_motd() {
   [[ -f "$motd_template" ]] || { echo "Missing $motd_template" >&2; exit 1; }
   cat "$motd_template"
}

render_cloud_init_template() {
   load_set_vars_defaults
   [[ -n "$pubkey_file" && -n "$kuser" && -n "$base_setup_dir" ]] || {
      echo "Missing --pubkey-file, --kuser, or --base-setup-dir" >&2
      exit 1
   }
   [[ -f "$cloud_config" ]] || { echo "Missing $cloud_config" >&2; exit 1; }
   [[ -f "$inputrc_template" ]] || { echo "Missing $inputrc_template" >&2; exit 1; }
   [[ -f "$motd_template" ]] || { echo "Missing $motd_template" >&2; exit 1; }
   [[ -f "$netplan_script_template" ]] || { echo "Missing $netplan_script_template" >&2; exit 1; }
   [[ -r "$pubkey_file" ]] || { echo "Cannot read $pubkey_file" >&2; exit 1; }

   local pubkey tmp_motd tmp_netplan
   pubkey=$(cat "$pubkey_file")
   tmp_motd=$(mktemp)
   tmp_netplan=$(mktemp)
   render_text_template "$motd_template" > "$tmp_motd"
   render_netplan_script > "$tmp_netplan"

   while IFS= read -r line || [[ -n "$line" ]]; do
      case "$line" in
         __INPUTRC_CONTENT__) indent_yaml_content "$inputrc_template" ;;
         __MOTD_CONTENT__) indent_yaml_content "$tmp_motd" ;;
         __NETPLAN_SCRIPT_CONTENT__) indent_yaml_content "$tmp_netplan" ;;
         *) printf '%s\n' "$line" ;;
      esac
   done < "$cloud_config" | sed \
      -e "s|__PUBKEY__|$(sed_escape "$pubkey")|g" \
      -e "s|__KUSER__|$(sed_escape "$kuser")|g" \
      -e "s|__BASESETUPDIR__|$(sed_escape "$base_setup_dir")|g"

   rm -f "$tmp_motd" "$tmp_netplan"
}

render_calico() {
   load_set_vars_defaults
   [[ -n "$pod_network_cidr" ]] || { echo "Missing --pod-network-cidr" >&2; exit 1; }
   [[ -f "$calico_template" ]] || { echo "Missing $calico_template" >&2; exit 1; }

   sed -e "/ *- name: CALICO_IPV4POOL_CIDR/ {
N;s|\([[:space:]]*value:[[:space:]]*\)\"\([0-9.]*\/[[:digit:]][[:digit:]]\)\"|\1\"$(sed_escape "$pod_network_cidr")\"|
}" -e 's/# - name: CALICO_IPV4POOL_CIDR/- name: CALICO_IPV4POOL_CIDR/' \
      -e "s+#   value: \"[0-9.]*/[0-9]*\"+  value: \"$(sed_escape "$pod_network_cidr")\"+" \
      "$calico_template"
}

render_flannel() {
   load_set_vars_defaults
   [[ -n "$pod_network_cidr" ]] || { echo "Missing --pod-network-cidr" >&2; exit 1; }
   [[ -f "$flannel_template" ]] || { echo "Missing $flannel_template" >&2; exit 1; }

   sed -e "s|\"Network\": \"[0-9.]*/[0-9]*\"|\"Network\": \"$(sed_escape "$pod_network_cidr")\"|" \
      "$flannel_template"
}

if [[ "$mode" == "motd" ]]; then
   if [[ -n "$output" ]]; then
      render_motd > "$output"
   else
      render_motd
   fi
elif [[ "$mode" == "cloud_init" ]]; then
   if [[ -n "$output" ]]; then
      render_cloud_init_template > "$output"
   else
      render_cloud_init_template
   fi
elif [[ "$mode" == "calico" ]]; then
   if [[ -n "$output" ]]; then
      render_calico > "$output"
   else
      render_calico
   fi
elif [[ "$mode" == "flannel" ]]; then
   if [[ -n "$output" ]]; then
      render_flannel > "$output"
   else
      render_flannel
   fi
else
   if [[ -n "$output" ]]; then
      render_file_template > "$output"
   else
      render_file_template
   fi
fi
