# syntax=docker/dockerfile:1
# Subnautica 2 headless session host.
#
# Two targets:
#   panel (default)  small Wine layer supervised by s6-overlay as a fixed non-root
#                    user; what compose.yaml runs on Docker Desktop and Linux
#   backup           offen's pinned backup engine plus local scheduling policy
#
# The image contains no Steam, game, UE4SS binaries or sign-in. All of those are
# fetched at runtime into the one data volume.

ARG DEBIAN_DIGEST=sha256:f6b08b09a05725f9431502d3b5714f5c4576e82c1a84fa1debe0c24a7e0c3ec4

FROM debian:trixie-slim@${DEBIAN_DIGEST} AS panel

ARG WINE_STAGING_DEB=11.20~trixie-1
# s6-overlay supervises the panel image (a panel runs one process).
ARG S6_OVERLAY_VERSION=3.2.3.2
ARG S6_NOARCH_SHA256=5379750ed30a84bbd2e2dd74847ba6b5bd29cd0b2e3ea2ec58049b57eb2eda12
ARG S6_X86_64_SHA256=e6befcc96a437a3831386ecfc51808c5d3e939dc5fe3c02ae9284599e8aa2408
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
# winehq-staging needs its recommends (the 32-bit Wine libraries). Those also bring a USB
# printer daemon and mDNS, which a headless host has no use for, so they come back out.
# hadolint ignore=DL3008,DL3015
RUN dpkg --add-architecture i386 \
 && apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl gnupg \
 && mkdir -p /etc/apt/keyrings \
 && curl -fsSL -o /tmp/winehq.key https://dl.winehq.org/wine-builds/winehq.key \
 && curl -fsSL -o /etc/apt/sources.list.d/winehq-trixie.sources \
      https://dl.winehq.org/wine-builds/debian/dists/trixie/winehq-trixie.sources \
 && printf '%s  %s\n' \
      d965d646defe94b3dfba6d5b4406900ac6c81065428bf9d9303ad7a72ee8d1b8 /tmp/winehq.key \
      d10fb49718b5ceda9cc9c2f8f52b076772396b4b3563a1aad2ab6503414dcee7 /etc/apt/sources.list.d/winehq-trixie.sources \
      | sha256sum -c - \
 && gpg --dearmor -o /etc/apt/keyrings/winehq-archive.key /tmp/winehq.key \
 && apt-get update \
 && apt-get install -y --install-recommends \
      "winehq-staging=${WINE_STAGING_DEB}" "wine-staging=${WINE_STAGING_DEB}" \
      "wine-staging-amd64=${WINE_STAGING_DEB}" "wine-staging-i386=${WINE_STAGING_DEB}" \
 && apt-get install -y --no-install-recommends \
      apt libapt-pkg7.0 \
      xvfb x11-utils xdotool x11vnc websockify autocutsel jq unzip zip 7zip procps xz-utils osslsigncode python3-minimal python3-vdf python3-jinja2 python3-requests python3-cryptography python3-yaml openssl lighttpd logrotate fonts-dejavu-core \
 && apt-get purge -y ipp-usb avahi-daemon \
 && apt-get clean && rm -rf /var/lib/apt/lists/*
# WINE_RUNTIME=tkg also unpacks Kron4ek's build of wine-tkg-staging-fsync 10.10, pinned by sha256,
# and puts it first on PATH: Wine Staging with fsync, which WineHQ's Wine never had and later wine-tkg
# builds dropped for ntsync. WineHQ's stays installed for its system dependencies, the 32-bit ones too.
# Proton's Wine was tried first and left out: the Windows Steam client does not start under it
# ("InternalAPI_Init_Internal failed"), with or without fsync. The default is winehq until measured.
ARG WINE_RUNTIME=winehq
ARG WINE_TKG_VERSION=10.10
ARG WINE_TKG_SHA256=1d97bb21a931ac1839e9291bce9f321c80d1cc84183badbc1a86e6c42ebf678a
RUN mkdir -p /opt/sn2 \
 && case "${WINE_RUNTIME}" in \
      winehq) ;; \
      tkg) f="wine-${WINE_TKG_VERSION}-staging-tkg-amd64.tar.xz" \
        && curl -fsSL -o "/tmp/$f" "https://github.com/Kron4ek/Wine-Builds/releases/download/${WINE_TKG_VERSION}/$f" \
        && echo "${WINE_TKG_SHA256}  /tmp/$f" | sha256sum -c - \
        && mkdir -p /opt/wine-tkg && tar -C /opt/wine-tkg --strip-components=1 -xJf "/tmp/$f" && rm -f "/tmp/$f" \
        && for b in /opt/wine-tkg/bin/*; do ln -s "$b" /usr/local/bin/; done \
        && [ "$(command -v wineserver)" = /usr/local/bin/wineserver ] ;; \
      *) echo "WINE_RUNTIME must be winehq or tkg" >&2; exit 2 ;; \
    esac \
 && echo "${WINE_RUNTIME}" > /opt/sn2/wine-runtime
WORKDIR /tmp
# noVNC from its own release: static files websockify serves. Debian's package would bring Node.js
# along, which nothing here runs.
# Pillow from its own wheel, pinned by sha256: it decodes the map's background pictures, which come
# from addresses the host sets, and Debian's 11.1 carries decoder advisories Debian will not patch.
# The wheel bundles its own image libraries; unpacking it is what pip would do, without adding pip.
ARG PILLOW_WHEEL=pillow-13.0.0-cp313-cp313-manylinux_2_27_x86_64.manylinux_2_28_x86_64.whl
ARG PILLOW_URL=https://files.pythonhosted.org/packages/ef/fe/f5cdaa2d1c4086e757430f368c271a58ee29cfe7378e7ae7b9d964015c25
ARG PILLOW_SHA256=5f56499c1a74d2b862beb0c33b8016f99d095858455df9d21583bbbc1c15b582
RUN curl -fsSL -o "${PILLOW_WHEEL}" "${PILLOW_URL}/${PILLOW_WHEEL}" \
 && echo "${PILLOW_SHA256}  ${PILLOW_WHEEL}" | sha256sum -c - \
 && unzip -q "${PILLOW_WHEEL}" -d /usr/local/lib/python3.13/dist-packages \
 && rm -f "${PILLOW_WHEEL}" \
 && python3 -c 'import PIL.Image, PIL.ImageGrab; assert PIL.__version__ == "13.0.0"'
ARG NOVNC_VERSION=1.7.0
ARG NOVNC_SHA256=b1003a11b6e6e8d8f7f5e5586daae7f8ca651d8aee0aa155ff9ac841c48f52c6
RUN curl -fsSL -o novnc.tar.gz "https://github.com/novnc/noVNC/archive/refs/tags/v${NOVNC_VERSION}.tar.gz" \
 && echo "${NOVNC_SHA256}  novnc.tar.gz" | sha256sum -c - \
 && mkdir -p /usr/share/novnc && tar -C /usr/share/novnc --strip-components=1 -xzf novnc.tar.gz \
 && rm -f novnc.tar.gz
RUN base="https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}" \
 && curl -fsSLO "$base/s6-overlay-noarch.tar.xz" && curl -fsSLO "$base/s6-overlay-x86_64.tar.xz" \
 && echo "${S6_NOARCH_SHA256}  s6-overlay-noarch.tar.xz" | sha256sum -c - \
 && echo "${S6_X86_64_SHA256}  s6-overlay-x86_64.tar.xz" | sha256sum -c - \
 && tar -C / -Jxpf s6-overlay-noarch.tar.xz && tar -C / -Jxpf s6-overlay-x86_64.tar.xz \
 && rm -f s6-overlay-noarch.tar.xz s6-overlay-x86_64.tar.xz
ARG SUPERCRONIC_VERSION=v0.2.51
ARG SUPERCRONIC_SHA256=cc232108374e8e2b537045f2d5eaa1229f619db314c3ba6a14d38b35dc0aa123
RUN curl -fsSL -o /usr/local/bin/supercronic \
      "https://github.com/aptible/supercronic/releases/download/${SUPERCRONIC_VERSION}/supercronic-linux-amd64" \
 && echo "${SUPERCRONIC_SHA256}  /usr/local/bin/supercronic" | sha256sum -c - \
 && chmod 0755 /usr/local/bin/supercronic

# The game runs as a fixed non-root user. s6-overlay needs a writable /run: it's a
# volume, root-owned with the sticky bit, which s6-overlay's preinit accepts for any uid.
RUN useradd -m -d /home/container -s /bin/bash container && chown root:root /run && chmod 1777 /run
VOLUME ["/run"]
COPY --chmod=0755 docker/sn2-service.sh docker/healthcheck.sh /opt/sn2/bin/
COPY --chmod=0755 docker/s6-overlay/ /etc/s6-overlay/
COPY --chmod=0755 scripts/common.sh scripts/launch-headless.sh scripts/restart-warning.sh scripts/install-game.sh \
     scripts/install-ue4ss.sh scripts/install-msvc-runtime.sh scripts/join-watch.sh scripts/join-page.py scripts/friend-accept.py scripts/discord-notify.py scripts/save-stage.sh scripts/steam-config.sh scripts/restart-after-autosave.sh scripts/steam-install-confirm.sh scripts/verify-fresh.sh scripts/world-stats.py scripts/tick-report.py scripts/steamfile.py scripts/sn2files.py \
     scripts/map-chart.py scripts/plugins-section.py scripts/mod-stats.py scripts/mod-service.sh scripts/publish-mods.py /opt/sn2/bin/
COPY --chmod=0755 bin/moonpool /usr/local/bin/moonpool
COPY mod/ /opt/sn2/mod/
COPY web/ /opt/sn2/web/
COPY NOTICE LICENSE /opt/sn2/

# Everything from here runs as the "container" user created above.
# hadolint ignore=DL3066
USER container
WORKDIR /home/container
ENV SN2_IN_CONTAINER=1 \
    USER=container \
    HOME=/home/container \
    DATA_DIR=/home/container \
    SN2_CONTROL_DIR=/home/container/control \
    DISPLAY=:99 \
    S6_KEEP_ENV=1 \
    S6_CMD_WAIT_FOR_SERVICES_MAXTIME=0 \
    S6_SERVICES_GRACETIME=210000 \
    S6_KILL_GRACETIME=5000 \
    S6_BEHAVIOUR_IF_STAGE2_FAILS=2
HEALTHCHECK --interval=60s --timeout=10s --start-period=300s \
    CMD ["/opt/sn2/bin/healthcheck.sh"]
# /init (s6-overlay) supervises every service. The command only shows the services log.
# The tunnel token is for the tunnel container; the game, Steam and mods never see it. The other secrets
# are taken out where Steam and the game are started (WITHOUT_SECRETS in common.sh).
ENTRYPOINT ["/usr/bin/env", "-u", "TUNNEL_TOKEN", "/init"]
CMD ["/bin/bash", "-c", "mkdir -p \"$DATA_DIR/logs\" && touch \"$DATA_DIR/logs/services.log\" && exec tail -n +1 -F \"$DATA_DIR/logs/services.log\""]

# ---------------------------------------------------------------------------
# Keep offen's backup engine and add only the scheduling policy that it lacks:
# skip byte-for-byte unchanged sources and optionally cap local archive bytes.
FROM offen/docker-volume-backup:v2.50.1@sha256:06fccb4c6ff79c4d5e4a839ace17c174da82a9327f43594f8a2c6a15f43bc660 AS backup
COPY --chmod=0755 scripts/backup-run.sh /usr/local/bin/sn2-backup
ENTRYPOINT ["/usr/local/bin/sn2-backup"]

# ---------------------------------------------------------------------------
FROM panel AS default
