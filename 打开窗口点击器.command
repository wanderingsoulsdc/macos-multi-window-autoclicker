#!/bin/zsh
set -eu
cd -- "${0:A:h}"
if [[ ! -d "dist/Mac窗口点击器.app" ]]; then
  zsh scripts/build-app.sh
fi
open "dist/Mac窗口点击器.app"
