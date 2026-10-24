#!/bin/bash -e

# Sets up the OneFinity controller's system integration on an Ubuntu arm64
# image: systemd units, the touchscreen kiosk and settings a CNC controller
# needs.  Safe to run more than once.  Run from this directory as root.
#
# Not yet covered here: installing bbctrl itself (into /opt/onefinity/venv),
# the UART/I2C config.txt overlays and USB automount.

cd "$(dirname "$0")"

KIOSK_USER=kiosk

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a


# Packages
apt-get update
apt-get install -y cage wlr-randr curl network-manager dnsmasq-base
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


# Scripts and units
install -m 755 onefinity-hw-setup onefinity-browser /usr/local/bin/
install -m 644 bbctrl.service onefinity-hw-setup.service \
    onefinity-kiosk.service /etc/systemd/system/

systemctl daemon-reload
systemctl disable getty@tty1.service
systemctl enable onefinity-hw-setup.service bbctrl.service \
    onefinity-kiosk.service
