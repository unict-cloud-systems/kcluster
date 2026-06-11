#!/bin/sh

setup_dir=${SETUP_KUBE_DIR:-setup_kube}
show_tmux_hint=0
login_user=$(logname 2>/dev/null || true)

if [ -n "${SETUP_KUBE_HOME:-}" ]; then
   setup_home=$SETUP_KUBE_HOME
elif [ -n "${PAM_USER:-}" ]; then
   setup_home="/home/$PAM_USER"
elif [ -n "$login_user" ]; then
   setup_home=$(getent passwd "$login_user" 2>/dev/null | cut -d: -f6)
   setup_home=${setup_home:-/home/$login_user}
elif [ -n "${HOME:-}" ]; then
   setup_home=$HOME
else
   setup_home='$HOME'
fi

if [ -n "${SETUP_KUBE_CLEAR_SCREEN:-}" ]; then
   printf '\033[H\033[2J'
fi

if [ -n "${SETUP_KUBE_SHOW_TMUX_HINT:-}" ] || [ -n "${TMUX:-}" ]; then
   show_tmux_hint=1
else
   case "${TERM:-}" in
      *tmux*|screen*) show_tmux_hint=1 ;;
   esac
fi

print_tmux_hint() {
   printf '   - go to the master host pane:          (e.g.) \033[1mCtrl+b q 0\033[0m\n'
   printf '   - move it to a new tmux window:               \033[1mCtrl+b !\033[0m\n'
   printf '   - cycle between multi-ssh and master windows: \033[1mCtrl+b n\033[0m\n'
   printf '   - in the master window:   \033[1m./boot_master.sh\033[0m\n'
   printf '   - in the multi-ssh panes: \033[1m./boot_worker.sh\033[0m\n'
}

if [ -n "${SETUP_KUBE_ONLY_TMUX_HINT:-}" ]; then
   print_tmux_hint
   exit 0
fi

if [ -n "${SETUP_KUBE_UNDER_TMUX_TITLE:-}" ]; then
   printf 'How to run K8s setup scripts: under tmux\n'
else
   printf 'How to run K8s setup scripts: \n'
fi
if [ -z "${SETUP_KUBE_SKIP_ENTER_HINT:-}" ]; then
   printf '   \033[1msudo -i\033[0m\n'
   printf '   \033[1mcd %s/%s\033[0m\n' "$setup_home" "$setup_dir"
fi
if [ -z "${SETUP_KUBE_SKIP_ENTER_HINT:-}" ]; then
   printf '   \033[1m./install_kube.sh\033[0m \033[37mor\033[0m \033[1m./reset_kube.sh\033[0m\n'
fi

if [ "$show_tmux_hint" = 0 ]; then
   printf '   \033[1m./boot_master.sh\033[0m  \033[37mor\033[0m \033[1m./boot_worker.sh\033[0m\n'
fi

if [ "$show_tmux_hint" = 1 ]; then
   print_tmux_hint
fi
