#!/bin/bash
# What CI should run. Kept as a script rather than a workflow file because this project
# currently lives inside another repository; once it has its own, a workflow can just
# call this.
set -euo pipefail

step() { printf '\n\033[36m==> %s\033[0m\n' "$1"; }

step "InvoiceCore tests (SwiftPM, platform-independent)"
swift test

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "Not macOS: skipping the app build and its tests."
    exit 0
fi

step "Generating the Xcode project"
command -v xcodegen >/dev/null 2>&1 || { echo "xcodegen missing; run scripts/bootstrap.sh" >&2; exit 1; }
xcodegen generate --spec project.yml --project .

step "Building and testing every target"
xcodebuild test \
    -project Invoices.xcodeproj \
    -scheme Invoices-All \
    -destination 'platform=macOS' \
    -enableCodeCoverage YES \
    CODE_SIGNING_ALLOWED=NO

step "Reminder: the compliance checks CI cannot do for you"
cat <<'NOTE'
  - EN 16931 Schematron validation of the generated XML
  - veraPDF --flavour 3b on an exported Factur-X PDF
  Both need the official artefacts; see README.md.
NOTE
