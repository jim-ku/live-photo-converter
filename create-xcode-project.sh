#!/usr/bin/env bash
# Regenerate the Xcode project with xcodegen if available.
set -euo pipefail
cd "$(dirname "$0")"
if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate
  echo "Generated LivePhotoConverter.xcodeproj via xcodegen."
else
  echo "xcodegen not installed. The checked-in LivePhotoConverter.xcodeproj is ready to open."
  echo "Optional: brew install xcodegen && ./create-xcode-project.sh"
fi
