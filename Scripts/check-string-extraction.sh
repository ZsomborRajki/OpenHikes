#!/bin/bash
# Type-checking extracts only localizable expressions. Audit the source too,
# before a catalog sync can silently delete the last evidence of a lost key.
set -euo pipefail
cd "$(dirname "$0")/.."
swift_bin="$(xcrun --find swift)"
host="$(dirname "$swift_bin")/../lib/swift/host"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
exec "$swift_bin" -sdk "$sdk" -I "$host" -L "$host" Scripts/lib/check-string-extraction.swift "$@"
