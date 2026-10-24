DIR := $(shell dirname $(lastword $(MAKEFILE_LIST)))

NODE_MODS  := $(DIR)/node_modules
PUG        := $(NODE_MODS)/.bin/pug
STYLUS     := $(NODE_MODS)/.bin/stylus

TARGET_DIR := build/http
HTML       := index
HTML       := $(patsubst %,$(TARGET_DIR)/%.html,$(HTML))
RESOURCES  := $(shell find src/resources -type f)
RESOURCES  := $(patsubst src/resources/%,$(TARGET_DIR)/%,$(RESOURCES))
TEMPLS     := $(wildcard src/pug/templates/*.pug)

AVR_FIRMWARE := src/avr/bbctrl-avr-firmware.hex
GPLAN_MOD    := rpi-share/camotics/gplan.so
GPLAN_TARGET := src/py/camotics/gplan.so
GPLAN_IMG    := gplan-dev.img

RSYNC_EXCLUDE := \*.pyc __pycache__ \*.egg-info \\\#* \*~ .\\\#\*
RSYNC_EXCLUDE := $(patsubst %,--exclude %,$(RSYNC_EXCLUDE))
RSYNC_OPTS    := $(RSYNC_EXCLUDE) -rv --no-g --delete --force

VERSION  := $(shell sed -n 's/^.*"version": "\([^"]*\)",.*$$/\1/p' package.json)
PKG_NAME := bbctrl-$(VERSION)

SUBPROJECTS := avr boot pwr jig

# The OS image a package is built for, see scripts/onefinity-platform.
# Build an Ubuntu package with "make pkg PLATFORM=ubuntu-arm64".
PLATFORM ?= raspbian-armhf

ifeq ($(PLATFORM),raspbian-armhf)
PKG_DEPS := bbserial
endif

ifndef HOST
HOST=onefinity.local
endif

ifndef PASSWORD
PASSWORD=onefinity
endif

all: $(HTML) $(RESOURCES)
	@for SUB in $(SUBPROJECTS); do $(MAKE) -C src/$$SUB; done

pkg: all $(AVR_FIRMWARE) $(PKG_DEPS) wheels
	echo $(PLATFORM) > PLATFORMS
	./setup.py sdist

# Python dependencies the OS doesn't package, so installs work offline
wheels:
	rm -rf wheels
	if [ -e platform/$(PLATFORM)/requirements.txt ]; then \
	  pip3 wheel --no-deps -w wheels \
	    -r platform/$(PLATFORM)/requirements.txt; \
	fi

bbserial:
	$(MAKE) -C src/bbserial

# gplan.so and bbemu for this machine, e.g. in arm64 CI or on a Pi 5
native:
	./scripts/build-native.sh

gplan: $(GPLAN_TARGET)

$(GPLAN_TARGET): $(GPLAN_MOD)
	cp $< $@

$(GPLAN_MOD): $(GPLAN_IMG)
	./scripts/gplan-init-build.sh
	cp ./scripts/gplan-build.sh rpi-share/
	chmod +x rpi-share/gplan-build.sh
	sudo ./scripts/rpi-chroot.sh $(GPLAN_IMG) /mnt/host/gplan-build.sh

$(GPLAN_IMG):
	./scripts/gplan-init-build.sh

.PHONY: $(AVR_FIRMWARE)
$(AVR_FIRMWARE):
	$(MAKE) -C src/avr

update: pkg
	http_proxy= curl -i -X PUT -H "Content-Type: multipart/form-data" \
	  -F "firmware=@dist/$(PKG_NAME).tar.bz2" -F "password=$(PASSWORD)" \
	  http://$(HOST)/api/firmware/update
	@-tput sgr0 && echo # Fix terminal output

build/templates.pug: $(TEMPLS)
	mkdir -p build
	cat $(TEMPLS) >$@

node_modules: package.json
	npm install && touch node_modules

$(TARGET_DIR)/%: src/resources/%
	install -D $< $@

src/svelte-components/dist/%:
	cd src/svelte-components && rm -rf dist && npm run build

$(TARGET_DIR)/index.html: build/templates.pug
$(TARGET_DIR)/index.html: $(wildcard src/static/js/*)
$(TARGET_DIR)/index.html: $(wildcard src/static/css/*)
$(TARGET_DIR)/index.html: $(wildcard src/pug/templates/*)
$(TARGET_DIR)/index.html: $(wildcard src/js/*)
$(TARGET_DIR)/index.html: $(wildcard src/stylus/*)
$(TARGET_DIR)/index.html: src/resources/config-template.json
$(TARGET_DIR)/index.html: $(wildcard src/resources/onefinity*defaults.json)
$(TARGET_DIR)/index.html: $(wildcard src/svelte-components/dist/*)

FORCE:

$(TARGET_DIR)/%.html: src/pug/%.pug node_modules FORCE
	cd src/svelte-components && rm -rf dist && npm run build
	@mkdir -p $(TARGET_DIR)/svelte-components
	cp src/svelte-components/dist/* $(TARGET_DIR)/svelte-components/

	@mkdir -p $(TARGET_DIR)
	$(PUG) -O pug-opts.js -P $< -o $(TARGET_DIR) || (rm -f $@; exit 1)

clean:
	rm -rf rpi-share
	git clean -fxd

.PHONY: all install clean tidy pkg gplan lint pylint jshint bbserial wheels native