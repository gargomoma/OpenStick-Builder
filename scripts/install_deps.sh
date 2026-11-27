#!/bin/sh -e

apt update

# arm64 emulation for the rootfs chroot. Ubuntu >= 25.10 and Debian >= 13 no
# longer have qemu-user-static: there qemu-user-binfmt brings a static
# qemu-aarch64 and registers it with the F flag (works inside the chroot).
if apt-cache policy qemu-user-static | grep -q 'Candidate: [0-9]'; then
    QEMU_PKG=qemu-user-static
else
    QEMU_PKG=qemu-user-binfmt
fi

apt install -y \
    android-sdk-libsparse-utils \
    autoconf \
    automake \
    binfmt-support \
    cmake \
    debian-archive-keyring \
    debootstrap \
    device-tree-compiler \
    fdisk \
    g++-aarch64-linux-gnu \
    gcc-aarch64-linux-gnu \
    gcc-arm-none-eabi \
    libtool \
    make \
    pkg-config \
    python3-cryptography \
    python3-pyasn1-modules \
    python3-pycryptodome \
    ${QEMU_PKG} \
    unzip \
    wget 

# make sure the arm64 handler is registered (systemd-binfmt reads binfmt.d)
if [ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ] && command -v systemctl >/dev/null; then
    systemctl restart systemd-binfmt || true
fi
