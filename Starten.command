#!/bin/bash
set -euo pipefail
APP_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ ! -x "$APP_DIR/build/Koe.app/Contents/MacOS/Koe" ]; then
  bash "$APP_DIR/build.sh"
fi
open "$APP_DIR/build/Koe.app"
