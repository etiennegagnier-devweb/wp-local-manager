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

SITES_FILE="$ROOT_DIR/sites.json"
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