#!/usr/bin/env bash
# QML checks that actually mean something.
#
# Background, because this is not obvious and cost an hour to work out:
#
# `qmllint 1.0` on this system reports NOTHING. An unknown type exits 0 silently.
# An unresolved identifier exits 0 silently. It only distinguishes "parses" from
# "does not parse", and communicates that solely through its exit code. So
# "qmllint passed" is a much weaker claim than it sounds, and a green qmllint is
# not evidence of anything beyond parseability.
#
# Worse, both qmllint and qmlformat fail (255 and 1, with zero output) on any
# file containing a Quickshell `IpcHandler` with typed functions -- including
# Omarchy's OWN first-party files: /usr/share/omarchy/shell/Ui/Panel.qml and
# plugins/bar/widgets/SystemUpdate.qml both fail exactly the same way. Those
# files are running in the shell right now, so the tools are wrong, not the QML.
#
# Therefore: parse-check every file the tools can handle, skip the ones they
# demonstrably cannot, and rely on `just smoke` (which loads the plugin into the
# live shell and queries its IPC target) as the real gate for the rest.
set -uo pipefail
cd "$(dirname "$0")/.."
fail=0
SHELL_DIR=/usr/share/omarchy/shell

for f in Panel.qml Store.qml views/*.qml components/*.qml; do
    [[ -e $f ]] || continue
    if grep -q 'IpcHandler' "$f"; then
        printf '  %-34s skipped (IpcHandler: Qt tools fail on first-party files too)\n' "$f"
        continue
    fi
    out=$(qmllint -I "$SHELL_DIR" -I . "$f" 2>&1); code=$?
    if [[ $code -ne 0 || -n $out ]]; then
        printf '  %-34s FAIL (exit %s)\n%s\n' "$f" "$code" "$out"; fail=1
    else
        printf '  %-34s ok\n' "$f"
    fi
done

# JS is genuinely lintable, unlike the QML. node parses it for real.
if command -v node >/dev/null; then
    if node --check Model.js 2>/dev/null; then
        printf '  %-34s ok (node --check)\n' "Model.js"
    else
        # Model.js uses `.pragma library`, which is QML-flavoured JS; strip it.
        tmp=$(mktemp /tmp/model.XXXX.js); grep -v '^\.pragma' Model.js > "$tmp"
        if node --check "$tmp" 2>/dev/null; then
            printf '  %-34s ok (node --check, .pragma stripped)\n' "Model.js"
        else
            printf '  %-34s FAIL\n' "Model.js"; node --check "$tmp"; fail=1
        fi
        rm -f "$tmp"
    fi
fi

# Model.js carries every function that could get a number or an address wrong,
# and none of it is reachable from a QML harness. These are the real unit tests.
if command -v node >/dev/null && [[ -f tests/Model.test.js ]]; then
    if out=$(node --test 2>&1); then
        printf '  %-34s ok (%s)\n' "tests/Model.test.js" "$(echo "$out" | grep -oE 'pass [0-9]+' | head -1)"
    else
        printf '  %-34s FAIL\n' "tests/Model.test.js"
        echo "$out" | grep -E '✖|not ok' | head -10
        fail=1
    fi
fi

exit $fail
