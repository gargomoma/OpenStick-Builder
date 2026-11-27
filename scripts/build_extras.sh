#!/bin/sh -e
# Optional extras, staged into dist/ (build_images.sh copies dist/ into the rootfs).
# Every part can be switched off: WITH_FIX_ATTACH_APN=0 ./build.sh
DIST=${DIST=$(pwd)/dist}
X=configs/extras

enable_unit() { # enable a unit the same way systemctl would (no running systemd needed)
    mkdir -p ${DIST}/etc/systemd/system/multi-user.target.wants
    ln -sf /etc/systemd/system/$1 ${DIST}/etc/systemd/system/multi-user.target.wants/$1
}

mkdir -p ${DIST}/etc/systemd/system ${DIST}/usr/local/sbin

# fix-attach-apn: the UZ801 modem firmware resets its LTE attach APN to
# 'mobile.three.com.hk' at every modem boot; this sets the right one for the SIM.
if [ "${WITH_FIX_ATTACH_APN:-1}" = 1 ]; then
    install -m 0755 ${X}/fix-attach-apn ${DIST}/usr/local/sbin/fix-attach-apn
    install -m 0644 ${X}/fix-attach-apn.service ${DIST}/etc/systemd/system/
    enable_unit fix-attach-apn.service
fi

# dongie-leds: status LEDs. WAN LED on = LTE connected, slow blink = searching
# or connecting, off = no service; WLAN LED on = Tailscale running (if
# installed), else Wi-Fi up (hotspot or client). Without it the LEDs just stay
# on. LEDs are found by name, so it fits UZ801, JZ01-45, MF800 and HMUF02;
# override in /etc/default/dongie-leds. Same script as dongie-rs/contrib.
if [ "${WITH_LEDS:-1}" = 1 ]; then
    install -m 0755 ${X}/dongie-leds ${DIST}/usr/local/sbin/dongie-leds
    install -m 0644 ${X}/dongie-leds.service ${DIST}/etc/systemd/system/
    enable_unit dongie-leds.service
fi

# fewer flash writes: small journal, quieter NetworkManager/ModemManager logs
# (measured on a UZ801: ~8 KiB/min of writes when idle)
if [ "${WITH_FLASH_TWEAKS:-1}" = 1 ]; then
    install -D -m 0644 ${X}/journald-flash.conf ${DIST}/etc/systemd/journald.conf.d/50-flash.conf
    install -D -m 0644 ${X}/NetworkManager-quiet.conf ${DIST}/etc/NetworkManager/conf.d/50-quiet.conf
    install -D -m 0644 ${X}/ModemManager-quiet.conf ${DIST}/etc/systemd/system/ModemManager.service.d/50-quiet.conf
fi

# dongie-rs (web dashboard + API: modem, SMS, hotspot; EUPL-1.2) and dongie-ims
# (Wi-Fi calling/VoWiFi + SMS over IMS, calls in the browser; GPL-3.0).
# Built from source at a pinned tag; their complete source (with vendored
# dependencies) is written to files/ next to the images.
# Needs: git, cargo with target aarch64-unknown-linux-musl, go >= 1.26.
# Versions: configs/extras/dongie-versions (also used by flake.nix).
# DONGIE_PREBUILT=<dir> uses binaries + source archives built elsewhere instead
# (layout of `nix build .#dongie`: bin/dongie, bin/dongie-ims, sources/*.tar.xz).
. ${X}/dongie-versions
DONGIE_RS_REPO=${DONGIE_RS_REPO=https://github.com/derpyspike/dongie-rs.git}
DONGIE_IMS_REPO=${DONGIE_IMS_REPO=https://github.com/derpyspike/dongie-ims.git}
if [ "${WITH_DONGIE:-1}" = 1 ] && [ -n "${DONGIE_PREBUILT}" ]; then
    mkdir -p files
    install -D -m 0755 ${DONGIE_PREBUILT}/bin/dongie ${DIST}/usr/local/bin/dongie
    install -D -m 0755 ${DONGIE_PREBUILT}/bin/dongie-ims ${DIST}/usr/local/bin/dongie-ims
    install -m 0644 ${DONGIE_PREBUILT}/sources/*.tar.xz files/
elif [ "${WITH_DONGIE:-1}" = 1 ]; then
    for t in git cargo go; do
        command -v $t >/dev/null || { echo "build_extras: '$t' not found (or build with WITH_DONGIE=0)"; exit 1; }
    done
    SRC=$(pwd)/build/extras
    rm -rf ${SRC} && mkdir -p ${SRC} files
    git clone -q --depth 1 -b ${DONGIE_RS_REF} ${DONGIE_RS_REPO} ${SRC}/dongie-rs
    git clone -q --depth 1 -b ${DONGIE_IMS_REF} ${DONGIE_IMS_REPO} ${SRC}/dongie-ims

    (cd ${SRC}/dongie-rs && cargo build -q --release --locked --target aarch64-unknown-linux-musl)
    # dongie-ims >= 0.3.0 carries a patch for a vendored ims-go (VoLTE's ESP
    # socket): its scripts/vendor.sh vendors + patches, then build from vendor/
    (cd ${SRC}/dongie-ims && sh scripts/vendor.sh && CGO_ENABLED=0 GOOS=linux GOARCH=arm64 \
        go build -mod=vendor -trimpath -ldflags='-s -w' -o dongie-ims .)

    install -D -m 0755 ${SRC}/dongie-rs/target/aarch64-unknown-linux-musl/release/dongie ${DIST}/usr/local/bin/dongie
    install -D -m 0755 ${SRC}/dongie-ims/dongie-ims ${DIST}/usr/local/bin/dongie-ims

    # complete corresponding source, including vendored Rust/Go dependencies
    (cd ${SRC}/dongie-rs && cargo vendor -q --locked vendor >/dev/null && mkdir -p .cargo && \
        printf '\n[source.crates-io]\nreplace-with = "vendored-sources"\n\n[source.vendored-sources]\ndirectory = "vendor"\n' >> .cargo/config.toml)
    # dongie-ims: vendor/ is already there, patched exactly as built
    rm -rf ${SRC}/dongie-rs/target ${SRC}/dongie-rs/.git ${SRC}/dongie-ims/.git ${SRC}/dongie-ims/dongie-ims
    tar -C ${SRC} -cJf files/sources-dongie-rs-${DONGIE_RS_REF}.tar.xz dongie-rs
    tar -C ${SRC} -cJf files/sources-dongie-ims-${DONGIE_IMS_REF}.tar.xz dongie-ims
fi

# muxtastic (shares one Meshtastic node between apps; AGPL-3.0-or-later,
# https://github.com/derpyspike/muxtastic): for a node with Wi-Fi on the
# stick's hotspot. Shown on dongie's Mesh tab. Installed, NOT enabled (it
# needs the node's address first). Has C parts (SQLite, aws-lc): needs zig
# (or `pip install ziglang`) as the aarch64 C compiler, plus cmake.
# MUXTASTIC_PREBUILT=<dir> takes bin/muxtastic + sources/*.tar.xz instead.
MUXTASTIC_REPO=${MUXTASTIC_REPO=https://github.com/derpyspike/muxtastic.git}
if [ "${WITH_MUXTASTIC:-1}" = 1 ] && [ -n "${MUXTASTIC_PREBUILT}" ]; then
    mkdir -p files
    install -D -m 0755 ${MUXTASTIC_PREBUILT}/bin/muxtastic ${DIST}/usr/local/bin/muxtastic
    install -m 0644 ${MUXTASTIC_PREBUILT}/sources/*.tar.xz files/
elif [ "${WITH_MUXTASTIC:-1}" = 1 ]; then
    command -v zig >/dev/null || python3 -m ziglang version >/dev/null 2>&1 || \
        { echo "build_extras: zig not found (pip install ziglang, or build with WITH_MUXTASTIC=0)"; exit 1; }
    for t in git cargo cmake; do
        command -v $t >/dev/null || { echo "build_extras: '$t' not found (or build with WITH_MUXTASTIC=0)"; exit 1; }
    done
    SRC=$(pwd)/build/extras-muxtastic
    ZCC=$(pwd)/scripts/zigcc-aarch64-musl
    rm -rf ${SRC} && mkdir -p ${SRC} files
    git clone -q --depth 1 -b ${MUXTASTIC_REF} ${MUXTASTIC_REPO} ${SRC}/muxtastic
    (cd ${SRC}/muxtastic && \
        CC_aarch64_unknown_linux_musl=${ZCC} AR_aarch64_unknown_linux_musl=${ZCC}-ar \
        CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER=rust-lld \
        CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_RUSTFLAGS="-C target-feature=+crt-static" \
        cargo build -q --release --locked --target aarch64-unknown-linux-musl -p muxtastic)
    install -D -m 0755 ${SRC}/muxtastic/target/aarch64-unknown-linux-musl/release/muxtastic ${DIST}/usr/local/bin/muxtastic
    # complete corresponding source (AGPL), with vendored dependencies
    (cd ${SRC}/muxtastic && cargo vendor -q --locked vendor >/dev/null && mkdir -p .cargo && \
        printf '\n[source.crates-io]\nreplace-with = "vendored-sources"\n\n[source.vendored-sources]\ndirectory = "vendor"\n' >> .cargo/config.toml)
    rm -rf ${SRC}/muxtastic/target ${SRC}/muxtastic/.git
    tar -C ${SRC} -cJf files/sources-muxtastic-${MUXTASTIC_REF}.tar.xz muxtastic
fi
if [ "${WITH_MUXTASTIC:-1}" = 1 ]; then
    install -D -m 0644 ${X}/muxtastic.service ${DIST}/etc/systemd/system/muxtastic.service
    install -D -m 0644 ${X}/muxtastic.toml ${DIST}/etc/muxtastic/muxtastic.toml
    # dongie's Mesh tab may edit the settings (group dongie, set at boot)
    if [ "${WITH_DONGIE:-1}" = 1 ]; then
        install -D -m 0644 ${X}/muxtastic.tmpfiles ${DIST}/usr/lib/tmpfiles.d/muxtastic.conf
    fi
    # not enabled: set tcp_host in /etc/muxtastic/muxtastic.toml, then
    # systemctl enable --now muxtastic
fi

# Leviculum (Reticulum in Rust; AGPL-3.0, https://codeberg.org/Lew_Palm/leviculum):
# lnsd (daemon, storage in RAM only), lnstatus (dongie's Reticulum tab) and
# loquax (LXMF messenger CLI; installed as lnmsg too, which dongie's LXMF
# notifications call). From the dongie-master branch of our mirror (upstream +
# local LXMF fixes) at LEVICULUM_REF. Installed, NOT enabled: needs your
# transport node in /etc/lnsd/config. Needs zig like muxtastic (mimalloc).
# LEVICULUM_PREBUILT=<dir> takes bin/{lnsd,lnstatus,loquax} + sources/*.tar.xz.
LEVICULUM_REPO=${LEVICULUM_REPO=https://github.com/derpyspike/leviculum.git}
if [ "${WITH_LEVICULUM:-1}" = 1 ] && [ -n "${LEVICULUM_PREBUILT}" ]; then
    mkdir -p files
    for b in lnsd lnstatus loquax; do
        install -D -m 0755 ${LEVICULUM_PREBUILT}/bin/$b ${DIST}/usr/local/bin/$b
    done
    install -m 0644 ${LEVICULUM_PREBUILT}/sources/*.tar.xz files/
elif [ "${WITH_LEVICULUM:-1}" = 1 ]; then
    command -v zig >/dev/null || python3 -m ziglang version >/dev/null 2>&1 || \
        { echo "build_extras: zig not found (pip install ziglang, or build with WITH_LEVICULUM=0)"; exit 1; }
    for t in git cargo; do
        command -v $t >/dev/null || { echo "build_extras: '$t' not found (or build with WITH_LEVICULUM=0)"; exit 1; }
    done
    SRC=$(pwd)/build/extras-leviculum
    ZCC=$(pwd)/scripts/zigcc-aarch64-musl
    rm -rf ${SRC} && mkdir -p ${SRC}/leviculum files
    # a pinned commit, not a tag: fetch exactly that one
    (cd ${SRC}/leviculum && git init -q && git remote add origin ${LEVICULUM_REPO} && \
        git fetch -q --depth 1 origin ${LEVICULUM_REF} && git checkout -q FETCH_HEAD)
    LEV_ENV="CC_aarch64_unknown_linux_musl=${ZCC} AR_aarch64_unknown_linux_musl=${ZCC}-ar \
        CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER=rust-lld \
        CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_RUSTFLAGS=-Ctarget-feature=+crt-static \
        CARGO_PROFILE_RELEASE_STRIP=symbols"
    # Leviculum pins its compiler in rust-toolchain.toml; inside its tree rustup
    # would switch to that one, which lacks the aarch64-musl target added for
    # dongie/muxtastic. Use the same toolchain as the other extras (tested with 1.100).
    if command -v rustup >/dev/null; then
        TC=$(cd / && rustup show active-toolchain 2>/dev/null | cut -d' ' -f1)
        if [ -n "${TC}" ]; then LEV_ENV="${LEV_ENV} RUSTUP_TOOLCHAIN=${TC}"; fi
    fi
    # no BLE and no I2P on the stick
    (cd ${SRC}/leviculum && env ${LEV_ENV} cargo build -q --release --locked --target aarch64-unknown-linux-musl \
        -p leviculum-cli --no-default-features --features compression,serial --bin lnsd --bin lnstatus)
    (cd ${SRC}/leviculum && env ${LEV_ENV} cargo build -q --release --locked --target aarch64-unknown-linux-musl \
        -p loquax --bin loquax)
    for b in lnsd lnstatus loquax; do
        install -D -m 0755 ${SRC}/leviculum/target/aarch64-unknown-linux-musl/release/$b ${DIST}/usr/local/bin/$b
    done
    # complete corresponding source (AGPL), with vendored dependencies
    (cd ${SRC}/leviculum && env ${LEV_ENV} cargo vendor -q --locked vendor-sources >/dev/null && mkdir -p .cargo && \
        printf '\n[source.crates-io]\nreplace-with = "vendored-sources"\n\n[source.vendored-sources]\ndirectory = "vendor-sources"\n' >> .cargo/config.toml)
    rm -rf ${SRC}/leviculum/target ${SRC}/leviculum/.git
    tar -C ${SRC} -cJf files/sources-leviculum-${LEVICULUM_REF}.tar.xz leviculum
fi
if [ "${WITH_LEVICULUM:-1}" = 1 ]; then
    # dongie's LXMF notifications call `lnmsg` (loquax's old name, same CLI)
    ln -sf loquax ${DIST}/usr/local/bin/lnmsg
    install -D -m 0755 ${X}/lnsd-setup ${DIST}/usr/local/sbin/lnsd-setup
    install -D -m 0640 ${X}/lnsd.config ${DIST}/etc/lnsd/config
    install -D -m 0644 ${X}/lnsd.sysusers ${DIST}/usr/lib/sysusers.d/lnsd.conf
    for u in lnsd.service lnsd-prune.service lnsd-prune.timer run-lnsd.mount run-lnmsg.mount; do
        install -D -m 0644 ${X}/$u ${DIST}/etc/systemd/system/$u
    done
    # not enabled: set the transport node in /etc/lnsd/config, then
    # systemctl enable --now lnsd
fi

# Tailscale (BSD-3-Clause): VPN to reach the stick from anywhere; dongie's
# web UI and dongie-ims' browser calls (HTTPS via `tailscale serve`) lean on
# it. Static binaries from pkgs.tailscale.com at TAILSCALE_VERSION, checked
# against TAILSCALE_SHA256. Installed and running, but not logged in: no auth
# key is ever put into the image. On the stick: tailscale up
# TAILSCALE_TGZ=<file> uses a tarball fetched elsewhere (the Nix flake does).
if [ "${WITH_TAILSCALE:-1}" = 1 ]; then
    TGZ=${TAILSCALE_TGZ:-$(pwd)/build/tailscale_${TAILSCALE_VERSION}_arm64.tgz}
    if [ ! -f "${TGZ}" ]; then
        command -v curl >/dev/null || { echo "build_extras: 'curl' not found (or build with WITH_TAILSCALE=0)"; exit 1; }
        mkdir -p "$(dirname ${TGZ})"
        curl -sSfL -o ${TGZ}.part https://pkgs.tailscale.com/stable/tailscale_${TAILSCALE_VERSION}_arm64.tgz
        mv ${TGZ}.part ${TGZ}
    fi
    echo "${TAILSCALE_SHA256}  ${TGZ}" | sha256sum -c --quiet - || \
        { echo "build_extras: ${TGZ} doesn't match TAILSCALE_SHA256"; exit 1; }
    T=$(mktemp -d)
    tar -C ${T} -xzf ${TGZ}
    TS=${T}/tailscale_${TAILSCALE_VERSION}_arm64
    install -D -m 0755 ${TS}/tailscaled ${DIST}/usr/sbin/tailscaled
    install -D -m 0755 ${TS}/tailscale ${DIST}/usr/bin/tailscale
    install -D -m 0644 ${TS}/systemd/tailscaled.service ${DIST}/etc/systemd/system/tailscaled.service
    install -D -m 0644 ${TS}/systemd/tailscaled.defaults ${DIST}/etc/default/tailscaled
    install -D -m 0644 ${X}/tailscale.LICENSE ${DIST}/usr/share/doc/tailscale/LICENSE
    rm -rf ${T}
    enable_unit tailscaled.service
fi

# systemd enables every unit on the first boot unless a preset says otherwise
if [ "${WITH_DONGIE:-1}" = 1 ] || [ "${WITH_MUXTASTIC:-1}" = 1 ]; then
    install -D -m 0644 ${X}/20-openstick-extras.preset \
        ${DIST}/usr/lib/systemd/system-preset/20-openstick-extras.preset
fi

if [ "${WITH_DONGIE:-1}" = 1 ]; then
    install -D -m 0644 ${X}/dongie.service ${DIST}/etc/systemd/system/dongie.service
    install -D -m 0644 ${X}/dongie-ims.service ${DIST}/etc/systemd/system/dongie-ims.service
    # dongie's VoWiFi switch: "off" there keeps systemd from starting dongie-ims
    install -D -m 0644 ${X}/dongie-ims-switch.conf ${DIST}/etc/systemd/system/dongie-ims.service.d/dongie.conf
    # dongie-ims VoLTE opens the modem's DATA6_CNTL as /dev/rpmsgN: keep ModemManager off it
    install -D -m 0644 ${X}/78-mm-ignore-rpmsg-ept.rules ${DIST}/etc/udev/rules.d/78-mm-ignore-rpmsg-ept.rules
    if [ "${WITH_TAILSCALE:-1}" = 1 ]; then
        # dongie as Tailscale operator: prefs + its HTTPS (tailscale serve) switch
        install -D -m 0644 ${X}/tailscaled-operator.conf ${DIST}/etc/systemd/system/tailscaled.service.d/dongie-operator.conf
    fi
    # root helper behind dongie's Update button (signed releases only; never enabled)
    install -D -m 0644 ${X}/dongie-update.service ${DIST}/etc/systemd/system/dongie-update.service
    # dongie's firewall (nftables, firewall = true in dongie.toml): loads the
    # rules at boot before the network
    install -D -m 0644 ${X}/dongie-firewall.service ${DIST}/etc/systemd/system/dongie-firewall.service
    install -D -m 0640 ${X}/dongie.toml ${DIST}/etc/dongie/config.toml
    install -D -m 0644 ${X}/dongie.sysusers ${DIST}/usr/lib/sysusers.d/dongie.conf
    install -D -m 0644 ${X}/dongie.tmpfiles ${DIST}/usr/lib/tmpfiles.d/dongie.conf
    install -D -m 0644 ${X}/50-dongie.rules ${DIST}/etc/polkit-1/rules.d/50-dongie.rules
    install -D -m 0440 ${X}/sudoers-dongie ${DIST}/etc/sudoers.d/dongie
    # check it with the visudo of the sudo that will read it: the image's
    # (classic sudo). The build host's may be sudo-rs (Ubuntu >= 25.10), whose
    # visudo rejects classic settings such as !syslog.
    CHROOT=${CHROOT=$(pwd)/rootfs}
    if [ -x ${CHROOT}/usr/sbin/visudo ] && [ "$(id -u)" = 0 ]; then
        cp ${DIST}/etc/sudoers.d/dongie ${CHROOT}/tmp/sudoers-dongie.check
        chroot ${CHROOT} qemu-aarch64-static /usr/sbin/visudo -cqf /tmp/sudoers-dongie.check
        rm -f ${CHROOT}/tmp/sudoers-dongie.check
    elif command -v visudo >/dev/null && visudo --version 2>&1 | grep -q '^visudo version'; then
        visudo -cqf ${DIST}/etc/sudoers.d/dongie
    else
        echo "build_extras: no classic visudo to check sudoers.d/dongie with, skipped"
    fi
    enable_unit dongie.service
    enable_unit dongie-firewall.service
    # dongie-ims is NOT enabled: registering for Wi-Fi calling moves the SIM's
    # calls to the stick. Turn on with: systemctl enable --now dongie-ims
    # (or, with a dongie that has it, the VoWiFi switch on the Mobile tab)
fi
