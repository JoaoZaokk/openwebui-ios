#!/usr/bin/env bash
#
# Open WebUI iOS — project setup.
# Generates the Xcode project from project.yml and (optionally) wires your
# Apple Developer Team ID so you can run on a physical iPhone.
#
#   ./setup.sh
#   DEVELOPMENT_TEAM=ABCDE12345 ./setup.sh   # non-interactive
#
set -euo pipefail

echo "▶ Open WebUI iOS — setup"

# 1) XcodeGen (turns project.yml into OpenWebUI.xcodeproj)
if ! command -v xcodegen >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    echo "• Installing XcodeGen via Homebrew…"
    brew install xcodegen
  else
    echo "✗ XcodeGen not found. Install it first: brew install xcodegen"
    echo "  (or see https://github.com/yonaskolb/XcodeGen)"
    exit 1
  fi
fi

# 2) Apple Developer Team ID — only needed to build to a real device.
#    Find it at https://developer.apple.com/account → Membership details.
TEAM="${DEVELOPMENT_TEAM:-}"
if [ -z "$TEAM" ] && [ -t 0 ]; then
  read -rp "Apple Developer Team ID (press Enter to skip — simulator only): " TEAM
fi
export DEVELOPMENT_TEAM="$TEAM"

# 3) Generate the project (project.yml reads ${DEVELOPMENT_TEAM} from the env).
echo "• Generating OpenWebUI.xcodeproj…"
xcodegen generate

echo
echo "✓ Done. Open OpenWebUI.xcodeproj in Xcode and run on an iPhone (iOS 17+)."
echo "  In the app's login screen, type your Open WebUI server URL and sign in."
if [ -z "$TEAM" ]; then
  echo "  ⚠ No Team ID set → simulator only. Re-run with DEVELOPMENT_TEAM=XXXX for device builds."
fi
echo "  You may also want to change PRODUCT_BUNDLE_IDENTIFIER in project.yml (default com.example.openwebui)."
