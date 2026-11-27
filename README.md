# OpenStick Image Builder
Image builder for MSM8916 based 4G modem dongles

This builder uses the precompiled [kernel](https://pkgs.postmarketos.org/package/master/postmarketos/aarch64/linux-postmarketos-qcom-msm8916) provided by [postmarketOS](https://postmarketos.org/) for Qualcomm MSM8916 devices.

> [!NOTE]
> This branch generates a `debian` image, use the [alpine branch](https://github.com/kinsamanka/OpenStick-Builder/tree/alpine) for an `alpine` image.

## Build Instructions
### Build locally
This has been tested to work on **Ubuntu 22.04**
- clone
  ```shell
  git clone --recurse-submodules https://github.com/LongQT-sea/OpenStick-Builder.git
  cd OpenStick-Builder/
  ```
#### Quick
- build
  ```shell
  cd OpenStick-Builder/
  sudo ./build.sh
  ```
#### Detailed
- install dependencies
  ```shell
  sudo scripts/install_deps.sh
  ```
- build hyp and lk2nd

  these custom bootloader allows basic support for `extlinux.conf` file, similar to u-boot and depthcharge.
  ```shell
  sudo scripts/build_hyp_aboot.sh
  ```
- extract Qualcomm firmware

  extracts the bootloader and creates a new partition table that utilizes the full emmc space
  ```shell
  sudo scripts/extract_fw.sh
  ```
- create rootfs using debootstrap (Debian 13 "trixie"; `RELEASE=bookworm` for Debian 12)
  ```shell
  sudo scripts/debootstrap.sh
  ```

- build gadget-tools
  ```shell
  sudo scripts/build_gt.sh
  ```
- stage extras (see [Extras](#extras))

  needs `git`, `cargo` (with `rustup target add aarch64-unknown-linux-musl`) and `go` >= 1.26 for dongie, plus `zig` (or `pip install ziglang`) and `cmake` for muxtastic, `zig` for Leviculum; or skip them with `WITH_DONGIE=0` / `WITH_MUXTASTIC=0` / `WITH_LEVICULUM=0`
  ```shell
  sudo scripts/build_extras.sh
  ```
- create images
  ```shell
  sudo scripts/build_images.sh
  ```

The generated firmware files will be stored under the `files` directory

### With Nix
The [`flake.nix`](flake.nix) builds the [extras](#extras) without apt or toolchains on the host. The dongie versions come from [`configs/extras/dongie-versions`](configs/extras/dongie-versions), the same file `build_extras.sh` reads.
```shell
nix build .#dongie     # result/bin/{dongie,dongie-ims} (static aarch64) + result/sources/*.tar.xz
nix build .#extras     # result/rootfs: everything the extras add to the image (to inspect), result/files: source archives
nix develop            # Rust (aarch64-musl) + Go toolchains, shellcheck, actionlint
```
To use the Nix-built dongie in an image build (the image itself still needs the scripts, as root):
```shell
sudo DONGIE_PREBUILT=$(nix build --print-out-paths .#dongie) ./build.sh
```

### On the cloud using Github Actions
1. Fork this repo
2. Run the [Build workflow](../../actions/workflows/build.yml)
   - click and run ***Run workflow***
   - once the workflow is done, click on the workflow summary and then download the resulting artifact

## Customizations
Edit [`scripts/setup.sh`](scripts/setup.sh) to add/remove packages. Note that this script is running inside the `chroot` environment.

## Extras
[`scripts/build_extras.sh`](scripts/build_extras.sh) adds these to the image. Each one can be left out by setting its variable to `0` when building, e.g. `sudo WITH_DONGIE=0 ./build.sh`.

| | variable | what it does |
| --- | --- | --- |
| fix-attach-apn | `WITH_FIX_ATTACH_APN` | The UZ801 modem firmware resets its LTE attach APN to `mobile.three.com.hk` (Three Hong Kong) at every modem boot, so some networks never register on LTE. At boot this sets the right APN for the inserted SIM (table in the script, extend it in `/etc/default/fix-attach-apn`). Unknown SIMs are left alone. |
| dongie-leds | `WITH_LEDS` | Status LEDs. WAN LED: on = LTE connected, slow blink = searching/connecting, off = no service. WLAN LED: on = Tailscale running (if installed), otherwise Wi-Fi up (hotspot or client). Without it all LEDs just stay on. LEDs are found by name (UZ801, JZ01-45, MF800, HMUF02); override in `/etc/default/dongie-leds`. Polls every 5 s with one `busctl` call and sysfs: about 1 % of one core on a UZ801 (the old `mmcli`/`nmcli` version: 4 %). |
| flash tweaks | `WITH_FLASH_TWEAKS` | Small journal (32 MB), NetworkManager/ModemManager logging at WARN. Together with `noatime,commit=30` in `/etc/fstab`: about 8 KiB/min of writes when idle. |
| [Tailscale](https://tailscale.com) | `WITH_TAILSCALE` | VPN to reach the stick from anywhere; dongie's web UI and dongie-ims' calls in the browser (HTTPS via `tailscale serve`) use it. Static binaries from pkgs.tailscale.com at `TAILSCALE_VERSION`, checked against `TAILSCALE_SHA256` (both in [`configs/extras/dongie-versions`](configs/extras/dongie-versions)). Running but **not logged in**: run `sudo tailscale up` on the stick, then add its Tailscale IP to dongie's web addresses (Settings). The image makes `dongie` the Tailscale operator (a `tailscaled` drop-in runs `tailscale set --operator=dongie`), so the dashboard can read Tailscale's settings and, from the next dongie release, switch HTTPS (`tailscale serve`, tailnet only) on and off. A later `tailscale up` with other flags then needs `--operator=dongie` added, or use `tailscale set`. Adds 73 MB to the rootfs; logged out it takes ~9 MB of RAM and 0.3 % CPU on a UZ801 (measured). |
| [dongie-rs](https://github.com/derpyspike/dongie-rs) | `WITH_DONGIE` | Web dashboard + API: signal and cells, SMS and contacts, hotspot and Wi-Fi settings, network selection, WireGuard tunnels (edit peers, create tunnels), notifications (ntfy, webhook, Meshtastic, LXMF), services with RAM/CPU/network, settings from the web UI, Mesh tab for muxtastic, update check with an Update button (installs only releases signed with the maintainer's GPG key, rolls back if the new version doesn't start). |
| [dongie-ims](https://github.com/derpyspike/dongie-ims) | `WITH_DONGIE` | Wi-Fi calling (VoWiFi over the LTE data connection): receive and make calls in the browser, SMS over IMS. Installed but **off**, see below. |
| [muxtastic](https://github.com/derpyspike/muxtastic) | `WITH_MUXTASTIC` | Shares one Meshtastic node (with Wi-Fi, joined to the stick's hotspot) between several apps; history in RAM only. Shown on dongie's Mesh tab. Installed but **off**, see below. |
| [Leviculum](https://codeberg.org/Lew_Palm/leviculum) | `WITH_LEVICULUM` | Reticulum in Rust: `lnsd` (daemon, a plain client of your transport node, storage in RAM only: 12 MB tmpfs, pruned every 5 min), `lnstatus` (dongie's Reticulum tab) and `loquax` (LXMF messenger CLI, also as `lnmsg` for dongie's LXMF notifications). From the `dongie-master` branch of [github.com/derpyspike/leviculum](https://github.com/derpyspike/leviculum) (upstream + two local LXMF fixes) at `LEVICULUM_REF`. Installed but **off**, see below. lnsd measured at 5.5-12 MB RSS on a UZ801. |

WireGuard needs no extra: the kernel module and `wireguard-tools` are in every image, and NetworkManager runs WireGuard tunnels itself (dongie's WireGuard tab edits them).

dongie-rs, dongie-ims and muxtastic are built from source at the tags in [`configs/extras/dongie-versions`](configs/extras/dongie-versions) (`DONGIE_RS_REF`, `DONGIE_IMS_REF`, `MUXTASTIC_REF`). muxtastic has C parts (SQLite, aws-lc), cross-compiled with zig ([`scripts/zigcc-aarch64-musl`](scripts/zigcc-aarch64-musl)); the Nix flake doesn't build it yet, `MUXTASTIC_PREBUILT=<dir>` (`bin/muxtastic`, `sources/*.tar.xz`) takes one built elsewhere. Leviculum is built the same way from the commit `LEVICULUM_REF`; `LEVICULUM_PREBUILT=<dir>` (`bin/{lnsd,lnstatus,loquax}`, `sources/*.tar.xz`) takes binaries built elsewhere.

## Firmware Installation
> [!WARNING]  
> The following commands can potentially brick your device, making it unbootable. Proceed with caution and at your own risk!

> [!IMPORTANT]  
> Make sure to perform a backup of the original firmware using the command `edl rf orig_fw.bin`

### Prerequisites
- [EDL](https://github.com/bkerler/edl)
- Android fastboot tool
  ```
  sudo apt install fastboot
  ```

### Steps
- Ensure that your device is running the stock firmware
- Enter Qualcom EDL mode using this [guide](https://wiki.postmarketos.org/wiki/Zhihe_series_LTE_dongles_(generic-zhihe)#How_to_enter_flash_mode)
- Backup required partitions

  The following files are required from the original firmware:

     - `fsc.bin`
     - `fsg.bin`
     - `modem.bin`
     - `modemst1.bin`
     - `modemst2.bin`
     - `persist.bin`
     - `sec.bin`

  Skip this step if these files are already present
  ```shell
  for n in fsc fsg modem modemst1 modemst2 persist sec; do
      edl r ${n} ${n}.bin
  done
  ```
- Install `aboot`
  ```shell
  edl w aboot aboot.mbn
  ```
- Reboot to fastboot
  ```shell
  edl e boot
  edl reset
  ```
- Flash firmware
  ```shell
  fastboot flash partition gpt_both0.bin
  fastboot flash aboot aboot.mbn
  fastboot flash hyp hyp.mbn
  fastboot flash rpm rpm.mbn
  fastboot flash sbl1 sbl1.mbn
  fastboot flash tz tz.mbn
  fastboot flash boot boot.bin
  fastboot flash rootfs rootfs.bin
  ```
- Restore original partitions
  ```shell
  for n in fsc fsg modem modemst1 modemst2 persist sec; do
      fastboot flash ${n} ${n}.bin
  done
  ```
- Reboot
  ```shell
  fastboot reboot
  ```

## Post-Install
- Network configuration
  
  |  | |
  | ----- | ---- |
  | ssid | 4G-UFI-XX |
  | password | 1234567890 |
  | ip addr | 192.168.100.1 |

- Default user
  
  | | |
  | ----- | ---- |
  | username | user |
  | password | 1 |
 
- CPU idle is off (`cpuidle.off=1` in `/boot/extlinux/extlinux.conf`). Some
  sticks hang early in boot, before userspace, as soon as a core enters PSCI
  power collapse (seen on one UZ801 with the same SoC revision and firmware as
  two that run fine). Idle cores then wait in WFI instead, a few dozen mW more.
  To try it on a stick that is known to be fine, remove `cpuidle.off=1` and reboot.

- If your device is not based on **UZ801**, modify `/boot/extlinux/extlinux.conf` to use the correct devicetree
  ```shell
  sed -i 's/yiming-uz801v3/<BOARD>/' /boot/extlinux/extlinux.conf
  ```

  where `<BOARD>` is
     - `thwc-uf896` for **UF896** boards
     - `thwc-ufi001c` for **UFIxxx** boards
     - `jz01-45-v33` for **JZxxx** boards
     - `fy-mf800` for **MF800** boards


- To update the kernel of the `debian` image
- Get the kernel link from: http://mirror.postmarketos.org/postmarketos/master/aarch64/

  ```shell
  wget -O - http://mirror.postmarketos.org/postmarketos/master/aarch64/linux-postmarketos-qcom-msm8916-6.12.1-r2.apk \
          | tar xkzf - -C / --exclude=.PKGINFO --exclude=.SIGN* 2>/dev/null
  ```

- dongie dashboard (if built with extras)

  create a login, then open http://192.168.100.1:8040 (Wi-Fi hotspot or USB)
  ```shell
  sudo dongie user add <name>
  ```
  The unauthenticated API and the dashboard without login are off in this image; see `/etc/dongie/config.toml`.

- Wi-Fi calling (dongie-ims) is off by default: once it registers, calls to the SIM's number ring on the stick (and in the dongie dashboard) instead of a phone with that SIM. Turn it on with
  ```shell
  sudo systemctl enable --now dongie-ims
  ```
  It needs an unlocked SIM: if the SIM has a PIN, enter it on dongie's Mobile tab first. From the next dongie release, the Mobile tab also has a VoWiFi on/off switch (remembered across reboots).

- muxtastic is off by default: it needs the address of your Meshtastic node (Wi-Fi on, joined to the stick's hotspot). Set `tcp_host` in `/etc/muxtastic/muxtastic.toml` (it suggests a fixed `dhcp-host` lease outside the DHCP pool), then
  ```shell
  sudo systemctl enable --now muxtastic
  ```
  Apps connect to the stick on port 4404, the web UI (no login) is on port 8090, from the hotspot/USB or Tailscale; the service drops both ports on the LTE side (`wwan*`) while it runs. dongie's Mesh tab shows a summary behind dongie's login and (from dongie 0.2) edits node address, admin allowlist and history, and starts/stops muxtastic.

- Reticulum (Leviculum `lnsd`) is off by default: it needs your transport node. Set `target_host` / `target_port` in `/etc/lnsd/config`, then
  ```shell
  sudo systemctl enable --now lnsd
  ```
  The first start generates the stick's `rpc_key` (also given to dongie for its Reticulum tab). lnsd keeps everything in RAM (`/run/lnsd`); only dongie's LXMF sender identity is on flash. dongie can then send notifications over LXMF (`[[notify]] kind = "lxmf"`).

## License
The build scripts in this repository are MIT-licensed (see `LICENSE`).

The boot firmware files `rpm.mbn`, `sbl1.mbn` and `tz.mbn` are **not** covered
by the MIT license: they are proprietary binaries from the DragonBoard 410c
bootloader package, redistributed in binary form under the terms in
`LICENSE.qcom-db410c`, which is included with every build and release.

The generated images are an aggregate of separately licensed works, each under
its own license, among them:
- Debian packages (various licenses; exact versions in `packages.manifest` next
  to the images, sources at [snapshot.debian.org](https://snapshot.debian.org/))
- the Linux kernel (GPL-2.0), the postmarketOS package
  `linux-postmarketos-qcom-msm8916`, source via
  [postmarketOS](https://pkgs.postmarketos.org/package/master/postmarketos/aarch64/linux-postmarketos-qcom-msm8916)
- lk2nd, qhypstub, gt and libusbgx (git submodules in `src/`)
- extras: fix-attach-apn, dongie-leds and the dongie configs (EUPL-1.2, SPDX headers),
  dongie-rs (EUPL-1.2), dongie-ims (GPL-3.0), muxtastic
  (AGPL-3.0-or-later) and Leviculum (AGPL-3.0, with two local patches); their
  complete source, including vendored dependencies, is in `sources-dongie-*.tar.xz`,
  `sources-muxtastic-*.tar.xz` and `sources-leviculum-*.tar.xz` next to the images
- Tailscale (BSD-3-Clause, unmodified release binaries; license in
  `/usr/share/doc/tailscale/LICENSE`, the licenses of its dependencies at
  [tailscale.com/licenses/tailscale](https://tailscale.com/licenses/tailscale),
  source at [github.com/tailscale/tailscale](https://github.com/tailscale/tailscale))
