FROM debian:bookworm-slim

ARG PUID=1000
ARG PGID=1000

ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

RUN apt-get update -o Acquire::ForceIPv4=true && apt-get install -y -o Acquire::ForceIPv4=true --no-install-recommends \
    curl \
    ca-certificates \
    gnupg \
    git \
    jq \
    ripgrep \
    python3 \
    build-essential \
    unzip \
    openssh-client \
    less \
    vim \
    nano \
    gedit \
    chromium \
    xdg-utils \
    xxd \
    binutils \
    file \
    dnsutils \
    iputils-ping \
    rsync \
    shellcheck \
    iptables \
    iproute2 \
    sudo \
    dbus-x11 \
    gnome-keyring \
    libsecret-1-0 \
    pulseaudio-utils \
    libnss3 \
    libgtk-3-0 \
    libxss1 \
    libasound2 \
    fonts-liberation \
    dbus-user-session \
    libglib2.0-bin \
    && rm -rf /var/lib/apt/lists/*

RUN curl -4 -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
    apt-get install -y -o Acquire::ForceIPv4=true nodejs && \
    rm -rf /var/lib/apt/lists/*

RUN curl -4 -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | gpg --dearmor -o /usr/share/keyrings/githubcli-archive-keyring.gpg && \
    chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list && \
    apt-get update -o Acquire::ForceIPv4=true && \
    apt-get install -y -o Acquire::ForceIPv4=true --no-install-recommends gh && \
    rm -rf /var/lib/apt/lists/*

RUN curl -4 -fsSL https://packages.microsoft.com/config/debian/12/packages-microsoft-prod.deb -o /tmp/packages-microsoft-prod.deb && \
    dpkg -i /tmp/packages-microsoft-prod.deb && \
    rm /tmp/packages-microsoft-prod.deb && \
    apt-get update -o Acquire::ForceIPv4=true && \
    apt-get install -y -o Acquire::ForceIPv4=true --no-install-recommends dotnet-sdk-10.0 && \
    rm -rf /var/lib/apt/lists/*

ENV USER=root
RUN curl -4 -fsSL https://raw.githubusercontent.com/AdguardTeam/AdGuardVPNCLI/master/scripts/release/install.sh -o /tmp/install-adguard.sh
RUN sh /tmp/install-adguard.sh -v < /dev/null || true
RUN ln -sf /opt/adguardvpn_cli/adguardvpn-cli /usr/local/bin/adguardvpn-cli

ARG CACHEBUST=1
RUN echo "cachebust=$CACHEBUST" && \
    curl -4 -fsSL https://pkg.claude-desktop-debian.dev/KEY.gpg | gpg --dearmor -o /usr/share/keyrings/claude-desktop-unofficial.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/claude-desktop-unofficial.gpg arch=amd64,arm64] https://pkg.claude-desktop-debian.dev stable main" \
        > /etc/apt/sources.list.d/claude-desktop-unofficial.list && \
    apt-get update -o Acquire::ForceIPv4=true && apt-get install -y -o Acquire::ForceIPv4=true --no-install-recommends claude-desktop-unofficial && \
    rm -rf /var/lib/apt/lists/*

# /usr/bin/chromium (Debian's launcher script) sources every file under
# /etc/chromium.d/ and appends to CHROMIUM_FLAGS — the supported way to
# inject flags regardless of how chromium gets invoked (.desktop file,
# xdg-open, x-www-browser, direct CLI).
RUN mkdir -p /etc/chromium.d && \
    printf 'CHROMIUM_FLAGS="$CHROMIUM_FLAGS --no-sandbox"\n' > /etc/chromium.d/no-sandbox && \
    update-alternatives --set x-www-browser /usr/bin/chromium
ENV BROWSER=/usr/bin/chromium

RUN groupadd -g ${PGID} claude && \
    useradd -u ${PUID} -g ${PGID} -m -s /bin/bash claude && \
    usermod -aG sudo claude && \
    passwd -d claude && \
    echo "claude ALL=(ALL:ALL) NOPASSWD: ALL" >> /etc/sudoers

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["claude-desktop-unofficial"]
