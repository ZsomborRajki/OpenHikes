#!/usr/bin/env bash
#
# The App Store screenshot set in dark appearance, on a simulator of its own.
# Writes `Screenshots/Output/NN-name-dark.png`. `--frame 03` re-shoots one
# frame; `--help` lists the rest. Everything this shares with the light set,
# and the reasons for it, is in Scripts/lib/screenshots.sh.
#
# A pass of its own rather than the second half of one run: this app draws a
# different accent green in dark, so a dark frame is a different picture, and
# the dark frames are the ones that have failed where light passed.

set -euo pipefail

screenshot_appearance="dark"
screenshot_suffix="-dark"
screenshot_default_device="OpenHikes Screenshots Dark"
# shellcheck source=lib/screenshots.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/screenshots.sh"

screenshots_main "$@"
