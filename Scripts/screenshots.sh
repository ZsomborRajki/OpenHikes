#!/usr/bin/env bash
#
# The App Store screenshot set, in dark appearance, on a simulator of its own.
# Writes raw PNGs in a device/locale/date folder under Screenshots/Output.
# `--frame 03` replaces that frame while keeping the rest of the set, and
# `--device-type` shoots the iPad's or the iPhone Duo's set; `--help` lists the
# rest. The capture, and the reasons for it, are in Scripts/lib/screenshots.sh.

set -euo pipefail

# shellcheck source=lib/screenshots.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/screenshots.sh"

screenshots_main "$@"
