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

if [ -n "${PORT_REDIRECTS:-}" ]; then
    echo "== Applying port redirects =="
    # Captured now, before adguardvpn-cli installs its own default route
    # via tun0 — a redirect's traffic needs to go out this way instead.
    _default_route_dev=$(ip route show default | head -1 | awk '{for(i=1;i<=NF;i++) if ($i=="dev") print $(i+1)}')
    _default_route_via=$(ip route show default | head -1 | awk '{for(i=1;i<=NF;i++) if ($i=="via") print $(i+1)}')
    _redirect_rule_pref=100
    IFS=',' read -ra _redirects <<< "$PORT_REDIRECTS"
    for r in "${_redirects[@]}"; do
        [ -z "$r" ] && continue
        proto="tcp"
        case "$r" in
            */udp) proto="udp"; r="${r%/udp}" ;;
            */tcp) proto="tcp"; r="${r%/tcp}" ;;
        esac
        local_port="${r%%:*}"
        rest="${r#*:}"
        remote_host="${rest%%:*}"
        remote_port="${rest#*:}"
        echo "  $local_port/$proto -> $remote_host:$remote_port (bypasses VPN)"
        # The filter-table ACCEPT below only decides whether the packet is
        # allowed — routing still decides which interface it goes out on,
        # and AdGuard's AUTO mode installs a full default route via tun0
        # once connected. A specific host route beats that default route
        # regardless of when each was added (longest-prefix-match), so
        # without this the traffic would still physically go through the
        # VPN even though the killswitch happily accepts it.
        if [ -n "$_default_route_dev" ]; then
            if [ -n "$_default_route_via" ]; then
                ip route replace "$remote_host/32" via "$_default_route_via" dev "$_default_route_dev"
            else
                ip route replace "$remote_host/32" dev "$_default_route_dev"
            fi
            # AdGuard's AUTO mode doesn't just set a default route — it uses
            # policy routing (a separate table, consulted via a high-priority
            # ip rule) covering the whole public IP range in large CIDR
            # blocks. The host route above lands in the main table, which is
            # only consulted *after* that rule, so it's never actually
            # reached — the kernel stops at the first rule that matches
            # anything, however broad, rather than picking the overall most
            # specific route across all tables. A rule with a lower pref
            # (= higher priority) than AdGuard's forces main to be checked
            # first for this one destination.
            ip rule add to "$remote_host" lookup main pref "$_redirect_rule_pref" 2>/dev/null
            _redirect_rule_pref=$((_redirect_rule_pref + 1))
        else
            echo "  !! could not determine the pre-VPN default route — this redirect may still go through the VPN" >&2
        fi
        iptables -t nat -A OUTPUT -p "$proto" --dport "$local_port" -j DNAT --to-destination "$remote_host:$remote_port"
        # A connection originally addressed to 127.0.0.1 keeps that as its
        # source unless something rewrites it too — the remote server can't
        # reply to that address, so the handshake never completes even
        # though the initial connect() succeeds. MASQUERADE fixes the
        # source to the container's real outbound address.
        iptables -t nat -A POSTROUTING -p "$proto" -d "$remote_host" --dport "$remote_port" -j MASQUERADE
        # DNAT already rewrote the destination by the time this chain sees
        # the packet, so this only ever matches this specific redirect's
        # traffic — not a blanket VPN bypass.
        iptables -A OUTPUT -p "$proto" -d "$remote_host" --dport "$remote_port" -j ACCEPT
    done
fi

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

echo "== Verifying traffic actually flows through the VPN =="
vpn_ok=0
for i in $(seq 1 5); do
    http_code=$(curl -sS -m 10 -o /tmp/ipapi.json -w '%{http_code}' http://ip-api.com/json 2>/dev/null || true)
    if [ "$http_code" = "200" ] && jq -e . /tmp/ipapi.json >/dev/null 2>&1; then
        echo "== VPN OK: $(jq -r '"\(.query) (\(.city), \(.country))"' /tmp/ipapi.json) =="
        vpn_ok=1
        break
    fi
    echo "  attempt $i/5 failed (http='${http_code:-none}'), retrying..."
    sleep 5
done
rm -f /tmp/ipapi.json
if [ "$vpn_ok" -ne 1 ]; then
    echo "!! tun0 is up but requests to ip-api.com do not return HTTP 200 with valid JSON after 5 attempts — stopping"
    echo "!! Check: docker exec -it claude-desktop-vpn adguardvpn-cli status"
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
