#!/bin/bash
# Installs what is needed to generate and build the Xcode project.
set -euo pipefail

say() { printf '\033[36m==>\033[0m %s\n' "$1"; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$1" >&2; }
die() { printf '\033[31merror:\033[0m %s\n' "$1" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || die "The app target only builds on macOS. On other \
platforms you can still run 'swift test' against InvoiceCore."

say "Checking for Xcode"
if ! xcode-select -p >/dev/null 2>&1; then
    die "No Xcode toolchain selected. Install Xcode, then run 'sudo xcode-select --switch /Applications/Xcode.app'."
fi
xcodebuild -version | head -1

say "Checking for xcodegen"
if command -v xcodegen >/dev/null 2>&1; then
    echo "xcodegen $(xcodegen --version) already installed"
else
    if command -v brew >/dev/null 2>&1; then
        say "Installing xcodegen via Homebrew"
        brew install xcodegen
    elif command -v mint >/dev/null 2>&1; then
        say "Installing xcodegen via Mint"
        mint install yonaskolb/XcodeGen
    else
        die "Neither brew nor mint found. Install one, or install XcodeGen from
  https://github.com/yonaskolb/XcodeGen/releases
and put it on your PATH."
    fi
fi

say "Checking for the sRGB ICC profile"
if [[ -f App/Resources/sRGB-IEC61966-2.1.icc ]]; then
    echo "present"
else
    warn "App/Resources/sRGB-IEC61966-2.1.icc is missing. Exports will carry the \
Factur-X payload but will not declare PDF/A-3. See App/Resources/README.md."
fi

say "Done. Next: make project && make open"
