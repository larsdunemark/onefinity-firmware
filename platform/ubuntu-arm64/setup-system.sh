#!/bin/bash -e

# Sets up the OneFinity controller's system integration on an Ubuntu arm64
# image: packages, systemd units, the touchscreen kiosk and settings a CNC
# controller needs.  Run as root by install.sh on every install and update,
# so it must be idempotent and work offline once the image has the packages.
#
# Not yet covered here: the UART config.txt overlays and USB automount.

cd "$(dirname "$0")"

KIOSK_USER=kiosk

PACKAGES=(
    # Kiosk and networking
    cage wlr-randr curl network-manager dnsmasq-base
    # bbctrl's dependencies, used from its venv via --system-site-packages.
    # sockjs-tornado isn't packaged, it ships as a wheel, see requirements.txt
    python3-venv python3-setuptools python3-tornado python3-serial
    python3-pyudev python3-smbus2 python3-watchdog python3-libgpiod
)

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a


# Packages.  Only needs the network when something is missing, which is on a
# fresh image, not on firmware updates.
MISSING=()
for PKG in "${PACKAGES[@]}"; do
    dpkg-query -W -f '${Status}' "$PKG" 2>/dev/null |
        grep -q 'install ok installed' || MISSING+=("$PKG")
done

if [ ${#MISSING[@]} -ne 0 ]; then
    apt-get update
    apt-get install -y "${MISSING[@]}"
fi

snap list chromium >/dev/null 2>&1 || snap install chromium


# A CNC controller must not update or restart things on its own mid-job.
# Updates come with firmware updates instead.
systemctl disable --now unattended-upgrades.service 2>/dev/null || true
cat > /etc/apt/apt.conf.d/52onefinity <<END
APT::Periodic::Unattended-Upgrade "0";
END
snap refresh --hold

# cloud-init only for the first boot, so it can't reset hostname, users or
# network config later
touch /etc/cloud/cloud-init.disabled


# NetworkManager manages all interfaces, see config-wifi.  Takes effect on
# the next boot so a remote session running this isn't cut off.
cat > /etc/netplan/01-network-manager.yaml <<END
network:
  version: 2
  renderer: NetworkManager
END
chmod 600 /etc/netplan/01-network-manager.yaml


# Kiosk user
if ! id $KIOSK_USER >/dev/null 2>&1; then
    useradd -m -s /usr/sbin/nologin -G video,render,input $KIOSK_USER
fi

# Memory limit for the browser, as rc.local's cgroup did on Raspbian.  The
# Chromium snap runs in its own scope in the user's slice, outside the kiosk
# service's cgroup, so the limit goes on the slice.
SLICE_DIR=/etc/systemd/system/user-$(id -u $KIOSK_USER).slice.d
mkdir -p $SLICE_DIR
cat > $SLICE_DIR/50-onefinity-memory.conf <<END
[Slice]
MemoryHigh=650M
MemoryMax=750M
END


# Local bbctrl options, kept across updates
if [ ! -e /etc/default/bbctrl ]; then
    cat > /etc/default/bbctrl <<END
# Extra options for bbctrl.  Use --emulate on a Pi without the controller
# board: bbemu then emulates the AVR and no machine moves.
BBCTRL_ARGS=
END
fi


# Log rotation for /var/log/bbctrl.log
install -m 644 ../../scripts/bbctrl-logrotate /etc/logrotate.d/bbctrl


# Scripts and units
install -m 755 onefinity-hw-setup onefinity-browser /usr/local/bin/
install -m 644 bbctrl.service onefinity-hw-setup.service \
    onefinity-kiosk.service /etc/systemd/system/

systemctl daemon-reload
systemctl disable getty@tty1.service
systemctl enable onefinity-hw-setup.service bbctrl.service \
    onefinity-kiosk.service
