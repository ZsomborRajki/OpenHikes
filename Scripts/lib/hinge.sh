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
# Its version is not checked. A hinge too old for these scripts fails on the
# first option it does not know, and Scripts/duo-pose.sh quotes that failure
# and points at `brew upgrade hinge`.

# Prints the hinge to run. When there is none to run, prints what to do about
# it instead and returns 1. OPENHIKES_HINGE names one in place of the one on
# PATH: Scripts/run-script-tests.sh's seam for a machine without it, which
# nothing else sets.
hinge_command() {
    local hinge
    hinge="${OPENHIKES_HINGE:-$(command -v hinge || true)}"
    if [[ -z "$hinge" || ! -x "$hinge" ]]; then
        echo "hinge is not installed (brew install artemnovichkov/tap/hinge)."
        return 1
    fi
    printf '%s\n' "$hinge"
}
