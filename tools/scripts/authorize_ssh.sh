#!/bin/bash
# Copyright 2026 IsaacBot
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Lets this machine ssh into the isaacbot's containers without a password: installs this
# machine's ssh key (~/.ssh/id_ed25519, created if missing) on every SSH-enabled container.
#
#   tools/scripts/authorize_ssh.sh                    192.168.1.201, all containers
#   tools/scripts/authorize_ssh.sh 10.0.0.42          another isaacbot
#   tools/scripts/authorize_ssh.sh 10.0.0.42 24 26    only the orchestrator and vda5050
#
# Logs in with the image password (root, see README "Orchestrator SSH"; override with
# ISAACBOT_AMR_SSH_PASSWORD) and asks for one only where that fails. Containers already
# accepting the key are skipped, so it is safe to run again.
#
# The key lives in each container's /root/.ssh, which a new release (a recreated container)
# forgets; run this again then. A new release also has new ssh host keys: this shows the new
# fingerprint and, once confirmed, forgets the old one.
set -euo pipefail

declare -A CONTAINER=(
    [22]=isaacbot-amr-platform
    [23]=isaacbot-amr-sensors
    [24]=isaacbot-amr-orchestrator
    [25]=isaacbot-amr-drive-interface
    [26]=isaacbot-amr-vda5050
)

case "${1:-}" in
    -h | --help) sed -n '16,29p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac
HOST="${1:-${ISAACBOT_AMR_HOST:-192.168.1.201}}"
shift || true
PORTS=("$@")
[ "${#PORTS[@]}" -gt 0 ] || PORTS=(22 23 24 25 26)
for port in "${PORTS[@]}"; do
    [[ "$port" =~ ^[0-9]+$ ]] || { echo "Not a port: $port" >&2; exit 2; }
done
TARGET="root@$HOST"
KEY="$HOME/.ssh/id_ed25519"
PASSWORD="${ISAACBOT_AMR_SSH_PASSWORD:-root}"

if [ ! -f "$KEY" ]; then
    echo "Creating an ssh key for this machine: $KEY"
    mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
    ssh-keygen -q -t ed25519 -N '' -C "$(id -un)@$(hostname)" -f "$KEY"
fi

# Hands the password to ssh through SSH_ASKPASS, so no sshpass is needed.
ASKPASS="$(mktemp)"
trap 'rm -f "$ASKPASS"' EXIT
chmod 700 "$ASKPASS"
printf '#!/bin/sh\nprintf "%%s\\n" "$ISAACBOT_PASSWORD"\n' > "$ASKPASS"

# known_hosts names port 22 as plain host, any other port as [host]:port.
known_name() { if [ "$1" = 22 ]; then echo "$HOST"; else echo "[$HOST]:$1"; fi; }

authorize() {
    local port="$1" name="${CONTAINER[$1]:-port}" probe answer
    local ssh_opts=(-p "$port" -o ConnectTimeout=10)
    if probe="$(ssh "${ssh_opts[@]}" -o BatchMode=yes "$TARGET" true 2>&1)"; then
        echo "$name ($port): already authorized."
        return 0
    fi
    if grep -q 'REMOTE HOST IDENTIFICATION HAS CHANGED' <<<"$probe"; then
        echo "$name ($port): the ssh host key changed. A new isaacbot release does that. Its keys now:"
        ssh-keyscan -p "$port" "$HOST" 2>/dev/null | ssh-keygen -lf -
        read -r -p "Trust the new key? Only if the isaacbot was just updated or reflashed [y/N] " answer
        [ "$answer" = y ] || [ "$answer" = Y ] || { echo "$name ($port): not changed."; return 1; }
        ssh-keygen -q -R "$(known_name "$port")" >/dev/null
    elif ! grep -qiE 'permission denied|host key verification failed' <<<"$probe"; then
        echo "$name ($port): unreachable: ${probe##*$'\n'}"
        return 1
    fi
    echo "$name ($port): installing this machine's key."
    local copy_opts=(-i "$KEY.pub" "${ssh_opts[@]}" -o StrictHostKeyChecking=accept-new)
    if ! ISAACBOT_PASSWORD="$PASSWORD" SSH_ASKPASS="$ASKPASS" SSH_ASKPASS_REQUIRE=force \
            ssh-copy-id "${copy_opts[@]}" -o NumberOfPasswordPrompts=1 "$TARGET" \
            </dev/null >/dev/null 2>&1; then
        echo "$name ($port): the default password didn't work, enter this container's root password."
        ssh-copy-id "${copy_opts[@]}" "$TARGET" >/dev/null \
            2> >(grep -v '^/usr/bin/ssh-copy-id: INFO' >&2) || return 1
    fi
    ssh "${ssh_opts[@]}" -o BatchMode=yes "$TARGET" true
}

OK=() FAILED=()
for port in "${PORTS[@]}"; do
    if authorize "$port"; then OK+=("$port"); else FAILED+=("$port"); fi
done

echo
if [ "${#OK[@]}" -gt 0 ]; then
    echo "No password needed now:"
    for port in "${OK[@]}"; do
        printf '  ssh -p %-3s %s%s\n' "$port" "$TARGET" "${CONTAINER[$port]:+   # ${CONTAINER[$port]}}"
    done
fi
if [ "${#FAILED[@]}" -gt 0 ]; then
    echo "Failed on port(s): ${FAILED[*]}" >&2
    exit 1
fi
