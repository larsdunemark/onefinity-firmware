#!/bin/bash -e

# Installs or updates the controller on Ubuntu.  Run as root by
# scripts/install.sh, from the root of an extracted firmware package, for
# both first installs and firmware updates.  update-bbctrl has already
# stopped bbctrl.
#
# Works offline: Python dependencies come from Ubuntu packages on the image
# plus the wheels bundled in the package (see requirements.txt).

UPDATE_AVR=true
UPDATE_PY=true
REBOOT=false

VENV=${VENV:-/opt/onefinity/venv}
BIN_DIR=${BIN_DIR:-/usr/local/bin}
PLATFORM_DIR=platform/ubuntu-arm64

# config.txt lines the controller needs.  The UART overlay (with CTS/RTS)
# goes here once verified on hardware.
BOOT_LINES=(dtparam=i2c_arm=on)

# update-bbctrl passes all options as one argument, so split on spaces
# shellcheck disable=SC2048
for ARG in $*; do
    case "$ARG" in
        --no-avr) UPDATE_AVR=false ;;
        --no-py) UPDATE_PY=false ;;
    esac
done


# Don't leave the controller stopped if anything below fails
trap 'echo "Install failed"; systemctl start bbctrl onefinity-kiosk' ERR


# Packages, systemd units, kiosk and system settings
$PLATFORM_DIR/setup-system.sh


if $UPDATE_PY; then
    # Recreate the venv if missing or built for another Python, e.g. after an
    # Ubuntu release upgrade
    if [ "$("$VENV/bin/python" -V 2>&1)" != "$(python3 -V 2>&1)" ]; then
        rm -rf "$VENV"
        mkdir -p "$(dirname "$VENV")"
        python3 -m venv --system-site-packages "$VENV"
    fi

    WHEELS=()
    [ -d wheels ] && WHEELS=(--find-links wheels)
    # Their dependencies come from Ubuntu packages
    "$VENV/bin/pip" install --no-index --no-deps "${WHEELS[@]}" \
        -r $PLATFORM_DIR/requirements.txt
    "$VENV/bin/pip" install --no-index --no-deps --no-build-isolation \
        --force-reinstall .

    # bbctrl and the system run its scripts from /usr/local/bin
    "$VENV/bin/python" - <<'END' |
import importlib.metadata, os, sys
bin_dir = os.path.realpath(os.path.join(sys.prefix, 'bin'))
for f in importlib.metadata.files('bbctrl'):
    path = os.path.realpath(f.locate())
    if os.path.dirname(path) == bin_dir: print(os.path.basename(path))
END
    while read -r SCRIPT; do
        ln -sf "$VENV/bin/$SCRIPT" "$BIN_DIR/$SCRIPT"
    done

    if ! "$VENV/bin/python" -c 'import camotics.gplan' 2>/dev/null; then
        echo "WARNING: camotics.gplan is missing, the planner will not work"
    fi
fi


if $UPDATE_AVR; then
    "$VENV/bin/python" scripts/avr109-flash.py src/avr/bbctrl-avr-firmware.hex
fi


# Boot config, reboot if it changed.  Not edit-boot-config: config.txt has
# several dtparam/dtoverlay lines and it would replace the first one.
BOOT_CONFIG=$(scripts/onefinity-platform --boot-dir)/config.txt
for LINE in "${BOOT_LINES[@]}"; do
    if ! grep -qx "$LINE" "$BOOT_CONFIG"; then
        echo "$LINE" >> "$BOOT_CONFIG"
        REBOOT=true
    fi
done


systemctl daemon-reload

if $REBOOT; then
    echo "Rebooting"
    reboot
    exit 0
fi

systemctl restart bbctrl
systemctl restart onefinity-kiosk

echo "Install complete"
