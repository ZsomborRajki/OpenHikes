#!/usr/bin/env bash
#
# Finds hinge, sourced by Scripts/duo-pose.sh and Scripts/lib/screenshots.sh.
# Not executable on its own.
#
# hinge (https://github.com/artemnovichkov/hinge) is the only scriptable way to
# fold an iPhone Duo simulator: it posts the event Device Hub's own hinge
# slider posts. It is an optional tool, installed rather than kept here —
# `brew install artemnovichkov/tap/hinge` — so a new release reaches these
# scripts with `brew upgrade` and nothing in this repository has to move. Only
# opening a Duo needs it: a simulator boots closed.
#
# The oldest release these scripts are written against. An older one is
# refused before it is asked to fold anything; a newer one is used as it is,
# because Scripts/duo-pose.sh reads every fold back, and that is what notices a
# release that changed what it does. It lives here, beside the one check that
# reads it, rather than in a file of its own.
oldest_hinge="0.3.0"

# Prints the hinge to run. When there is none to run, prints what to do about
# it instead and returns 1. OPENHIKES_HINGE names one in place of the one on
# PATH: Scripts/run-script-tests.sh's seam for a machine without it, which
# nothing else sets.
hinge_command() {
    local hinge installed older
    hinge="${OPENHIKES_HINGE:-$(command -v hinge || true)}"
    if [[ -z "$hinge" || ! -x "$hinge" ]]; then
        echo "hinge is not installed (brew install artemnovichkov/tap/hinge)."
        return 1
    fi
    installed="$("$hinge" -v 2>/dev/null || true)"
    older="$(printf '%s\n%s\n' "$installed" "$oldest_hinge" | sort -V | head -1)"
    if [[ "$older" != "$oldest_hinge" ]]; then
        echo "hinge ${installed:-of no known version} is older than $oldest_hinge (brew upgrade hinge)."
        return 1
    fi
    printf '%s\n' "$hinge"
}
