#!/bin/bash
HOME_DIR=""
LOCATION=""
MOUNT_WSL_DRIVES=0
DISABLE_IPV6=0
FORWARD_SSH_AGENT=1
CHECK_CLAUDE_UPDATE=0
EXTRA_MOUNTS=()
EXTRA_PORTS=()
EXTRA_REDIRECTS=()

while [[ "$1" == --home || "$1" == --location || "$1" == --mount-wsl-drives || "$1" == --disable-ipv6 || "$1" == --no-forward-ssh-agent || "$1" == --check-claude-update || "$1" == --mount || "$1" == --port || "$1" == --redirect-port ]]; do
    case "$1" in
        --home)
            HOME_DIR="$2"
            shift 2
            ;;
        --location)
            LOCATION="$2"
            shift 2
            ;;
        --mount-wsl-drives)
            MOUNT_WSL_DRIVES=1
            shift 1
            ;;
        --disable-ipv6)
            DISABLE_IPV6=1
            shift 1
            ;;
        --no-forward-ssh-agent)
            FORWARD_SSH_AGENT=0
            shift 1
            ;;
        --check-claude-update)
            CHECK_CLAUDE_UPDATE=1
            shift 1
            ;;
        --mount)
            EXTRA_MOUNTS+=("$2")
            shift 2
            ;;
        --port)
            EXTRA_PORTS+=("$2")
            shift 2
            ;;
        --redirect-port)
            EXTRA_REDIRECTS+=("$2")
            shift 2
            ;;
    esac
done

USAGE="Usage: $0 --home /path/to/home --location <location_code> [--mount-wsl-drives] [--disable-ipv6] [--no-forward-ssh-agent] [--check-claude-update] [--mount src-path:dst-path ...] [--port [host-ip:]host-port:container-port ...] [--redirect-port local-port:remote-host:remote-port[/tcp|/udp] ...] [command]"

if [[ "$1" == --* ]]; then
    echo "Unknown option: $1" >&2
    echo "$USAGE" >&2
    exit 1
fi

if [[ -z "$HOME_DIR" || -z "$LOCATION" ]]; then
    echo "$USAGE"
    exit 1
fi

mkdir -p "$HOME_DIR"

ADGUARD_CONFIG_DIR="$HOME_DIR/.adguard-vpn-config"
mkdir -p "$ADGUARD_CONFIG_DIR"

MAC_FILE="$HOME_DIR/.container-mac"
if [[ ! -f "$MAC_FILE" ]]; then
    printf '02:%02x:%02x:%02x:%02x:%02x\n' \
        $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) \
        > "$MAC_FILE"
fi
CONTAINER_MAC=$(cat "$MAC_FILE")

if [[ -d /mnt/wslg ]]; then
    # WSL2: WSLg exposes X11/Wayland/PulseAudio sockets under one runtime dir.
    AUDIO_RUNTIME_DIR="/mnt/wslg/runtime-dir"
else
    # Native Linux: sockets live under the desktop session's own XDG runtime dir.
    AUDIO_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
fi

if [[ ! -d "$AUDIO_RUNTIME_DIR" ]]; then
    echo "!! Runtime dir $AUDIO_RUNTIME_DIR not found — audio passthrough will likely fail" >&2
fi

PULSE_SOCKET="unix:${AUDIO_RUNTIME_DIR}/pulse/native"

DRIVE_MOUNTS=()
if [[ "$MOUNT_WSL_DRIVES" -eq 1 ]]; then
    if [[ -d /mnt/wslg ]]; then
        while IFS= read -r drive; do
            DRIVE_MOUNTS+=(-v "$drive:$drive")
        done < <(mount | awk '$3 ~ "^/mnt/[a-z]$" {print $3}')
        if [[ ${#DRIVE_MOUNTS[@]} -eq 0 ]]; then
            echo "!! --mount-wsl-drives: no /mnt/<letter> drives found to mount" >&2
        fi
    else
        echo "!! --mount-wsl-drives ignored: not running under WSL2" >&2
    fi
fi

EXTRA_MOUNT_ARGS=()
for m in "${EXTRA_MOUNTS[@]}"; do
    src="${m%%:*}"
    dst="${m#*:}"
    if [[ -z "$src" || -z "$dst" || "$src" == "$m" ]]; then
        echo "!! --mount '$m' ignored: expected format src-path:dst-path" >&2
        continue
    fi
    if [[ ! -e "$src" ]]; then
        echo "!! --mount: source '$src' does not exist on the host" >&2
    fi
    EXTRA_MOUNT_ARGS+=(-v "$src:$dst")
done

EXTRA_PORT_ARGS=()
for p in "${EXTRA_PORTS[@]}"; do
    if [[ ! "$p" =~ ^([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}:)?[0-9]*:[0-9]+(/(tcp|udp))?$ ]]; then
        echo "!! --port '$p' ignored: expected format [host-ip:]host-port:container-port[/tcp|/udp]" >&2
        continue
    fi
    EXTRA_PORT_ARGS+=(-p "$p")
done

REDIRECT_PORTS=""
REDIRECT_SYSCTLS=()
for r in "${EXTRA_REDIRECTS[@]}"; do
    if [[ ! "$r" =~ ^[0-9]+:[^:/]+:[0-9]+(/(tcp|udp))?$ ]]; then
        echo "!! --redirect-port '$r' ignored: expected format local-port:remote-host:remote-port[/tcp|udp]" >&2
        continue
    fi
    REDIRECT_PORTS+="${r},"
done
if [[ -n "$REDIRECT_PORTS" ]]; then
    # DNAT of a locally-127.0.0.1-addressed connection needs this, or the
    # kernel drops it regardless of the NAT rule (can't be set at runtime
    # inside the container — AppArmor blocks sysctl -w there, must be
    # passed at container creation instead).
    REDIRECT_SYSCTLS=(
        --sysctl net.ipv4.conf.all.route_localnet=1
        --sysctl net.ipv4.conf.default.route_localnet=1
    )
fi

SSH_AGENT_ARGS=()
if [[ "$FORWARD_SSH_AGENT" -eq 1 ]]; then
    if [[ -n "${SSH_AUTH_SOCK:-}" && -S "$SSH_AUTH_SOCK" ]]; then
        SSH_AGENT_ARGS=(-v "$SSH_AUTH_SOCK:$SSH_AUTH_SOCK" -e SSH_AUTH_SOCK="$SSH_AUTH_SOCK")
    else
        echo "!! SSH agent forwarding: \$SSH_AUTH_SOCK not set or not a valid socket on the host — is ssh-agent running? (pass --no-forward-ssh-agent to silence this)" >&2
    fi

    [[ -f "$HOME/.ssh/config" ]] && SSH_AGENT_ARGS+=(-v "$HOME/.ssh/config:/home/claude/.ssh/config:ro")
    [[ -f "$HOME/.ssh/known_hosts" ]] && SSH_AGENT_ARGS+=(-v "$HOME/.ssh/known_hosts:/home/claude/.ssh/known_hosts")
fi

IPV6_SYSCTLS=()
if [[ "$DISABLE_IPV6" -eq 1 ]]; then
    IPV6_SYSCTLS=(
        --sysctl net.ipv6.conf.all.disable_ipv6=1
        --sysctl net.ipv6.conf.default.disable_ipv6=1
    )
fi

if [[ "$CHECK_CLAUDE_UPDATE" -eq 1 ]]; then
    CONTAINER_CMD=(--check-claude-update)
else
    CONTAINER_CMD=("${@:-claude-desktop-unofficial}")
fi

docker run -it --rm \
    --cap-add=NET_ADMIN \
    --device=/dev/net/tun \
    --shm-size=1g \
    --mac-address="$CONTAINER_MAC" \
    --hostname="claude-desktop-vpn-container" \
    "${IPV6_SYSCTLS[@]}" \
    "${REDIRECT_SYSCTLS[@]}" \
    -v "$HOME_DIR:/home/claude" \
    -v "$ADGUARD_CONFIG_DIR:/root/.local/share/adguardvpn-cli" \
    -v /tmp/.X11-unix:/tmp/.X11-unix \
    -v "$AUDIO_RUNTIME_DIR:$AUDIO_RUNTIME_DIR" \
    "${DRIVE_MOUNTS[@]}" \
    "${EXTRA_MOUNT_ARGS[@]}" \
    "${EXTRA_PORT_ARGS[@]}" \
    "${SSH_AGENT_ARGS[@]}" \
    -e DISPLAY="$DISPLAY" \
    -e WAYLAND_DISPLAY="$WAYLAND_DISPLAY" \
    -e XDG_RUNTIME_DIR="$AUDIO_RUNTIME_DIR" \
    -e PULSE_SERVER="$PULSE_SOCKET" \
    -e VPN_LOCATION="$LOCATION" \
    -e PORT_REDIRECTS="$REDIRECT_PORTS" \
    --name claude-desktop-vpn \
    claude-desktop-vpn-container \
    "${CONTAINER_CMD[@]}"
