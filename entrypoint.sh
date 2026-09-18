#!/bin/bash
set -e

if [ "${1:-}" = "--check-claude-update" ]; then
    echo "== Checking for claude-desktop-unofficial updates =="
    if apt-get update -qq -o Acquire::ForceIPv4=true \
        -o Dir::Etc::SourceList=/etc/apt/sources.list.d/claude-desktop-unofficial.list \
        -o Dir::Etc::SourceParts=/dev/null >/dev/null 2>&1; then
        installed_version=$(dpkg-query -W -f='${Version}' claude-desktop-unofficial 2>/dev/null || true)
        candidate_version=$(apt-cache policy claude-desktop-unofficial 2>/dev/null | awk '/Candidate:/ {print $2}')
        if [[ -n "$candidate_version" && "$installed_version" != "$candidate_version" ]]; then
            echo "!! claude-desktop-unofficial is outdated: installed $installed_version, latest $candidate_version"
            echo ""
            echo "To update, rebuild the image with a cache-bust so this step re-runs instead of reusing the cached layer:"
            echo "  docker build --network=host -t claude-desktop-vpn-container \\"
            echo "      --build-arg PUID=\$(id -u) --build-arg PGID=\$(id -g) \\"
            echo "      --build-arg CACHEBUST=\$(date +%s) ."
        else
            echo "== claude-desktop-unofficial is up to date ($installed_version) =="
        fi
    else
        echo "!! Could not check for claude-desktop-unofficial updates (no network) — try again in a moment"
    fi
    exit 0
fi

echo "== Killswitch: blocking everything except lo / root (VPN infra) / tun0 =="
iptables -F OUTPUT
iptables -P OUTPUT DROP
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A OUTPUT -m owner --uid-owner 0 -j ACCEPT
iptables -A OUTPUT -o tun0 -j ACCEPT

echo "== Checking AdGuard login =="
status_output=$(adguardvpn-cli status 2>&1) || true
if printf '%s\n' "$status_output" | grep -qiE \
    'not logged in|authentication required|login required|unauthorized|session expired|invalid session'; then
    echo "== Login not found, starting interactive login =="
    adguardvpn-cli login
fi

if [ -z "$VPN_LOCATION" ]; then
    echo "!! VPN_LOCATION not set, stopping"
    exit 1
fi

echo "== Bringing up VPN =="
adguardvpn-cli connect -l "$VPN_LOCATION" --boot -y

echo "== Waiting for tun0 =="
for i in $(seq 1 30); do
    if ip link show tun0 >/dev/null 2>&1; then
        echo "== tun0 is up =="
        ip link set dev tun0 mtu 1400
        break
    fi
    sleep 1
done

if ! ip link show tun0 >/dev/null 2>&1; then
    echo "!! tun0 did not come up within 30 seconds — network is blocked by the killswitch, stopping"
    echo "!! Check: docker exec -it claude-desktop-vpn adguardvpn-cli status"
    echo "!! And the log: docker exec -it claude-desktop-vpn tail -40 /root/.local/share/adguardvpn-cli/tunnel.log"
    exit 1
fi

export DISPLAY="${DISPLAY:-:0}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
mkdir -p /tmp/runtime-claude
chown claude:claude /tmp/runtime-claude
chmod 700 /tmp/runtime-claude
export XDG_RUNTIME_DIR="/tmp/runtime-claude"

#mkdir -p /home/claude/.local/share/keyrings
#chown -R claude:claude /home/claude/.local/share/keyrings

export PULSE_SERVER="${PULSE_SERVER:-unix:/mnt/wslg/runtime-dir/pulse/native}"

#exec sudo -u claude -H env DISPLAY="$DISPLAY" WAYLAND_DISPLAY="$WAYLAND_DISPLAY" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" PULSE_SERVER="$PULSE_SERVER" "$@"

mkdir -p /home/claude/.local/share/keyrings
chown -R claude:claude /home/claude/.local/share/keyrings

LAUNCHER_CONFIG="/home/claude/.config/claude-desktop-debian/environment"
if [ ! -f "$LAUNCHER_CONFIG" ]; then
    echo "== Setting CLAUDE_PASSWORD_STORE=basic (plain storage, no keyring/D-Bus dependency) =="
    mkdir -p "$(dirname "$LAUNCHER_CONFIG")"
    echo "CLAUDE_PASSWORD_STORE=basic" > "$LAUNCHER_CONFIG"
    chown -R claude:claude /home/claude/.config
fi

echo "== Registering claude:// URL handler (for OAuth/login redirects, e.g. Google sign-in) =="
sudo -u claude XDG_DATA_HOME=/home/claude/.local/share xdg-mime default claude-desktop-unofficial.desktop x-scheme-handler/claude

exec sudo -u claude -H \
    env DISPLAY="$DISPLAY" WAYLAND_DISPLAY="$WAYLAND_DISPLAY" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" PULSE_SERVER="$PULSE_SERVER" SSH_AUTH_SOCK="$SSH_AUTH_SOCK" \
    dbus-run-session -- bash -c '
        eval "$(printf "\n" | gnome-keyring-daemon --unlock --components=secrets,pkcs11)"
        eval "$(printf "\n" | gnome-keyring-daemon --start --components=secrets,pkcs11)"
        export GNOME_KEYRING_CONTROL
        exec "$@"
    ' bash "$@"
