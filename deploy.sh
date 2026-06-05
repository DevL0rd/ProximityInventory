#!/usr/bin/env bash
# Deploy the Proximity Inventory fork from this repo into the Project Zomboid (Proton) mods folder.
# Run after making changes:  ./deploy.sh
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$HOME/.local/share/Steam/steamapps/compatdata/108600/pfx/drive_c/users/steamuser/Zomboid/mods/ProximityInventory"

mkdir -p "$DEST"
rsync -a --delete \
  --exclude='.git/' \
  --exclude='deploy.sh' \
  --exclude='README.md' \
  --exclude='.gitignore' \
  "$REPO_DIR/" "$DEST/"

echo "Deployed ProximityInventory -> $DEST"
echo "Restart Project Zomboid and ensure this fork is enabled (disable the original Proximity Inventory to avoid a duplicate mod id)."
