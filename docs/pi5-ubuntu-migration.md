# Migration Review: Raspberry Pi 5 + Ubuntu (official image)

Status: **draft / review**. This is the first pass, written from the code alone and not yet checked on hardware.
Items marked **(verify)** need to be confirmed on a real Pi 5 running the Ubuntu image.

## 1. Where we are today

The firmware assumes a specific 2017–2018 stack:

| Area | Today | Evidence |
|---|---|---|
| Board | Raspberry Pi 3 (BCM2837) | `rc.local` unbinds `3f201000.serial`, `pi3-disable-bt`, `i2c-bcm2708` |
| OS | Raspbian **Stretch**, 32-bit **armhf** | `scripts/gplan-init-build.sh` (2017-11-29 image), `src/bbserial/Makefile` (`arm-linux-gnueabihf`, `bcm2709_defconfig`, kernel 2017-10-29) |
| Init | sysvinit leftovers + `rc.local` | `setup_rpi.sh`, `scripts/rc.local`, `scripts/resize2fs_once` |
| Display | X11 + ratpoison + Chromium deb, legacy firmware framebuffer | `scripts/xinitrc`, `scripts/browser`, `config-screen` (`framebuffer_*`, `display_rotate`), `tvservice` |
| Network | ifupdown + dhcpcd + wpa_supplicant + hostapd/dnsmasq | `scripts/config-wifi` |
| GPIO | `RPi.GPIO` + wiringPi `gpio` CLI | `scripts/avr109-flash.py`, `scripts/rc.local` |
| Python | system `pip3 install` + `setup.py install`, `pkg_resources` | `scripts/install.sh`, `src/py/bbctrl/__init__.py`, `Config.py`, `Log.py` |
| Native code | `bbserial.ko` (out-of-tree kernel module), `gplan.so` (CAMotics C++ planner, armhf) | `src/bbserial/`, `Makefile` `gplan` target |
| Update path | tarball → `update-bbctrl` → `scripts/install.sh` edits the live OS | `scripts/update-bbctrl`, `scripts/install.sh` |

Target: **Raspberry Pi 5 (BCM2712 + RP1 I/O chip), Ubuntu 26.04 LTS arm64** (Server image as the base. See §4.1).

The Pi 5 changes the I/O architecture. GPIO, UART, I²C and SPI no longer sit on the SoC. They are behind the **RP1** chip on PCIe.
Anything that touches registers or BCM2835 addresses directly breaks: `bbserial`, `RPi.GPIO`, wiringPi, and the hard-coded device names.

## 2. Blockers (nothing works until these are solved)

| # | Item | Why it breaks | Direction |
|---|---|---|---|
| B1 | **`bbserial` kernel module** (`src/bbserial/`) | Built for a 2017 32-bit kernel. Uses kernel APIs that have since changed: `class_create(THIS_MODULE, …)` takes only a name since 6.4, and amba `.remove` returns `void` since 5.13. Must be arm64 and match Ubuntu's `linux-raspi` kernel. Ubuntu kernel updates will break a prebuilt `.ko`. | See §3.1. Recommend first testing whether the stock `amba-pl011` driver with RTS/CTS is good enough; otherwise port + DKMS. |
| B2 | **UART binding** (`scripts/rc.local`) | `echo 3f201000.serial > …/unbind` is a Pi 3 address. On Pi 5 the PL011 UARTs are RP1 devices with different names and IDs **(verify)**, and `ttyAMA0` naming differs (the debug header is `ttyAMA10`). | Bind by device tree / overlay, not a hard-coded address. Add a udev symlink such as `/dev/onefinity-avr` and pass it via `bbctrl -s`. |
| B3 | **CTS pin mux** (`gpio mode 27 alt3`) | Uses wiringPi numbering (wPi 27 = BCM 16 = CTS0 on Pi 3). wiringPi is not available on Ubuntu or the Pi 5. | Use the UART overlay with `ctsrts` in `config.txt` **(verify exact overlay/pins for RP1 UART0)**. Use `pinctrl` only for debugging. |
| B4 | **AVR reset for flashing** (`scripts/avr109-flash.py`) | `RPi.GPIO` does not support the Pi 5 (no `/dev/gpiomem` BCM2835 block). | Port to `gpiod` (libgpiod v2 Python bindings, `python3-libgpiod`) or `lgpio`/`gpiozero`. Look up the chip by label (`pinctrl-rp1`), not by `gpiochipN`, because the number changed across kernel versions. |
| B5 | **`gplan.so`** (`Makefile`, `scripts/gplan-*.sh`) | 32-bit armhf binary linked against Stretch's Python 3.5 ABI. cbang and CAMotics are pinned to 2017 commits, built with scons, and patched with `perl` regexes. | Rebuild for **aarch64** against the target Python (a CPython extension is tied to one minor version). Expect C++ fixes with GCC 14/15. See §3.5. |
| B6 | **Python install model** (`install.sh`) | Ubuntu enforces PEP 668, so `pip3 install` outside a venv fails. `setup.py install` is deprecated. `pkg_resources` is deprecated and being removed from setuptools. The bundled 2015-era `watchdog-v0.10.6` / `pathtools` tarballs won't build cleanly on modern Python. | Install into a venv (`/opt/onefinity/venv`), or as a `.deb`. Prefer Ubuntu packages (`python3-tornado`, `python3-serial`, `python3-pyudev`, `python3-smbus2`, `python3-watchdog`). Replace `pkg_resources` with `importlib.resources` / `importlib.metadata`. |
| B7 | **Kiosk browser** (`xinitrc`, `browser`, `rc.local`) | On Ubuntu `chromium-browser` is a **snap**, so `/usr/lib/chromium-browser/chromium-browser` doesn't exist. `browser` writes to cgroup-v1 `/sys/fs/cgroup/memory/chrome/tasks`, which doesn't exist on cgroup-v2, so the browser never starts. `tvservice` doesn't exist under KMS. There is no `pi` user. | See §4.3. Use a Wayland kiosk compositor (`cage`, or `ubuntu-frame`) running Chromium under a systemd unit. Apply memory limits with `MemoryMax=` in the unit. |
| B8 | **Boot config paths** | Ubuntu's firmware partition is **`/boot/firmware/`** (`config.txt`, `cmdline.txt`). Hard-coded `/boot/config.txt` in `Web.py` (`ScreenRotationHandler`), `edit-boot-config`, `install.sh`, `resize_root_fs.sh`, `rc.local`. | Introduce one `BOOT_DIR` setting. Remove the `mount -o remount,ro /boot` logic, which doesn't apply. |
| B9 | **Networking / WiFi** (`scripts/config-wifi`, `Web.py`, `iw_parse`) | Ubuntu uses netplan with systemd-networkd or NetworkManager. `/etc/network/interfaces`, `dhcpcd.conf` and `iwlist` (wireless-tools) are not there. | Rewrite `config-wifi` on **NetworkManager** (`nmcli`). It handles client mode *and* the AP/hotspot mode, so hostapd, dnsmasq and the iptables rules go away. Replace `iwlist`/`iw_parse` with `nmcli -t -f SSID,SIGNAL,SECURITY dev wifi list`. |

## 3. Hardware / low-level details

### 3.1 Serial link to the main AVR (`bbserial`)

`bbserial.c` is a stripped-down PL011 driver with ring buffers. It exposes a char device named `ttyAMA0` and
`AVR.py` opens that device at 230400 baud. The firmware flasher uses 921600.

Options, in order of preference:

1. **Drop the custom driver.** Use the stock `amba-pl011` driver with `crtscts`, the `low_latency` flag (the code for this is already in `AVR.py`, `serial_set_low_latency`, but commented out), and a reasonable `FIFO`/IRQ trigger.
   The original reason for `bbserial` was tty-layer latency and lost bytes on a Pi 3 at 1.2 GHz. The Pi 5's A76 cores at 2.4 GHz may make this moot.
   **Action:** run a soak test (long G-code jobs, jogging, status flood) and count framing/overrun errors (`/proc/tty/driver/ttyAMA`).
2. **Port `bbserial` to a current kernel.** Make it a proper DT-bound driver with an overlay, build it with **DKMS** against `linux-raspi` headers so kernel upgrades rebuild it, and fix the API changes listed in B1.
   One thing to watch: on RP1 every MMIO read crosses PCIe (around 1 µs). The ISR polls `UART01x_FR` once per byte (`_tx`/`_rx` loops), so it costs much more than on the Pi 3.
   Consider reading RX in bursts using the FIFO level, or using the RIS/MIS bits.
3. Check that the amba peripheral-ID match (`0x00041011`) still matches the RP1 PL011 **(verify)**. If it doesn't, the driver silently never probes.

Either way, add a **startup self-test**: log which driver is bound and the baud rate, and fail loudly in the UI if the AVR doesn't answer.

### 3.2 I²C (LCD, AVR, power chip)

- `/dev/i2c-1` on GPIO 2/3 still exists on Pi 5 (`dtparam=i2c_arm=on`). `I2C.py` with `smbus2` should work unchanged.
- Remove `i2c-bcm2708` from `/etc/modules` and `bcm2708.vc_i2c_override=1` from cmdline. Both are Pi 3-only.
- An improvement: the BCM283x I²C controller had a clock-stretching bug. RP1 uses a DesignWare controller, which handles stretching correctly. Re-test the AVR and power-chip reads (`Pwr.py`), and consider removing any retry workarounds after the soak test.
- Install `python3-smbus2` (Ubuntu package). Drop the `smbus` fallback.

### 3.3 GPIO

| Use | Today | Pi 5 / Ubuntu |
|---|---|---|
| AVR reset (BCM 27) | `RPi.GPIO` | `gpiod` (v2 API), request line by chip label + offset |
| CTS mux (BCM 16) | `gpio mode 27 alt3` (wiringPi) | `config.txt` UART overlay with `ctsrts` |
| Debug | – | `pinctrl` (from `raspi-utils`, **verify** the Ubuntu package) |

### 3.4 Power, thermal, physical

- **Power budget:** the Pi 5 wants 5 V / 5 A for full USB current, and the controller board powers the Pi through the header.
  Measure the board's 5 V rail headroom (Pi 5 idle around 3 W, peak 10–12 W, plus touchscreen and USB camera).
  If the rail is limited, keep `usb_max_current_enable=0` and document the 600 mA USB limit. Replace `max_usb_current=1`, which is Pi 3-era and ignored on Pi 5.
- **Thermal:** the Pi 5 needs active cooling inside an enclosure. In `MonitorTemp.py`, `max_freq = 1200000` and `min_freq = 600000` are Pi 3 numbers. Read `cpuinfo_min_freq`/`cpuinfo_max_freq` instead of hard-coding (Pi 5 is about 1.5–2.4 GHz).
  Write to all policies, not only `cpu0`. Consider the Pi 5 fan curve (`dtparam=fan_temp*`) instead of software throttling.
- **Mechanical:** check the enclosure, header alignment and connector clearance (the Pi 5 moved the PoE header, added a fan connector, an RTC battery connector and PCIe FFC).
- **RTC:** the Pi 5 has an RTC (with a battery). That removes the reason for the `cron_d_reboot` / forced-logrotate hack for machines without network time.

### 3.5 GPlan (CAMotics planner)

- Today it is built in a qemu chroot of a 2017 Raspbian image (`rpi-chroot.sh` hard-codes partition offsets `4194304` / `48234496`).
- New approach: build **natively on arm64**. Use a GitHub Actions `ubuntu-24.04-arm` runner, or a Docker `--platform linux/arm64` image of the target Ubuntu release. That's faster and reproducible.
- Move to a current CAMotics/cbang release if the planner API is still compatible. Otherwise, fork with the `std::min` patches committed, instead of the `perl -i` edits in `gplan-build.sh`.
- `gplan.so` is tied to one CPython minor version, so build it for the exact Python version the image ships. Add a startup check that imports it and reports a clear error.

## 4. OS and system integration

### 4.1 Which Ubuntu image

- Canonical publishes Ubuntu 26.04 LTS Server and Desktop images for Raspberry Pi, including the Pi 5. 26.04.1 is out.
  Ubuntu notes that the Pi 5 needs a boot EEPROM dated **2025-02-11 or newer** for the current images. Plan for an EEPROM update step at the factory or in the docs.
- **Recommendation: Ubuntu Server 26.04 LTS arm64** plus a minimal kiosk. The Desktop image brings a full GNOME session, which is heavier, has more moving parts and more to lock down.
- Pin to the **LTS** (supported through 2031), not interim releases.

### 4.2 Users and accounts

- Ubuntu creates a `ubuntu` user (uid 1000) via cloud-init. The code assumes `pi` (X session, `/home/pi/...`) and `bbmc` (`Web.py: get_username()` looks up **uid 1001**).
  - Create service users explicitly with fixed uids, or better, look the user up by name.
  - Run the kiosk as a dedicated unprivileged `kiosk` user.
- **Password handling** (`Web.py: check_password/PasswordHandler`): forces MD5-crypt (`$1$`) via `openssl passwd -1` and `chpasswd -c MD5`. Ubuntu defaults to yescrypt.
  This will reject accounts created by the installer and is weak.
  Recommend separating the **web admin password** from the OS account (store a `hashlib.scrypt` hash in `/var/lib/bbctrl`), or verify through PAM.
- `chmod +s /sbin/{halt,reboot,shutdown,poweroff}` in `setup_rpi.sh` should go. `bbctrl` runs as root already. If it is de-rooted later, use polkit or `systemctl` rules.

### 4.3 Kiosk display

Ubuntu's Raspberry Pi graphics are **KMS-only**, and the Pi 5 only supports KMS. So:

- `display_rotate`, `framebuffer_width/height` (used by `config-screen` and `ScreenRotationHandler`) are ignored.
  Rotate via the compositor (`cage` / `wlr-randr --transform 180`, or `video=HDMI-A-1:...,rotate=180` on the kernel cmdline).
  Touch rotation: libinput calibration matrix via udev (`LIBINPUT_CALIBRATION_MATRIX`), not by patching `/usr/share/X11/xorg.conf.d/40-libinput.conf`.
- `tvservice` doesn't exist. The `xinitrc` loop currently degrades to "always start the browser", which is acceptable, but the check should be removed.
- Proposed stack: `cage` (Wayland single-app kiosk) + Chromium snap, started by a `onefinity-kiosk.service` systemd unit with `Restart=always`, `MemoryMax=750M` (replaces the cgroup-v1 code in `rc.local` and `browser`), and auto-login on tty1.
  - Alternative: Canonical's `ubuntu-frame` + `wpe-webkit-mir-kiosk` snaps. This is supported, but WPE is a different engine, so the UI needs re-testing.
  - Keep `--disable-3d-apis` under review. The Pi 5's V3D 7 is capable, and the 3D tool-path view (`three.min.js`) would benefit from it.
- The Chromium snap needs `snap refresh --hold` (see §4.6) and runs confined. `delete-cookies.py` and the `Preferences` crash-flag `sed` hack must target `~/snap/chromium/common/chromium/...` or move to `--user-data-dir`.
- Plymouth splash (`src/splash/`) works on Ubuntu. Drop `rpd-plym-splash` (a Raspberry Pi OS package).

### 4.4 Boot / init

Replace `rc.local` with systemd units:

| Today (`rc.local` / `install.sh`) | Replacement |
|---|---|
| Unbind pl011, `modprobe bbserial` | DT overlay + module autoload (`/etc/modules-load.d`) or none (stock driver) |
| `gpio mode 27 alt3` | `config.txt` overlay |
| cgroup for Chrome | `MemoryMax=` in kiosk unit |
| `/etc/init.d/udev restart` | Not needed (fix root cause) |
| `plymouth quit` + `sudo -u pi startx` | `onefinity-kiosk.service` (`After=plymouth-quit-wait.service`) |
| `resize_root_fs.sh` + `resize2fs_once` (raspi-config `init_resize.sh`) | **Delete.** cloud-init `growpart` already does this on Ubuntu. |
| `dphys-swapfile` `CONF_SWAPSIZE=1000` | **Delete.** Use `zram-tools`/`systemd-zram-generator` or a swapfile. Pi 5 ships with 4–16 GB RAM. |
| `cgroup_memory=1`, `dwc_otg.fiq_fsm_mask`, `sd_overclock`, `pi3-disable-bt`, `config_hdmi_boost`, `nohz=on` | **Delete.** Pi 3-only or no-ops on Pi 5 (USB is xHCI on RP1). |
| Editing `/etc/systemd/system/network-online.target.wants/networking.service` | **Delete.** It doesn't exist. Use `systemd-networkd-wait-online` overrides if needed. |

`bbctrl.service`: add `After=network-online.target` only if needed, plus `Restart=on-failure`, `RestartSec`.
Point `ExecStart` at the venv path. Consider `LogsDirectory=` / journald instead of `/var/log/bbctrl.log` + `copytruncate` logrotate.

### 4.5 USB automount (`11-automount.rules`)

Mounting from a udev `RUN+=` is unreliable under systemd (it was the reason for editing `systemd-udevd.service` `MountFlags`, which `install.sh` does and which is fragile across upgrades).
Replace it with `udisks2` + a small `udiskie`-style service, or `systemd-mount --automount` from the rule.

### 4.6 Things Ubuntu adds that a CNC controller must not have

- **`unattended-upgrades`**: can restart services or reboot mid-job. Disable it, or schedule it only while the machine is idle, with `Automatic-Reboot "false"`.
- **Snap auto-refresh**: would restart Chromium mid-job. Run `snap refresh --hold`, or set refresh timers controlled by the firmware.
- **cloud-init**: disable after first boot (`touch /etc/cloud/cloud-init.disabled`) so it doesn't reset hostname/users or regenerate netplan.
- **Kernel upgrades** vs. out-of-tree modules: DKMS, or `apt-mark hold linux-raspi` with an upgrade policy the firmware controls.
- **needrestart** prompts during `apt` in `install.sh`: set `NEEDRESTART_MODE=a` / `DEBIAN_FRONTEND=noninteractive`.

## 5. Application (Python) changes

| File | Change |
|---|---|
| `src/py/bbctrl/__init__.py`, `Config.py`, `Log.py` | `pkg_resources` → `importlib.resources.files('bbctrl')` / `importlib.metadata.version('bbctrl')` |
| `src/py/bbctrl/__init__.py` | Default `--serial` from config/udev symlink instead of `/dev/ttyAMA0` |
| `src/py/bbctrl/Web.py` | `/boot/config.txt` → `/boot/firmware/config.txt` (or drop rotation via `config.txt` entirely, §4.3). `iwlist` → `nmcli`. `sudo iw dev wlan0 info` → `nmcli`. uid-1001 lookup. Password handling (§4.2). `sudo timedatectl` → it runs as root, so drop `sudo`. |
| `src/py/bbctrl/Web.py` `RemoteDiagnosticsHandler` | Downloads a shell script from a tinyurl and runs it as root. Review this independently of the migration (pin the URL, verify a signature). |
| `src/py/bbctrl/MonitorTemp.py` | Frequencies from sysfs, all CPU policies (§3.4) |
| `src/py/bbctrl/AVR.py` | Decide on the `low_latency` ioctl. `serial_struct` uses `c_char_p`/`c_ulong`, which change size on arm64. That's fine if it mirrors the kernel struct, but **test** `TIOCGSERIAL` on arm64. |
| `src/py/bbctrl/v4l2.py`, `Camera.py` | ctypes structs (`timeval` with `c_long`) are arm64-correct, but test every ioctl. USB UVC cameras work. **Pi CSI cameras need libcamera** and won't work through this raw V4L2 path. |
| `Web.py` / `sockjs-tornado` | `sockjs-tornado` is unmaintained (last release 2019), isn't packaged for Ubuntu, and its compatibility with Tornado 6.4+ is unproven. Plan to move to Tornado's native `WebSocketHandler` and replace `sockjs.min.js` in `src/js/sock.js`. Keep SockJS for one release if needed. |
| `@gen.coroutine` users (`Preplanner.py`, `FileHandler.py`, `Web.py`) | Still works in Tornado 6. Migrate to `async def` opportunistically. |
| `inevent/` | Uses evdev ioctls via ctypes. Test the jog pendant / gamepad on arm64. |
| `scripts/config-wifi`, `sethostname` | `sethostname` → `hostnamectl set-hostname` (also handles `/etc/hosts` via `systemd-hostnamed`). Rewrite `config-wifi` for NetworkManager. |

## 6. Build, packaging and update path

### 6.1 Toolchain (build host / devcontainer)

- `.devcontainer`: Debian bullseye, `gcc-9`, `gcc-arm-linux-gnueabihf`, `qemu` → move to the same Ubuntu LTS as the target, with `gcc-aarch64-linux-gnu` (only if cross-building) and `qemu-user-static`.
- Node 18 (`nodesource setup_18.x`) is EOL → Node 22/24 LTS.
- `src/svelte-components`: `node-sass` (deprecated, won't build on current Node) → `sass`. `vite 3` → current. `svelte 3` → 4/5 (bigger change, separate track). The `@sveltejs/kit` pre-1.0 dependency appears unused, so remove it.
- `pug-cli 1.0.0-alpha6`, `browserify`, ESLint 8: work, but plan upgrades.
- `src/avr`, `src/boot`, `src/pwr`, `src/jig` (AVR code) are **not affected** by the Pi change. They only need `gcc-avr`/`avr-libc` on the build host.

### 6.2 Packaging

Today a `.tar.bz2` is untarred and `scripts/install.sh` rewrites system files on every update, assuming Raspbian.

Recommended:

1. Ship the controller as a **`.deb`** (or a venv tarball plus a `.deb` for system integration): systemd units, udev rules, config snippets, DKMS module, kiosk.
   Native code (`gplan.so`, `bbserial`) is built in CI for `arm64`.
2. Make the image itself **reproducible**: a script that takes the official Ubuntu preinstalled server image and applies our packages (e.g. with `systemd-nspawn`/qemu, or cloud-init `user-data` on first boot).
   That replaces `setup_rpi.sh` and `rpi-chroot.sh`.
3. Add a **platform guard** to the update path. A new firmware must refuse to install on a Pi 3 / Raspbian unit, and an old firmware must refuse to install on a Pi 5 / Ubuntu unit (check `/etc/os-release` + `/proc/device-tree/model` in `update-bbctrl` before running `install.sh`).
   Old firmware is in the field, so the guard must be in place **before** the first Pi 5 release.
   `upgrade-bbctrl` downloads `latest.txt` from `OneFinityCNC/onefinity-release`. Needs a separate channel or file per platform.

### 6.3 Support matrix decision

Decide early whether one codebase supports **both** Pi 3/Raspbian (existing customers) and Pi 5/Ubuntu.
The app layer can be shared. Everything in §2–§4 differs, so keep the platform-specific parts in `platform/rpi3-raspbian/` vs `platform/rpi5-ubuntu/`, or similar.

## 7. Suggested phases

1. **Bring-up spike (hardware):** flash Ubuntu 26.04 Server on a Pi 5, update the EEPROM, enable UART0 + CTS/RTS + I²C. Talk to the AVR from Python using the stock pl011 driver.
   Read the power chip and LCD over I²C. Toggle AVR reset with `gpiod`. Flash the AVR with a ported `avr109-flash.py`. → *Answers B1–B4 and the bbserial question.*
2. **Native builds:** arm64 CI for `gplan.so` (+ `bbserial` DKMS if still needed). Python packaging in a venv, `pkg_resources` removal.
3. **System integration:** systemd units, kiosk (cage + Chromium), NetworkManager WiFi/AP, boot-config path abstraction, automount, update guards, disabling unattended upgrades and snap refresh.
4. **Soak and regression:** multi-hour jobs, jog latency, status throughput, thermal under enclosure, power rail measurements, camera, USB stick, WiFi AP mode, firmware update round-trip.
5. **Release engineering:** image build pipeline, separate update channel, docs (`docs/development.md` still describes Debian 9 and Node 13).

## 8. Open questions

- Is there a hardware revision of the controller board for the Pi 5 (power budget, header pinout and reset line unchanged)?
- Must Pi 3 units in the field keep receiving updates from the same codebase?
- Was `bbserial` written to fix a measured problem (lost bytes or latency)? Is there a test that reproduces it?
- Keep Chromium, or accept a WPE-based kiosk (Ubuntu Frame) for a supported Canonical kiosk stack?
- Will the camera stay USB-only, or should Pi CSI cameras be supported (libcamera)?

## 9. Progress

Hardware-independent changes are landing first. Each one keeps working on Pi 3 / Raspbian Stretch (Python 3.5).

| Item | Status |
|---|---|
| B4: AVR reset via libgpiod v2, `RPi.GPIO` fallback | Done (PR #1) |
| B6 (part): `pkg_resources` removed from resource and version lookups | Done (PR #1) |
| §6.2.3: update-path platform guard (`PLATFORMS`, `scripts/onefinity-platform`, `update-bbctrl`, `install.sh`) | Done |
| B8 (part): boot dir detection in `edit-boot-config` and `Web.py` | Done |
| §3.4: `MonitorTemp.py` reads CPU frequency limits from sysfs, writes all policies | Done |
| Invalid escape sequences (errors on newer Python) in `Web.py`, `iw_parse.py` | Done |
| B9: WiFi on NetworkManager (`config-wifi` backend, `bbctrl/wifi.py` scan and status) | Done |
| B7, §4.3, §4.4, §4.6: systemd units, cage + Chromium kiosk, Ubuntu system setup (`platform/ubuntu-arm64/`) | Done, not yet called by an Ubuntu install path |

The platform guard has two halves. Both are needed because units in the field run their *installed* `update-bbctrl`, which executes the *new* package's `install.sh`:

- **Package side:** `install.sh` aborts (and restarts `bbctrl`) when the device platform is not listed in the package's `PLATFORMS` file. This protects existing Pi 3 units from Pi 5 packages.
- **Device side:** `update-bbctrl` checks `PLATFORMS` before stopping `bbctrl`. A package without the file is treated as `raspbian-armhf`. This protects Ubuntu units from old packages.
- **Release requirement:** the Ubuntu build must list only `ubuntu-arm64` in `PLATFORMS`. The Ubuntu image must ship this `update-bbctrl` and `onefinity-platform` in `/usr/local/bin`.

### WiFi on NetworkManager

`config-wifi` keeps its command-line interface. When NetworkManager is running it uses `nmcli`; otherwise it runs the legacy ifupdown/dhcpcd/hostapd code unchanged.
`bbctrl/wifi.py` makes the same choice for scanning (`nmcli device wifi list` instead of `iwlist`) and for the active SSID.

- **One profile at a time:** like the legacy backend, it manages a single WiFi profile. Configuring or disabling WiFi deletes every other WiFi connection profile (`onefinity-wifi` for client mode, `onefinity-ap` for access-point mode). Ethernet profiles are not touched.
- **Access point:** uses `ipv4.method shared` on `192.168.43.1/24`. NetworkManager provides DHCP and NAT, so hostapd, dnsmasq and iptables-persistent aren't needed. WPA2 (RSN/CCMP) only, and a password is required.
- **Reboot:** `-r` still reboots, because the web UI's connect dialog waits for one. NetworkManager doesn't need it, so the UI could later skip the reboot.

Ubuntu image requirements:
- Install `network-manager` (with `dnsmasq-base`, which shared mode needs). Set the netplan renderer to `NetworkManager`, e.g. `/etc/netplan/01-network-manager.yaml` with `network: {version: 2, renderer: NetworkManager}`.
- Don't define WiFi networks in cloud-init / netplan YAML. NetworkManager can't delete those profiles, so they would come back after "disable".

### systemd units and kiosk (`platform/ubuntu-arm64/`)

These files replace `rc.local`, `xinitrc`, `scripts/browser` and ratpoison on Ubuntu. The Raspbian files are unchanged.

| File | Replaces | Notes |
|---|---|---|
| `bbctrl.service` | `scripts/bbctrl.service` | Runs `/opt/onefinity/venv/bin/bbctrl` (venv install is still to do, B6). Adds `RestartSec`, `StateDirectory`. Keeps `KillMode=process`, because `update-bbctrl` is a child of `bbctrl` and stops it. |
| `onefinity-hw-setup` + `.service` | UART part of `rc.local` | If the `bbserial` module is installed, unbinds the PL011 that the `serial0` DT alias points to (no hard-coded address) and loads `bbserial`. Otherwise leaves the stock driver (§3.1 option 1). |
| `onefinity-kiosk.service` | `rc.local` `startx`, `xinitrc` loop | `cage` on tty1 as user `kiosk`, restarted by systemd. |
| `onefinity-browser` | `xinitrc`, `scripts/browser` | Waits for `bbctrl`, applies `display_rotate` from `config.txt` with `wlr-randr` (touch follows the output), clears Chromium crash flags, runs Chromium `--kiosk` on Wayland. |
| `setup-system.sh` | parts of `setup_rpi.sh` / `install.sh` | Idempotent. Installs packages and the Chromium snap. Creates the `kiosk` user. Sets the browser memory limit (650M/750M, as `rc.local`'s cgroup did) on the kiosk user's slice, because the Chromium snap runs in its own scope outside the service. Disables unattended upgrades, holds snap refreshes, disables cloud-init after first boot, sets the netplan renderer to NetworkManager, installs and enables the units. |

To verify on hardware:
- Chromium snap under cage via a PAM session, and the memory limit actually applying to the snap's scope.
- `wlr-randr` transforms and touch mapping on the OneFinity touchscreen.
- The RP1 UART appearing under `uart-pl011` on the amba bus.
- Whether `--kiosk` is wanted. The X11 setup didn't use it and relied on ratpoison to maximize the window.

## Sources

- [Install Ubuntu on Raspberry Pi (Canonical)](https://ubuntu.com/raspberry-pi): image availability and the Pi 5 EEPROM requirement
- [Ubuntu docs: Install Ubuntu on the Raspberry Pi](https://ubuntu.com/hardware/docs/boards/how-to/ubuntu_supported/raspberry-pi/)
- [HatLabs HALPI2 interface reference](https://docs.hatlabs.fi/halpi2/technical-reference/interfaces/): Pi 5 `uartN-pi5` overlays and `ctsrts`
- [openHAB: Enable /dev/ttyAMA0 on RPi5](https://community.openhab.org/t/enable-dev-ttyama0-on-rpi5/161585)
