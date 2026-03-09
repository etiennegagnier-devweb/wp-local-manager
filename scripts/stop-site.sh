#!/usr/bin/env bash
# stop-site.sh
# Usage: ./stop-site.sh <site-slug>
# Stops a running DDEV site and removes it from ACTIVE_SITES.

set -euo pipefail

SITE_SLUG="${1:-}"

if [[ -z "$SITE_SLUG" ]]; then
  echo "Usage: $0 <site-slug>"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
source "$ROOT_DIR/.env"

SITE_DIR="$SITES_PATH/$SITE_SLUG"

if [[ ! -d "$SITE_DIR/.ddev" ]]; then
  echo "❌  DDEV not set up for '$SITE_SLUG'"
  exit 1
fi

echo "⏹️   Stopping: $SITE_SLUG"
(cd "$SITE_DIR" && ddev stop) || true

# -------------------------------------------------------
# Remove slug from ACTIVE_SITES in .env
# -------------------------------------------------------
CURRENT_ACTIVE_SITES="${ACTIVE_SITES:-}"
NEW_ACTIVE_SITES=$(echo "$CURRENT_ACTIVE_SITES" | tr ',' '\n' | { grep -v "^${SITE_SLUG}$" || true; } | tr '\n' ',' | sed 's/,$//')

if grep -q "^ACTIVE_SITES=" "$ROOT_DIR/.env"; then
  TMP=$(mktemp)
  sed "s|^ACTIVE_SITES=.*|ACTIVE_SITES=$NEW_ACTIVE_SITES|" "$ROOT_DIR/.env" > "$TMP" \
    && cat "$TMP" > "$ROOT_DIR/.env" && rm "$TMP"
fi

echo ""
echo "✅  Stopped: $SITE_SLUG"