#!/bin/sh -e

DEBIAN_FRONTEND=noninteractive
DEBCONF_NONINTERACTIVE_SEEN=true

echo 'tzdata tzdata/Areas select Etc' | debconf-set-selections
echo 'tzdata tzdata/Zones/Etc select UTC' | debconf-set-selections
echo "locales locales/default_environment_locale select en_US.UTF-8" | debconf-set-selections
echo "locales locales/locales_to_be_generated multiselect en_US.UTF-8 UTF-8" | debconf-set-selections
rm -f "/etc/locale.gen"

apt update -qqy
apt upgrade -qqy
apt autoremove -qqy
# gt's libconfig: libconfig11 since Debian 13, libconfig9 in Debian 12
LIBCONFIG=libconfig9
apt-cache show libconfig11 >/dev/null 2>&1 && LIBCONFIG=libconfig11
# gpgv: dongie's Update button checks the release signature with it. Debian 13's
# apt uses sqv instead, so gpgv is no longer pulled in by default.
apt install -qqy --no-install-recommends \
    bridge-utils \
    dnsmasq \
    gpgv \
    iptables \
    iw \
    libqmi-utils \
    ${LIBCONFIG} \
    locales \
    modemmanager \
    netcat-traditional \
    network-manager \
    nftables \
    openssh-server \
    polkitd \
    qrtr-tools \
    rmtfs \
    sudo \
    systemd-timesyncd \
    tzdata \
    wireguard-tools \
    wpasupplicant \
    bash-completion \
    curl \
    ca-certificates \
    zram-tools \
    bc \
    ifupdown2 \
    mobile-broadband-provider-info \
    openresolv

# zram swap: 90 % of RAM, zstd (the pmOS kernel has it). The sticks have
# 384-512 MB and no other swap; zram only holds the compressed pages actually
# swapped out, so the real RAM it takes stays well below that.
# zram-tools >= 0.3.7 (Debian 13) uses PERCENT over SIZE when both are set.
printf 'ALGO=zstd\nPERCENT=90\nPRIORITY=100\n' > /etc/default/zramswap

# Cleanup
apt clean
rm -rf /var/lib/apt/lists/*
rm -f /etc/machine-id
rm -f /var/lib/dbus/machine-id
rm -f /etc/ssh/ssh_host_*
find /var/log -type f -delete

passwd -dl root

# Add user
adduser --disabled-password --comment "" user
# Set password
passwd user << EOD
1
1
EOD
# Add user to sudo group
usermod -aG sudo user

cat <<EOF >>/etc/bash.bashrc

l='ls --color=auto -lah'
ls='ls --color=auto'
ll='ls --color=auto -lh'
la='ls --color=auto -lAh'
alias cl='clear'
alias ip='ip --color'
alias bridge='bridge -color'
alias free='free -h'
alias df='df -h'
alias du='du -hs'

EOF

# journald limits: see configs/extras/journald-flash.conf (scripts/build_extras.sh)

# install dnsproxy
bash /install_dnsproxy.sh

systemctl mask systemd-networkd-wait-online.service

# Prevent the accidental shutdown by power button
sed -i 's/^#HandlePowerKey=poweroff/HandlePowerKey=ignore/' /etc/systemd/logind.conf

# Enable IPv4 and IPv6 forwarding (the bridge's NAT). Its own file: Debian 13
# no longer ships /etc/sysctl.conf (an upgrade from 12 saves an edited one as
# /etc/sysctl.conf.dpkg-bak, and forwarding is silently off afterwards).
printf 'net.ipv4.ip_forward=1\nnet.ipv6.conf.all.forwarding=1\n' > /etc/sysctl.d/99-openstick-forwarding.conf
