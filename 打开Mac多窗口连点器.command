#!/bin/zsh
set -eu
cd -- "${0:A:h}"
if [[ ! -d "dist/Mac多窗口连点器.app" ]]; then
  zsh scripts/build-app.sh
fi
open "dist/Mac多窗口连点器.app"
