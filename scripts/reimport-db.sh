#!/usr/bin/env bash
# reimport-db.sh
# Usage: ./reimport-db.sh <site-slug>
# Force reimport db.sql into DDEV and re-run search-replace.

set -euo pipefail

SITE_SLUG="${1:-}"

if [[ -z "$SITE_SLUG" ]]; then
  echo "Usage: $0 <site-slug>"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
source "$ROOT_DIR/.env"

# -------------------------------------------------------
# Resolve which sites file contains this slug
# Supports SITES_FILES (multi-workspace) and SITES_FILE (single)
# -------------------------------------------------------
resolve_sites_file() {
  local slug="$1"
  # Multi-workspace: SITES_FILES is comma-separated list
  if [[ -n "${SITES_FILES:-}" ]]; then
    IFS=',' read -ra FILES <<< "$SITES_FILES"
    for f in "${FILES[@]}"; do
      f="${f// /}"  # trim spaces
      if [[ -f "$f" ]] && jq -e ".[] | select(.slug == \"$slug\")" "$f" > /dev/null 2>&1; then
        echo "$f"
        return 0
      fi
    done
  fi
  # Single workspace: SITES_FILE or default
  local default="${SITES_FILE:-$ROOT_DIR/sites.json}"
  echo "$default"
}

SITES_FILE="$(resolve_sites_file "$SITE_SLUG")"
SITE_DIR="$SITES_PATH/$SITE_SLUG"
DB_FILE="$SITE_DIR/db.sql"

get_field() {
  jq -r ".[] | select(.slug == \"$SITE_SLUG\") | $1" "$SITES_FILE"
}

DOMAIN=$(get_field '.domain')

if [[ ! -f "$DB_FILE" ]]; then
  echo "❌  No db.sql found for '$SITE_SLUG'"
  echo "    Run: ./scripts/sync-site.sh $SITE_SLUG --db"
  exit 1
fi

echo "🗄️  Reimporting DB for: $SITE_SLUG"

(cd "$SITE_DIR" && ddev import-db --file="$DB_FILE")

echo "🔍  Search-replace URLs..."
(cd "$SITE_DIR" && ddev exec wp search-replace \
  "https://$DOMAIN" "https://$SITE_SLUG.ddev.site" \
  --all-tables --allow-root --quiet --skip-plugins --skip-themes)
(cd "$SITE_DIR" && ddev exec wp search-replace \
  "http://$DOMAIN" "https://$SITE_SLUG.ddev.site" \
  --all-tables --allow-root --quiet --skip-plugins --skip-themes)

# Update db_imported timestamp
TMP=$(mktemp)
jq --arg slug "$SITE_SLUG" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  'map(if .slug == $slug then .db_imported = $ts else . end)' \
  "$SITES_FILE" > "$TMP" && cat "$TMP" > "$SITES_FILE" && rm "$TMP"

echo ""
echo "✅  DB reimported: $SITE_SLUG"
echo "    🌐 https://$SITE_SLUG.ddev.site"