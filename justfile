# Recipe names mirror the sibling omarchy-plugin-evm-wallet project on purpose.

plugin_id := "io.github.ipastorsan.bujo"
dest := env_var("HOME") / ".config/omarchy/plugins" / plugin_id

default: lint test check-plugin

# qmlformat cannot parse Quickshell's typed IPC functions and would rewrite
# Panel.qml into something broken, so it is excluded here by name.
fmt:
    qmlformat -i Store.qml views/*.qml components/*.qml

lint:
    #!/usr/bin/env bash
    set -euo pipefail
    tmp=$(mktemp /tmp/bujo-model.XXXX.js)
    grep -v '^\.pragma' Model.js > "$tmp"
    node --check "$tmp"
    rm -f "$tmp"
    echo "Model.js parses"

test:
    node --test

# Everything the Omarchy plugin loader will check, plus our own hygiene rules.
check-plugin:
    omarchy plugin validate .
    ./tests/check-qml.sh

# Sync the QML into the live plugin directory and reload the shell.
# tests/ and .github/ are excluded: the shell watches this tree recursively and
# files it will never load are just reload noise.
install-dev:
    rsync -a --delete \
        --exclude '.git/' --exclude 'tests/' --exclude '.github/' \
        ./ {{dest}}/
    omarchy-shell shell rescanPlugins

# The gate that actually proves the QML works: load it and ask it a question.
# qmllint is near-useless here (it only distinguishes "parses" from "does not")
# and both Qt tools hard-fail on any file containing an IpcHandler.
#
# Use `restart`, not `install-dev`, after a load FAILURE: rescanPlugins does not
# evict a component that failed to compile, so a fixed file keeps reporting the
# old error until the shell is restarted.
smoke: install-dev
    @sleep 2
    omarchy-shell bujo status

restart: install-dev
    omarchy-restart-shell
    @sleep 6
    omarchy-shell bujo status

uninstall-dev:
    rm -rf {{dest}}
    omarchy-shell shell rescanPlugins
