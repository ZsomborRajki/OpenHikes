#!/usr/bin/env bash
#
# The App Store screenshot set in light appearance, on a simulator of its own.
# Writes raw PNGs in a device/locale/date folder under Screenshots/Output.
# `--frame 03` replaces that frame while keeping the rest of the set;
# `--help` lists the rest. Everything this shares with the dark set, and the
# reasons for it, is in Scripts/lib/screenshots.sh.

set -euo pipefail

screenshot_appearance="light"
screenshot_suffix=""
screenshot_default_device="OpenHikes Screenshots Light"
# shellcheck source=lib/screenshots.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/screenshots.sh"

screenshots_main "$@"
