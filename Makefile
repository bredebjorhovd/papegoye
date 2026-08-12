# Papegøye — build, sign and install the .app bundle (gh#37).
#
# `swift build` is still how you compile. These targets exist for the part it
# cannot do: giving the binary an identity that outlives the build, so the
# Accessibility grant survives a rebuild instead of leaving a second dead row
# in System Settings every time.
#
# Overridable:  make install APP_DIR=/Applications BIN_DIR=/usr/local/bin
#               make app CODESIGN_IDENTITY="Apple Development: you (TEAMID)"

SHELL := /bin/bash

APP_NAME  := Papegøye
STAGE_DIR ?= build
APP_DIR   ?= $(HOME)/Applications
BIN_DIR   ?= $(HOME)/.local/bin
LABEL     := com.digimata.parrot

STAGED    := $(STAGE_DIR)/$(APP_NAME).app
INSTALLED := $(APP_DIR)/$(APP_NAME).app
CLI       := $(BIN_DIR)/parrot

.DEFAULT_GOAL := help
.PHONY: help build test app install uninstall identity verify clean

help:
	@echo "make build      swift build -c release"
	@echo "make test       swift test"
	@echo "make app        build and sign $(STAGED)"
	@echo "make install    install it to $(APP_DIR) and link $(CLI) at it"
	@echo "make uninstall  remove both"
	@echo "make identity   what TCC sees for the installed app"
	@echo "make verify     rebuild and prove the identity did not change"

build:
	swift build -c release

test:
	swift test

app:
	@scripts/build-app.sh "$(STAGE_DIR)"

# Replacing a bundle out from under a running daemon is asking for a crash, so
# the agent is stopped first and put back afterwards.
install: app
	@set -euo pipefail; \
	uid=$$(id -u); \
	plist="$(HOME)/Library/LaunchAgents/$(LABEL).plist"; \
	running=0; \
	if launchctl print "gui/$$uid/$(LABEL)" >/dev/null 2>&1; then \
		running=1; \
		echo "→ stopping the LaunchAgent"; \
		launchctl bootout "gui/$$uid/$(LABEL)" >/dev/null 2>&1 || true; \
	fi; \
	mkdir -p "$(APP_DIR)" "$(BIN_DIR)"; \
	rm -rf "$(INSTALLED)"; \
	ditto "$(STAGED)" "$(INSTALLED)"; \
	ln -sfn "$(INSTALLED)/Contents/MacOS/parrot" "$(CLI)"; \
	echo "✓ $(INSTALLED)"; \
	echo "✓ $(CLI) -> $(INSTALLED)/Contents/MacOS/parrot"; \
	if [ "$$running" = 1 ]; then \
		launchctl bootstrap "gui/$$uid" "$$plist" >/dev/null 2>&1 || true; \
		echo "✓ LaunchAgent restarted"; \
		current=$$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$$plist" 2>/dev/null || true); \
		case "$$current" in \
			"$(INSTALLED)/"*) ;; \
			*) echo "! the agent still execs $$current"; \
			   echo "  re-run 'parrot install --launch-at-login ...' so it points into the bundle";; \
		esac; \
	fi

uninstall:
	@set -euo pipefail; \
	if [ "$$(readlink "$(CLI)" 2>/dev/null)" = "$(INSTALLED)/Contents/MacOS/parrot" ]; then \
		rm -f "$(CLI)"; echo "✓ removed $(CLI)"; \
	fi; \
	rm -rf "$(INSTALLED)"; \
	echo "✓ removed $(INSTALLED)"

identity:
	@scripts/app-identity.sh "$(INSTALLED)"

# The automatable half of the test that matters.
#
# TCC stores the designated requirement next to the grant and re-evaluates it
# against whatever turns up under that path. So: take the requirement recorded
# for the installed app, build a fresh one, and ask codesign — the same
# evaluator — whether the new build satisfies the old requirement. A different
# cdhash and a satisfied requirement together are exactly the situation the
# grant has to survive.
#
# The other half needs a human: toggle Accessibility on, run this, reinstall,
# and see that the daemon still starts and the list still has one row.
verify: app
	@set -euo pipefail; \
	if [ ! -d "$(INSTALLED)" ]; then \
		echo "nothing installed at $(INSTALLED) — run 'make install' first"; exit 1; \
	fi; \
	req=$$(codesign -d -r- "$(INSTALLED)" 2>/dev/null | sed -n 's/^designated => //p'); \
	if [ -z "$$req" ]; then echo "✗ the installed app is unsigned"; exit 1; fi; \
	echo "requirement recorded for the installed app:"; \
	echo "  $$req"; \
	echo "installed cdhash: $$(codesign -dvvv "$(INSTALLED)" 2>&1 | sed -n 's/^CDHash=//p')"; \
	echo "rebuilt   cdhash: $$(codesign -dvvv "$(STAGED)" 2>&1 | sed -n 's/^CDHash=//p')"; \
	if codesign --verify --strict -R="$$req" "$(STAGED)" 2>&1; then \
		echo "✓ the rebuilt app satisfies it — the same test TCC makes before"; \
		echo "  honouring the Accessibility grant"; \
	else \
		echo "✗ it does not: the grant would be dropped and a second row would appear"; \
		exit 1; \
	fi

clean:
	rm -rf "$(STAGE_DIR)/$(APP_NAME).app" "$(STAGE_DIR)/AppIcon.iconset"
