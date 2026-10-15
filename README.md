# Claude Desktop in a VPN-Isolated Docker Container (WSL2 / Linux)

**Built and tested for Windows + WSL2**, with best-effort support for native Linux desktops — `run.sh` auto-detects WSLg (`/mnt/wslg`) vs. a native `XDG_RUNTIME_DIR` and mounts the right GUI/audio sockets accordingly (see [How it works](#how-it-works)). It does **not** support macOS: there's no X11/Wayland or PulseAudio on the host to pass through, and it would need a fundamentally different approach (e.g. VNC).

Runs [Claude Desktop](https://github.com/aaddrick/claude-desktop-debian) inside a Docker container with **all traffic forced through AdGuard VPN** and a **killswitch** — if the VPN drops, the container loses network access entirely instead of leaking traffic through your regular connection. GUI, audio, and microphone are forwarded to Windows via WSLg (see [How it works](#how-it-works) for details).

## How it works

- The container has its own isolated network namespace (unlike separate WSL2 distros, which share one).
- `entrypoint.sh` sets a default-DROP `iptables` policy, brings up AdGuard VPN CLI (TUN mode), waits for the `tun0` interface and checks that a real request through it succeeds (HTTP 200 + valid JSON from `ip-api.com`), then allows traffic only through it (plus loopback and the VPN process itself).
- If the VPN never connects, the container refuses to start the GUI app instead of running with a broken killswitch.
- GUI is displayed via X11 (`/tmp/.X11-unix`, bind-mounted from the host — the app runs in X11-via-XWayland mode, see `--doctor` output). Audio and microphone go through PulseAudio, whose socket `run.sh` locates automatically: `/mnt/wslg/runtime-dir/pulse/native` on WSL2 (provided by WSLg), or `$XDG_RUNTIME_DIR/pulse/native` on native Linux (provided by the desktop session).
- Your home directory and VPN login are stored outside the container (both bind-mounted from the host), so they survive container restarts. The container itself is ephemeral — it only exists while the main process (Claude Desktop) is running.

## Prerequisites

**On WSL2:**
- **Windows 11** with WSL2 and a Linux distro (tested on Debian).
- **`.wslconfig` must use NAT networking**, not mirrored:
```ini
  [wsl2]
  networkingMode=NAT
```
  (Mirrored mode breaks Docker's bridge networking on some setups — see Troubleshooting.)

**On native Linux:**
- An X11 (or XWayland) session — `$DISPLAY` and `/tmp/.X11-unix` must be present.
- A running PulseAudio user session (`$XDG_RUNTIME_DIR/pulse/native` must exist) if you want audio/mic.
- Not tested as extensively as WSL2 — see [How it works](#how-it-works) for what `run.sh` auto-detects.

**Both:**
- **Docker Engine** (not Docker Desktop). On WSL2, install it inside the distro:
```bash
  sudo apt-get update
  sudo apt-get install -y ca-certificates curl gnupg
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list
  sudo apt-get update
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  sudo usermod -aG docker $USER   # then re-login or `newgrp docker`
  sudo systemctl enable --now docker
```
- An **AdGuard VPN account** (the CLI will prompt you to log in on first run).

Node.js is installed in the image alongside the packages above because `claude-desktop-unofficial` depends on it. The .NET 10 SDK is also installed, in case you want to build .NET projects inside the same VPN-protected environment (e.g. via `--mount` — see [Mounting host folders](#mounting-your-windows-drives)) — change `dotnet-sdk-10.0` in the `Dockerfile` if you need a different version.

Also included: `git`, `gh`, `jq`, `ripgrep`, `shellcheck`, and a general dev toolbox (see the `Dockerfile` package list for the full set), plus `chromium` (`--no-sandbox` is baked in via `/etc/chromium.d/`, and it's set as the default browser — see Troubleshooting for how OAuth/login link handling is wired up) and `gedit` for quick file edits inside the container.

## Project files

```
~/claude-desktop-vpn-container/
├── Dockerfile     # image definition
├── entrypoint.sh  # killswitch + VPN bring-up + GUI launch, runs as container PID 1
├── run.sh         # wrapper around docker run with the right flags
└── README.md
```

## Setup

1. Clone/create the project directory and add `Dockerfile`, `entrypoint.sh`, `run.sh` (see repo).
2. Build the image:
```bash
   cd ~/claude-desktop-vpn-container
   docker build --network=host -t claude-desktop-vpn-container \
       --build-arg PUID=$(id -u) --build-arg PGID=$(id -g) .
```
   `--network=host` is required for the build itself — some WSL2/Docker setups fail to resolve DNS over the default bridge network during `docker build` (see Troubleshooting). It has no effect on the container at runtime.

   By default this reuses Docker's build cache, including the `claude-desktop-unofficial` install step — a plain rebuild won't pick up a newer upstream release on its own. Check whether one's available with:
```bash
   ~/claude-desktop-vpn-container/run.sh --home ~/claude-container-home/ --location SG --check-claude-update
```
   This only checks the version and exits — it doesn't start the VPN or GUI. If it reports a newer version, force just the install step (and everything after it) to re-run:
```bash
   docker build --network=host -t claude-desktop-vpn-container \
       --build-arg PUID=$(id -u) --build-arg PGID=$(id -g) \
       --build-arg CACHEBUST=$(date +%s) .
```

3. Pick a home directory for the container (anything you like, created automatically):
```bash
   mkdir -p ~/claude-container-home
```

## First run (VPN login)

```bash
~/claude-desktop-vpn-container/run.sh --home ~/claude-container-home/ --location <LOCATION_CODE> bash
```

Replace `<LOCATION_CODE>` with an AdGuard VPN location code (e.g. `SG`, `DE`, `US`). Run `adguardvpn-cli list-locations` inside a container to see available codes if unsure.

On first launch, `entrypoint.sh` will detect there's no saved login and print a device-authorization link:
```
You need to authorize in your browser. The following link will be available for 1799 seconds: https://...
```

Open that link in a Windows browser and log in with your AdGuard account. The VPN config (including the login token) is stored in `<home>/.adguard-vpn-config`, bind-mounted from your home directory; the container also uses a fixed hostname and a MAC address generated on first run (then reused via `.container-mac`) — **both are required** for AdGuard to recognize the session as the same device on subsequent runs.

Why this matters: the container runs with `--rm`, so a fresh one is created on every launch, and Docker randomizes both the hostname and MAC address per container by default. AdGuard identifies a device by that hostname+MAC pair — without pinning them, every run would look like a brand-new device, which would either re-prompt for login every time or eat into your AdGuard account's device-limit quota (each "device" it hasn't seen before counts toward the limit, even if you never log out the old ones). `run.sh` and `entrypoint.sh` fix both to the same values every run so the container always looks like the same one device to AdGuard.

Don't delete `.container-mac` or `.adguard-vpn-config` in your home directory unless you want a fresh device identity.

## Normal usage

```bash
~/claude-desktop-vpn-container/run.sh --home ~/claude-container-home/ --location SG
```

With no trailing command, this launches `claude-desktop-unofficial` (the GUI) directly. The container:
1. Sets up the killswitch.
2. Confirms you're logged in to AdGuard (skips the login prompt if already authenticated).
3. Connects to the VPN and waits (up to 30s) for `tun0`.
4. Verifies traffic actually flows through the tunnel: up to 5 attempts (5s apart) of `curl http://ip-api.com/json`, which must return HTTP 200 with valid JSON. On success it logs the exit IP and location.
5. If either the VPN or that check fails, the container **exits** rather than launching the GUI in a broken state — check `docker exec -it claude-desktop-vpn adguardvpn-cli status` and `docker exec -it claude-desktop-vpn tail -40 /root/.local/share/adguardvpn-cli/tunnel.log`.
6. Launches Claude Desktop with GUI/audio/mic forwarded to your Windows session.

Closing the Claude Desktop window doesn't necessarily stop the container — like on native Linux, the app may keep running in the background. To fully stop everything:

```bash
docker rm -f claude-desktop-vpn
```

### Mounting your Windows drives

By default the container only sees `$HOME_DIR` — none of your actual Windows drives. If you need Claude Desktop to access files elsewhere on `C:`, `D:`, etc., pass `--mount-wsl-drives`:

```bash
~/claude-desktop-vpn-container/run.sh --home ~/claude-container-home/ --location SG --mount-wsl-drives
```

This bind-mounts every `/mnt/<letter>` drive WSL2 exposes (e.g. `/mnt/c`, `/mnt/d`) into the container at the same path. It's a no-op with a warning if you're not on WSL2 (native Linux has no drive letters to mount). **This gives the container read/write access to your entire Windows filesystem** — only use it if you actually need it, and understand it works against the isolation this setup is otherwise built for.

If you only need specific folders rather than whole drives, use `--mount src-path:dst-path` instead — it can be repeated for multiple folders:

```bash
~/claude-desktop-vpn-container/run.sh --home ~/claude-container-home/ --location SG \
    --mount /mnt/e/git/some-project:/home/claude/some-project \
    --mount /mnt/d/docs:/home/claude/docs
```

Note that `~` in the destination gets expanded by your *host* shell before `run.sh` ever sees it (e.g. `~/test` becomes `/home/<you>/test`, not a path inside the container) — write out the actual in-container path you want (typically under `/home/claude/...`) instead of relying on `~`.

### Forwarding ports

By default nothing running inside the container is reachable from the host. If you're running something inside the container that needs to be reachable (a dev server, an API, etc.), use `--port [host-ip:]host-port:container-port` — it can be repeated, takes an optional `/tcp` or `/udp` suffix (default `/tcp`), and an optional host IP to bind to a specific interface instead of all of them:

```bash
~/claude-desktop-vpn-container/run.sh --home ~/claude-container-home/ --location SG \
    --port 3000:3000 \
    --port 127.0.0.1:8080:80 \
    --port 53:53/udp \
    bash
```

This is a regular Docker port publish (`-p`) — the killswitch only restricts *outbound* traffic (`OUTPUT` chain), so published ports work normally regardless of VPN/killswitch state.

### Redirecting outbound connections

The opposite of `--port`: instead of exposing something *in* the container to the outside, `--redirect-port local-port:remote-host:remote-port[/tcp|udp]` transparently reroutes an outbound connection *from inside* the container. Whatever a process inside the container tries to reach on `local-port` (including `127.0.0.1:local-port`) actually lands on `remote-host:remote-port` instead. Repeatable, defaults to `/tcp`:

```bash
~/claude-desktop-vpn-container/run.sh --home ~/claude-container-home/ --location SG \
    --redirect-port 47306:5.182.87.205:47306 \
    bash
```

Implemented as a DNAT rule in the `nat` table's `OUTPUT` chain (added by `entrypoint.sh` from the `PORT_REDIRECTS` env var `run.sh` sets). Redirecting a `127.0.0.1`-addressed connection specifically needs `net.ipv4.conf.all.route_localnet=1`, which can only be set at container creation (not via `sysctl -w` at runtime — same AppArmor restriction as `--disable-ipv6`) — `run.sh` adds it automatically whenever `--redirect-port` is used.

**This traffic bypasses the VPN.** Everything else in the container is still bound by the killswitch (must go through `tun0` or be root), but each `--redirect-port` entry is carved out of that in three places `entrypoint.sh` sets up, all scoped to that exact `remote-host:remote-port`:

- A `filter`/`OUTPUT` `ACCEPT` rule, so the killswitch lets the (post-DNAT) traffic out at all.
- A `nat`/`POSTROUTING` `MASQUERADE` rule — without it, a connection that was originally addressed to `127.0.0.1` keeps that as its source address even after DNAT, so the remote side can never reply.
- A host route via the container's pre-VPN default interface, plus an `ip rule` for that destination pointing at the `main` routing table with a lower `pref` than AdGuard's own policy rule. AdGuard's AUTO mode doesn't just add a default route — it installs a high-priority policy route covering most of the public IP space, and Linux's rule lookup stops at the first rule that matches *anything*, not the most specific route overall. Without the extra `ip rule`, the destination route above would be correct but simply never consulted, and traffic would silently keep going through `tun0`.

This is deliberate and scoped: only traffic landing on that specific destination (after the DNAT rewrite) is exempted — nothing else changes. Use it when you specifically want a particular endpoint to reach a local/low-latency service rather than round-tripping through the VPN, and are fine with that one destination seeing your real IP.

### Using your host's SSH agent

On by default: `run.sh` forwards your host's `$SSH_AUTH_SOCK`, plus `~/.ssh/config` (read-only) and `~/.ssh/known_hosts` (read-write) if they exist. No other files under `~/.ssh` are touched. No-op with a warning if there's no `ssh-agent` running on the host.

To turn it all off at once:

```bash
~/claude-desktop-vpn-container/run.sh --home ~/claude-container-home/ --location SG --no-forward-ssh-agent bash
```

Note this is why `gnome-keyring-daemon` is started with `--components=secrets,pkcs11` (no `ssh`) in `entrypoint.sh`: gnome-keyring's own `ssh` component would otherwise claim `SSH_AUTH_SOCK` for its own (empty, keyless) agent and shadow the one forwarded from the host.

### Running other commands in the container

Since `run.sh` accepts a trailing command, you can use the same VPN-protected environment for other things:

```bash
# doctor diagnostics
~/claude-desktop-vpn-container/run.sh --home ~/claude-container-home/ --location SG claude-desktop-unofficial --doctor

# quick connectivity check
~/claude-desktop-vpn-container/run.sh --home ~/claude-container-home/ --location SG curl ip-api.com

# shell access
~/claude-desktop-vpn-container/run.sh --home ~/claude-container-home/ --location SG bash
```

### Inspecting a running container

```bash
docker ps -a                            # see if it's running
docker exec -it claude-desktop-vpn bash # shell into a running container
```

## Troubleshooting

**`docker build` hangs or times out resolving DNS.**
Rebuild with `--network=host`. If `apt-get` inside the Dockerfile hangs specifically (not fails), it's usually an IPv6 connectivity gap in WSL2 — the Dockerfile already forces IPv4 via `Acquire::ForceIPv4=true` and `curl -4`.

**Docker containers have no network access at all (build or runtime), even though the WSL2 host does.**
Check `.wslconfig` — if `networkingMode=mirrored`, switch to `NAT` (see Prerequisites) and `wsl --shutdown`, then restart Docker. Mirrored mode has been observed to break Docker's bridge/NAT forwarding on some Windows builds. If NAT is already set, check `sudo iptables -t nat -L -n -v | grep -i docker` for a `MASQUERADE` rule — if it's missing, `sudo systemctl restart docker` regenerates it (this can happen if another WSL2 distro touches iptables after Docker starts, since all WSL2 distros share one network namespace).

**`adguardvpn-cli` (or other outbound requests) intermittently hang for ~5s then succeed, or fail with "HTTP protocol error".**
Some networks have broken/unreliable IPv6 — a request tries IPv6 first, stalls, then falls back to IPv4. Pass `--disable-ipv6` to `run.sh` to disable IPv6 inside the container (`--sysctl net.ipv6.conf.all.disable_ipv6=1`), e.g. `run.sh --home ... --location SG --disable-ipv6`. Confirm it's active with `docker exec -it claude-desktop-vpn sysctl net.ipv6.conf.all.disable_ipv6` (should read `1`).

**Claude Desktop window is blank / doesn't render / can't be dragged.**
This was Docker's default 64MB `/dev/shm`, too small for Chromium's multi-process rendering. Already fixed via `--shm-size=1g` in `run.sh` — if you removed that flag, add it back.

**MCP server keeps disconnecting / "Couldn't finish loading" / WebSocket closes with code 1006.**
The VPN's `tun0` MTU of 1500 can cause fragmentation on long-lived WebSocket connections. `entrypoint.sh` already lowers it to 1400 right after the interface comes up.

**Container exits right after "Verifying traffic actually flows through the VPN".**
`tun0` came up but five requests to `ip-api.com` in a row didn't return HTTP 200 with valid JSON — usually the chosen VPN location is down or overloaded, or `ip-api.com` is rate-limiting that exit IP. Nothing leaks in the meantime (the killswitch is already active). Retry, try another `--location`, or check `adguardvpn-cli status` as printed in the error.

**A GUI window (e.g. Chromium) is in the Windows taskbar and clickable, but never appears.**
Not a container problem — WSLg's own RDP channel to the Windows-side `msrdc.exe` can break, so the window exists but its contents never reach Windows. Confirm with:
```bash
grep -c rdp_allocate_shared_memory /mnt/wslg/weston.log
```
A large and growing count (`Input/output error` in the log) means the channel is dead. Fix: close everything, run `wsl --shutdown` in PowerShell, then start the container again. A healthy log has little to none of these lines.

**"Your sign-in won't be saved on this device" / `safeStorage not available` in logs.**
`entrypoint.sh` does launch the GUI inside `dbus-run-session` with a `gnome-keyring-daemon` unlocked/started beforehand — but in practice the `DBUS_SESSION_BUS_ADDRESS` env var doesn't reliably survive the several layers of the `claude-desktop-unofficial` launcher script between that setup and the actual Electron binary being exec'd, so the app can end up talking to a *different*, never-unlocked, D-Bus-auto-activated keyring instead of the one we unlocked.

Rather than chase that down further, `entrypoint.sh` sidesteps it: on first run it writes `CLAUDE_PASSWORD_STORE=basic` to `~/.config/claude-desktop-debian/environment` (the launcher's own documented config file, read before every launch) if that file doesn't already exist. This makes the launcher pass `--password-store=basic` to Electron, which stores credentials in plain form instead of going through the OS keyring at all — sidestepping the D-Bus dependency entirely rather than fixing it. **Trade-off:** the login token is then stored unencrypted on disk (still only as exposed as the rest of `$HOME_DIR`, which is already bind-mounted from your host). Delete the `environment` file (or edit out that line) if you'd rather keep chasing the keyring path instead.

To confirm which one is actually active, check the running process's own arguments rather than logs:
```bash
docker exec -it claude-desktop-vpn pgrep -af claude-desktop-unofficial
```
Look for `--password-store=basic` on the main `claude-desktop` process line (not the `bash /usr/bin/claude-desktop-unofficial` wrapper line).

**Microphone doesn't work / `pactl` says "Connection refused".**
Check what `run.sh` detected: it prints a warning if the runtime dir it picked (`/mnt/wslg/runtime-dir` on WSL2, `$XDG_RUNTIME_DIR` on native Linux) doesn't exist on the host. Confirm the actual Pulse socket is there (`ls <runtime-dir>/pulse/native`) and, on WSL2, that you're not using the nonexistent `/mnt/wslg/PulseServer` path from older guides.

**Don't mount all of `/mnt/wslg` (WSL2 only).**
`/mnt/wslg/distro/` bind-mounts the *entire root filesystem* of the WSLg host distro, which — because Windows drives are mounted via `drvfs` — includes your Windows drives. `run.sh` only mounts `/mnt/wslg/runtime-dir`, which is all that's actually needed for Wayland/PulseAudio sockets.

**AdGuard login keeps being requested again on every run.**
AdGuard ties the session to the device's MAC address and hostname. Docker randomizes both per container by default. `run.sh` generates a random MAC once and stores it in `<home>/.container-mac`, reusing it on every run, and `entrypoint.sh`/`run.sh` fix the hostname to `claude-desktop-vpn-container`. Don't delete the `.container-mac` file.

**`adguardvpn-cli connect` fails with `Insufficient rights, please try running the command with sudo -E` / `ioctl TUNSETIFF failed: Operation not permitted`.**
The VPN process needs to create a TUN device, which requires root privileges — it must run as root inside the container (the image is deliberately structured this way: VPN login/connect always run as root; only the GUI app drops to the unprivileged `claude` user).

**Clicking an OAuth/login link (e.g. "Sign in with Google" from Claude Desktop) pops up "no application associated" / an empty "Open With..." chooser.**
This is a two-part fix, both handled automatically:
1. `claude-desktop-unofficial`'s own `.desktop` file declares `MimeType=x-scheme-handler/claude`, but nothing sets it as the *default* handler — `entrypoint.sh` runs `xdg-mime default claude-desktop-unofficial.desktop x-scheme-handler/claude` for the `claude` user on every start.
2. Even with that set, a chooser dialog (e.g. from `chromium`, the container's default browser) lists candidate apps from a separate index — `mimeinfo.cache` — not from the default-handler file. Without `desktop-file-utils` installed and `update-desktop-database` run at build time, that index doesn't exist and Claude Desktop never shows up as an option at all, regardless of the default-handler setting. The `Dockerfile` installs `desktop-file-utils` and runs `update-desktop-database /usr/share/applications` right after installing `claude-desktop-unofficial`.

If you swap in a different browser/package and this breaks again, re-run `update-desktop-database` after any change to `/usr/share/applications`.

**`adguardvpn-cli status` shows "System DNS could not be configured. DNS queries may bypass the VPN tunnel".**
This is expected and not a leak in this setup. Docker manages `/etc/resolv.conf` itself, so AdGuard can't rewrite it — but the killswitch only allows traffic from root (uid 0) or through `tun0`; since AdGuard's AUTO routing mode installs a full default route via `tun0`, DNS queries (like everything else from non-root processes) are forced through the tunnel regardless of which nameserver IP is configured. Verify anytime with `docker exec -it claude-desktop-vpn curl ip-api.com` — it should report the VPN's location, not your real one.

## Known limitations

- No KVM/QEMU passthrough, so Claude Desktop's Cowork VM feature won't work inside the container (`--doctor` will report this).
- UDP traffic is fully tunneled (this setup uses the CLI's TUN mode, not a TCP-only SOCKS proxy).
