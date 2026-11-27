#!/bin/sh -e

CHROOT=${CHROOT=$(pwd)/rootfs}
# Debian 13. RELEASE=bookworm still works (setup.sh picks the libconfig it has).
# Tested in place on a UZ801 (2026-11-26): the pmOS kernel, modem (ModemManager
# 1.24, libqmi 1.36), Wi-Fi, hotspot, Tailscale, dongie and VoWiFi all work.
RELEASE=${RELEASE=trixie}
HOST_NAME=${HOST_NAME=openstick}

rm -rf ${CHROOT}

debootstrap --foreign --arch arm64 \
    --keyring /usr/share/keyrings/debian-archive-keyring.gpg ${RELEASE} ${CHROOT}

# static arm64 emulator: qemu-aarch64-static (older distros) or qemu-aarch64
# (qemu-user-binfmt, Ubuntu >= 25.10 / Debian >= 13), copied in under the old
# name so the chroot calls below stay the same
QEMU=$(command -v qemu-aarch64-static || command -v qemu-aarch64) || \
    { echo "debootstrap: no qemu-aarch64(-static) found"; exit 1; }
cp "${QEMU}" ${CHROOT}/usr/bin/qemu-aarch64-static

chroot ${CHROOT} qemu-aarch64-static /bin/bash /debootstrap/debootstrap --second-stage

cat << EOF > ${CHROOT}/etc/apt/sources.list
deb http://deb.debian.org/debian ${RELEASE} main contrib non-free-firmware
deb http://deb.debian.org/debian-security/ ${RELEASE}-security main contrib non-free-firmware
deb http://deb.debian.org/debian ${RELEASE}-updates main contrib non-free-firmware
EOF

mount -t proc proc ${CHROOT}/proc/
mount -t sysfs sys ${CHROOT}/sys/
mount -o bind /dev/ ${CHROOT}/dev/
mount -o bind /dev/pts/ ${CHROOT}/dev/pts/
mount -o bind /run ${CHROOT}/run/

# chroot setup
cp configs/install_dnsproxy.sh ${CHROOT}
cp scripts/setup.sh ${CHROOT}
chroot ${CHROOT} qemu-aarch64-static /bin/sh -c /setup.sh

# cleanup
for a in proc sys dev/pts dev run; do
    umount ${CHROOT}/${a}
done;

rm ${CHROOT}/install_dnsproxy.sh
rm -f ${CHROOT}/setup.sh
echo -n > ${CHROOT}/root/.bash_history

echo ${HOST_NAME} > ${CHROOT}/etc/hostname
sed -i "/localhost/ s/$/ ${HOST_NAME}/" ${CHROOT}/etc/hosts

# setup dnsmasq
cp -a configs/dhcp.conf ${CHROOT}/etc/dnsmasq.d/dhcp.conf

cat <<EOF > ${CHROOT}/etc/resolv.conf
search lan
nameserver 127.0.0.1
options edns0 trust-ad
EOF

cat <<EOF >> ${CHROOT}/etc/hosts

192.168.100.1	${HOST_NAME}
EOF

# add rc-local
cp -a configs/rc.local ${CHROOT}/etc/rc.local
chmod +x ${CHROOT}/etc/rc.local

# add interfaces (ifupdown2)
cp -a configs/interfaces ${CHROOT}/etc/network/

# add MSM8916 USB gadget
cp -a configs/msm8916-usb-gadget.sh ${CHROOT}/usr/sbin/
cp configs/msm8916-usb-gadget.conf ${CHROOT}/etc/

# setup systemd services
cp -a configs/system/* ${CHROOT}/etc/systemd/system

cp -a scripts/msm-firmware-loader.sh ${CHROOT}/usr/sbin

# setup NetworkManager
cp configs/*.nmconnection ${CHROOT}/etc/NetworkManager/system-connections
chmod 0600 ${CHROOT}/etc/NetworkManager/system-connections/*
cp configs/99-custom.conf ${CHROOT}/etc/NetworkManager/conf.d/

# install kernel: postmarketOS linux-postmarketos-qcom-msm8916 6.12.1-r5.
# pmOS 'main' only keeps the newest build (it dropped -r5 for -r7), so take
# it from the v26.06 release branch, and check it: the apk isn't otherwise
# verified here. KERNEL_APK=<file> uses a local copy instead of downloading.
KERNEL_URL=${KERNEL_URL=https://mirror.postmarketos.org/postmarketos/v26.06/aarch64/linux-postmarketos-qcom-msm8916-6.12.1-r5.apk}
KERNEL_SHA256=${KERNEL_SHA256=0dba1a1da6c271d335ce0790fcc9503e4bff164ea5601e75da6337600174b5c8}
if [ -z "${KERNEL_APK}" ]; then
    KERNEL_APK=$(pwd)/build/kernel.apk
    mkdir -p build
    wget -q -O ${KERNEL_APK} ${KERNEL_URL}
fi
echo "${KERNEL_SHA256}  ${KERNEL_APK}" | sha256sum -c -
tar xkzf ${KERNEL_APK} -C ${CHROOT} --exclude=.PKGINFO --exclude=.SIGN* 2>/dev/null

# The pmOS package ships modules.alias and modules.symbols empty (postmarketOS
# regenerates them when the package is installed). Without them the kernel
# loads no module by alias: USB gadget functions, nftables, the modem and
# Wi-Fi drivers. Rebuild the index with the image's own depmod.
KVER=$(ls ${CHROOT}/lib/modules | head -1)
chroot ${CHROOT} qemu-aarch64-static /sbin/depmod -a ${KVER}
[ -s ${CHROOT}/lib/modules/${KVER}/modules.alias ] || \
    { echo "debootstrap: modules.alias for ${KVER} is still empty"; exit 1; }

mkdir -p ${CHROOT}/boot/extlinux
cp configs/extlinux.conf ${CHROOT}/boot/extlinux

# copy custom dtb's
cp dtbs/* ${CHROOT}/boot/dtbs/qcom/

# create missing directory
mkdir -p ${CHROOT}/lib/firmware/msm-firmware-loader

# update fstab
# noatime + 30 s ext4 commit interval: fewer flash writes (root is remounted
# with these options by systemd-remount-fs)
cat <<EOF > ${CHROOT}/etc/fstab
PARTUUID=a7ab80e8-e9d1-e8cd-f157-93f69b1d141e	/	ext4	noatime,commit=30,errors=remount-ro	0 1
PARTUUID=80780b1d-0fe1-27d3-23e4-9244e62f8c46	/boot	ext2	noatime	0 2
EOF

# list of Debian packages + versions in the image (for license/source lookups)
mkdir -p files
chroot ${CHROOT} qemu-aarch64-static /usr/bin/dpkg-query -W -f '${Package}\t${Version}\n' > files/packages.manifest

# backup rootfs
tar cpzf rootfs.tgz --exclude="usr/bin/qemu-aarch64-static" -C rootfs .

cat <<EOF > ${CHROOT}/etc/resolv.conf
nameserver 1.1.1.1
EOF
