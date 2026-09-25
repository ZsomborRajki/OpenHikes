#!/usr/bin/env bash
#
# The App Store screenshot set in light appearance, on a simulator of its own.
# Writes `Screenshots/Output/NN-name.png`. `--frame 03` re-shoots one frame;
# `--help` lists the rest. Everything this shares with the dark set, and the
# reasons for it, is in Scripts/lib/screenshots.sh.

set -euo pipefail

screenshot_appearance="light"
screenshot_suffix=""
screenshot_default_device="OpenHikes Screenshots Light"
# shellcheck source=lib/screenshots.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/screenshots.sh"

screenshots_main "$@"
