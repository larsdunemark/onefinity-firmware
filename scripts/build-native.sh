#!/bin/bash -e

# Builds the firmware's native parts for the machine it runs on:
#
#   src/py/camotics/gplan.so  CAMotics planner module, for this python3
#   src/avr/emu/bbemu         AVR emulator, for running without the board
#
# Used by CI for arm64 Ubuntu packages, and can run directly on a Pi 5.
# The Raspbian armhf build still uses "make gplan" (scripts/gplan-build.sh).
#
# Needs: build-essential git scons python3-dev libbz2-dev zlib1g-dev
#        libexpat1-dev libsqlite3-dev libyaml-dev

cd "$(dirname "$0")/.."

CBANG_COMMIT=18f1e963107ef26abe750c023355a5c40dd07853
CAMOTICS_COMMIT=ec876c80d20fc19837133087cef0c447df5a939d

BUILD=${BUILD:-build/native}
JOBS=${JOBS:-$(nproc)}
PYTHON_VERSION=$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')

export LC_ALL=C
export CBANG_HOME=$PWD/$BUILD/cbang


fetch() { # <name> <commit>
    local DIR=$BUILD/$1

    if [ "$(git -C "$DIR" rev-parse HEAD 2>/dev/null)" != "$2" ]; then
        rm -rf "$DIR"
        mkdir -p "$DIR"
        git -C "$DIR" init -q
        git -C "$DIR" remote add origin \
            https://github.com/CauldronDevelopmentLLC/$1
        git -C "$DIR" fetch -q --depth 1 origin "$2"
    fi

    # Start clean, so the patches below apply exactly once
    git -C "$DIR" reset -q --hard "$2"
}


fetch cbang $CBANG_COMMIT
fetch camotics $CAMOTICS_COMMIT

# cbang's python-config.py uses distutils, which Python 3.12 removed
python3 - "$BUILD/cbang/config/python/python-config.py" <<'END'
import sys
path = sys.argv[1]
src = open(path).read().replace('from distutils import sysconfig', '''\
import sysconfig as _sysconfig
class sysconfig:
    get_config_vars = staticmethod(_sysconfig.get_config_vars)
    @staticmethod
    def get_python_inc(plat_specific = False):
        return _sysconfig.get_path('platinclude' if plat_specific else 'include')
''')
open(path, 'w').write(src)
END

# These cbang/camotics versions predate OpenSSL 3, which gplan doesn't need
scons -j "$JOBS" -C "$BUILD/cbang" disable_local="re2 libevent" with_openssl=0

# Same planner patches as scripts/gplan-build.sh
PLAN=$BUILD/camotics/src/gcode/plan
for LIMIT in maxVel maxJerk maxAccel; do
    perl -i -0pe \
        "s/(fabs\((config\.$LIMIT\[axis\]) \/ unit\[axis\]\));/std::min(\2, \1);/gm" \
        "$PLAN/LineCommand.cpp" "$PLAN/LinePlanner.cpp"
done

mkdir -p "$BUILD/camotics/build"
touch "$BUILD/camotics/build/version.txt"
scons -j "$JOBS" -C "$BUILD/camotics" gplan.so with_gui=0 with_tpl=0 \
      python_version="$PYTHON_VERSION"

install -D -m 644 "$BUILD/camotics/gplan.so" src/py/camotics/gplan.so

make -C src/avr/emu -j "$JOBS"

echo "Built gplan.so for Python $PYTHON_VERSION and bbemu"
