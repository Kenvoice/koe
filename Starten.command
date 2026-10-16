#!/bin/bash
set -euo pipefail
APP_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ ! -x "/Applications/Koe.app/Contents/MacOS/Koe" ]; then
  bash "$APP_DIR/build.sh"
fi
open "/Applications/Koe.app"
