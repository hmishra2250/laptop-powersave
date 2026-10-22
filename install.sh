#!/usr/bin/env bash
# Install (or remove) the powersave tooling. Safe to run more than once.
set -euo pipefail
cd "$(dirname "$0")"
BEGIN_MARK="# BEGIN powersave"
END_MARK="# END powersave"

# Remove the ~/.profile block this script adds (between the BEGIN and END lines).
remove_profile_block() {
  [[ -f ~/.profile ]] || return 0
  sed -i "/^$BEGIN_MARK\$/,/^$END_MARK\$/d" ~/.profile
}

if [[ ${1:-} == --uninstall ]]; then
  rm -f ~/.local/bin/powersave
  sudo rm -f /usr/local/sbin/powersave-ac /etc/systemd/system/powersave-ac.service \
             /etc/udev/rules.d/99-powersave-ac.rules
  sudo systemctl daemon-reload; sudo udevadm control --reload-rules
  remove_profile_block
  echo "removed (kept /etc/powersave.conf, ~/.local/state/powersave and /var/lib/powersave)"
  [[ -f ~/.config/powersave/workloads ]] && echo "kept your workloads file: ~/.config/powersave/workloads"
  exit 0
fi

mkdir -p ~/.local/bin ~/.local/state/powersave
install -m755 bin/powersave ~/.local/bin/
sudo install -m755 system/powersave-ac /usr/local/sbin/powersave-ac
sudo install -m644 system/powersave-ac.service /etc/systemd/system/
sudo install -m644 system/99-powersave-ac.rules /etc/udev/rules.d/
[[ -f /etc/powersave.conf ]] || sudo install -m644 system/powersave.conf /etc/powersave.conf
# The workloads file is yours once it exists: never overwrite it.
if [[ -f ~/.config/powersave/workloads ]]; then
  echo "kept your ~/.config/powersave/workloads (template: system/workloads.example)"
else
  install -D -m644 system/workloads.example ~/.config/powersave/workloads
  echo "created ~/.config/powersave/workloads from system/workloads.example - edit it to choose what powersave touches"
fi
sudo systemctl daemon-reload
sudo udevadm control --reload-rules

# Replace any earlier copy of the block, so reinstalling never duplicates it.
remove_profile_block
cat >> ~/.profile <<'PROF'
# BEGIN powersave
# If 'powersave go-headless' armed a switch, finish it on console login.
if [ -f "$HOME/.local/state/powersave/pending-headless" ] && [ -z "$DISPLAY" ] && case "$(tty)" in /dev/tty[0-9]*) true;; *) false;; esac; then
    rm -f "$HOME/.local/state/powersave/pending-headless"
    echo "powersave: entering headless mode..."
    "$HOME/.local/bin/powersave" headless
    exec tmux new-session -A -s work
fi
# END powersave
PROF
echo "installed. try: powersave status"
