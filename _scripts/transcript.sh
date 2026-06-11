# shellcheck shell=bash

TRANSCRIPT_LEVEL=${K8S_SETUP_TRANSCRIPT:-0}
TRANSCRIPT_TAG=
TRANSCRIPT_SOURCE=
TRANSCRIPT_FILE=
RAW_LOG_FILE=
TRANSCRIPT_SET_VARS_OUTPUT=
TRANSCRIPT_ERROR_REPORTED=0
TRANSCRIPT_RAW_HINT_PRINTED=0
TRANSCRIPT_LAST_LINE=
TRANSCRIPT_STDOUT_FD=1
TRANSCRIPT_STDERR_FD=2
TRANSCRIPT_SCRIPT_NAME=script
TRANSCRIPT_SET_VARS_STDOUT_FD=
TRANSCRIPT_SET_VARS_STDERR_FD=

transcript_init() {
   local source script_name

   if [[ $# -eq 1 ]]; then
      source=${1:?missing transcript source}
      script_name=$(basename "$source")
      TRANSCRIPT_TAG=${script_name%.sh}
      TRANSCRIPT_SOURCE=$source
      TRANSCRIPT_SCRIPT_NAME=$script_name
   elif [[ $# -eq 2 ]]; then
      TRANSCRIPT_TAG=${1:?missing transcript tag}
      TRANSCRIPT_SOURCE=${2:?missing transcript source}
      TRANSCRIPT_SCRIPT_NAME=$(basename "$TRANSCRIPT_SOURCE")
   else
      echo "Usage: transcript_init <script> OR transcript_init <tag> <script>" >&2
      return 1
   fi

   if [[ "$TRANSCRIPT_LEVEL" != 0 && "$TRANSCRIPT_LEVEL" != 1 && "$TRANSCRIPT_LEVEL" != 2 ]]; then
      echo "K8S_SETUP_TRANSCRIPT must be 0, 1, or 2" >&2
      return 1
   fi
}

transcript_boot_init() {
   transcript_init "${1:?missing script source}" || return 1

   if [[ ! -f ./set_vars.sh ]]; then
      echo "set_vars.sh not found -- run upload_kcluster_setup.sh -y from the client first" >&2
      return 1
   fi

   if [[ "$TRANSCRIPT_LEVEL" -eq 2 ]]; then
      TRANSCRIPT_SET_VARS_OUTPUT=$(mktemp /tmp/k8s-setup-set-vars.XXXXXX)
      exec {TRANSCRIPT_SET_VARS_STDOUT_FD}>&1
      exec {TRANSCRIPT_SET_VARS_STDERR_FD}>&2
      exec >"$TRANSCRIPT_SET_VARS_OUTPUT" 2>&1
   fi
}

transcript_boot_ready() {
   local status=${1:-0}

   if [[ "$TRANSCRIPT_LEVEL" -eq 2 && -n "$TRANSCRIPT_SET_VARS_OUTPUT" ]]; then
      exec >&"$TRANSCRIPT_SET_VARS_STDOUT_FD" 2>&"$TRANSCRIPT_SET_VARS_STDERR_FD"
      exec {TRANSCRIPT_SET_VARS_STDOUT_FD}>&-
      exec {TRANSCRIPT_SET_VARS_STDERR_FD}>&-
      TRANSCRIPT_SET_VARS_STDOUT_FD=
      TRANSCRIPT_SET_VARS_STDERR_FD=

      if [[ "$status" -ne 0 ]]; then
         cat "$TRANSCRIPT_SET_VARS_OUTPUT" >&2
         rm -f "$TRANSCRIPT_SET_VARS_OUTPUT"
         TRANSCRIPT_SET_VARS_OUTPUT=
         return "$status"
      fi
   elif [[ "$status" -ne 0 ]]; then
      echo "Failed to source set_vars.sh -- check for errors in that file" >&2
      return 1
   fi

   # set -e + pipefail: any failure exits via the trap below (line number shown).
   # Add explicit '|| { echo ...; exit 1; }' only for critical failures that need context.
   # Use '|| true' for non-critical steps that must not abort the script.
   set -e -o pipefail
   trap 'transcript_on_error "$LINENO" "$TRANSCRIPT_SCRIPT_NAME"' ERR
   trap 'transcript_on_exit "$?" "$TRANSCRIPT_SCRIPT_NAME"' EXIT
}

transcript_trim() {
   local s=$1
   s=${s#"${s%%[![:space:]]*}"}
   s=${s%"${s##*[![:space:]]}"}
   printf '%s' "$s"
}

transcript_trim_right() {
   local s=$1
   s=${s%"${s##*[![:space:]]}"}
   printf '%s' "$s"
}

transcript_expand_vars() {
   local rest=$1
   local out=
   local token prefix var

   while [[ "$rest" =~ (\$\{[A-Za-z_][A-Za-z0-9_]*\}|\$[A-Za-z_][A-Za-z0-9_]*) ]]; do
      token=${BASH_REMATCH[1]}
      prefix=${rest%%"$token"*}
      out+=$prefix

      if [[ "$token" == \${* ]]; then
         var=${token#'${'}
         var=${var%'}'}
      else
         var=${token#'$'}
      fi

      if [[ ${!var+x} ]]; then
         out+=${!var}
      else
         out+=$token
      fi

      rest=${rest#*"$token"}
   done

   printf '%s' "$out$rest"
}

transcript_render_cmd() {
   local cmd=$1

   cmd=$(transcript_expand_vars "$cmd")
   if [[ "$cmd" =~ ^if[[:space:]]+![[:space:]]+(.+)\;[[:space:]]*then$ ]]; then
      cmd=${BASH_REMATCH[1]}
   fi

   # `|| true` is script control flow, not part of the admin-facing transcript.
   cmd=$(transcript_trim_right "$cmd")
   cmd=${cmd% || true}
   transcript_trim_right "$cmd"
}

transcript_emit_terminal() {
   local line=$1

   if [[ "$line" == \#* ]]; then
      printf '%s%s%s\n' "${GREEN:-}" "$line" "${NC:-}" >&"$TRANSCRIPT_STDOUT_FD"
   elif [[ "$line" == *" #"* ]]; then
      local before_comment=${line%% #*}
      local comment=${line#"$before_comment"}
      printf '%s%s%s%s\n' "$before_comment" "${GREEN:-}" "$comment" "${NC:-}" >&"$TRANSCRIPT_STDOUT_FD"
   else
      printf '%s\n' "$line" >&"$TRANSCRIPT_STDOUT_FD"
   fi
}

transcript_line() {
   local line=$1

   [[ "$TRANSCRIPT_LEVEL" -ge 1 ]] || return 0
   if [[ "$line" == \#* && -n "$TRANSCRIPT_LAST_LINE" && "$TRANSCRIPT_LAST_LINE" != \#* ]]; then
      printf '\n' >> "$TRANSCRIPT_FILE"
      [[ "$TRANSCRIPT_LEVEL" -eq 2 ]] && printf '\n' >&"$TRANSCRIPT_STDOUT_FD"
   fi
   printf '%s\n' "$line" >> "$TRANSCRIPT_FILE"
   [[ "$TRANSCRIPT_LEVEL" -eq 2 ]] && transcript_emit_terminal "$line"
   TRANSCRIPT_LAST_LINE=$line
   return 0
}

transcript_raw_output_hint() {
   [[ "$TRANSCRIPT_LEVEL" -eq 2 ]] || return 0
   [[ "$TRANSCRIPT_RAW_HINT_PRINTED" -eq 0 ]] || return 0
   transcript_line "# Raw command output: $RAW_LOG_FILE"
   TRANSCRIPT_RAW_HINT_PRINTED=1
}

transcript_from_source() {
   local line cmd note rendered

   while IFS= read -r line; do
      if [[ "$line" =~ ^[[:space:]]*#@[[:space:]]?(.*)$ ]]; then
         note=${BASH_REMATCH[1]}
         if [[ -z "$note" ]]; then
            transcript_line ""
         elif [[ "$note" =~ ^(sudo|cd|systemctl|rm|export|rsync|cp|sed|bash|kubectl|kubeadm)[[:space:]] ]]; then
            transcript_line "$(transcript_expand_vars "$note")"
         else
            transcript_line "# $note"
         fi
      elif [[ "$line" == *"#@"* ]]; then
         cmd=${line%%#@*}
         note=${line#*#@}
         cmd=$(transcript_trim "$cmd")
         note=$(transcript_trim "$note")
         rendered=$(transcript_render_cmd "$cmd")

         if [[ -n "$note" ]]; then
            transcript_line "$rendered  # $note"
         else
            transcript_line "$rendered"
         fi
      fi
   done < "$TRANSCRIPT_SOURCE"

   return 0
}

transcript_start() {
   [[ "$TRANSCRIPT_LEVEL" -ge 1 ]] || return 0

   TRANSCRIPT_FILE=${K8S_SETUP_TRANSCRIPT_FILE:-/root/k8s-setup-${THISNODE}-${TRANSCRIPT_TAG}.transcript}
   RAW_LOG_FILE=${K8S_SETUP_RAW_LOG_FILE:-/root/k8s-setup-${THISNODE}-${TRANSCRIPT_TAG}.raw.log}

   : > "$TRANSCRIPT_FILE"
   chmod 600 "$TRANSCRIPT_FILE"

   if [[ "$TRANSCRIPT_LEVEL" -eq 2 ]]; then
      : > "$RAW_LOG_FILE"
      chmod 600 "$RAW_LOG_FILE"
      if [[ -n "$TRANSCRIPT_SET_VARS_OUTPUT" ]]; then
         if [[ -s "$TRANSCRIPT_SET_VARS_OUTPUT" ]]; then
            printf '# set_vars.sh output\n' >> "$RAW_LOG_FILE"
            cat "$TRANSCRIPT_SET_VARS_OUTPUT" >> "$RAW_LOG_FILE"
            printf '\n' >> "$RAW_LOG_FILE"
         fi
         rm -f "$TRANSCRIPT_SET_VARS_OUTPUT"
         TRANSCRIPT_SET_VARS_OUTPUT=
      fi
      exec {TRANSCRIPT_STDOUT_FD}>&1
      exec {TRANSCRIPT_STDERR_FD}>&2
      exec >>"$RAW_LOG_FILE" 2>&1
   fi

   transcript_line "# ${TRANSCRIPT_TAG} transcript for node $THISNODE"
   transcript_line "# generated: $(date -Is)"
   transcript_line "# setup directory: $PWD"
   transcript_line ""
   transcript_from_source
   transcript_raw_output_hint
   transcript_line ""
   return 0
}

transcript_on_error() {
   local line=$1
   local script_name=${2:-script}

   TRANSCRIPT_ERROR_REPORTED=1

   if [[ "$TRANSCRIPT_LEVEL" -ge 1 ]]; then
      transcript_line "ERROR: $script_name failed on line $line"
      transcript_raw_output_hint
   fi

   if [[ "$TRANSCRIPT_LEVEL" -eq 2 ]]; then
      echo -e "${BOLDRED:-}$script_name: error on line $line, exiting${NC:-}" >&"$TRANSCRIPT_STDERR_FD"
      echo -e "${RED:-}Transcript: $TRANSCRIPT_FILE${NC:-}" >&"$TRANSCRIPT_STDERR_FD"
      echo -e "${RED:-}Raw output:  $RAW_LOG_FILE${NC:-}" >&"$TRANSCRIPT_STDERR_FD"
   else
      echo -e "${BOLDRED:-}$script_name: error on line $line, exiting${NC:-}" >&2
   fi
}

transcript_on_exit() {
   local status=$1
   local script_name=${2:-script}

   [[ "$status" -ne 0 ]] || return 0
   [[ "$TRANSCRIPT_ERROR_REPORTED" -eq 0 ]] || return 0

   if [[ "$TRANSCRIPT_LEVEL" -ge 1 ]]; then
      transcript_line "ERROR: $script_name exited with status $status"
      transcript_raw_output_hint
   fi

   if [[ "$TRANSCRIPT_LEVEL" -eq 2 ]]; then
      echo -e "${BOLDRED:-}$script_name: exited with status $status${NC:-}" >&"$TRANSCRIPT_STDERR_FD"
      echo -e "${RED:-}Transcript: $TRANSCRIPT_FILE${NC:-}" >&"$TRANSCRIPT_STDERR_FD"
      echo -e "${RED:-}Raw output:  $RAW_LOG_FILE${NC:-}" >&"$TRANSCRIPT_STDERR_FD"
   fi
}
