#!/usr/bin/env bash
# Exit immediately if a command exits with a non-zero status (prevents running if the build fails)
set -e

echo "==> Building game DLL..."
odin build src/game -build-mode:dll -target:darwin_arm64 -out:game.dylib

echo "==> Running game..."
odin run src