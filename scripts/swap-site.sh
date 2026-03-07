#!/usr/bin/env bash
# swap-site.sh
# Usage: ./swap-site.sh <site-slug>
# Stops the current active DDEV site and starts the requested one.

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

# -------------------------------------------------------
# Read config from sites.json
# -------------------------------------------------------
get_field() {
  jq -r ".[] | select(.slug == \"$SITE_SLUG\") | $1" "$SITES_FILE"
}

DOMAIN=$(get_field '.domain')
PHP_VERSION=$(get_field '.php_version // "8.2"')
WP_VERSION=$(get_field '.wp_version // "6.5"')
DB_IMPORTED=$(get_field '.db_imported // empty')

if [[ -z "$DOMAIN" ]]; then
  echo "❌  Site '$SITE_SLUG' not found in sites.json"
  exit 1
fi

if [[ ! -d "$SITE_DIR/.ddev" ]]; then
  echo "❌  DDEV not set up for '$SITE_SLUG'"
  echo "    Run: ./scripts/setup-site.sh $SITE_SLUG"
  exit 1
fi

echo "🔀  Swapping to: $SITE_SLUG"
echo "    PHP: $PHP_VERSION | WP: $WP_VERSION"

# -------------------------------------------------------
# Sync PHP version into .ddev/config.yaml if changed
# -------------------------------------------------------
DDEV_CONFIG="$SITE_DIR/.ddev/config.yaml"
CURRENT_PHP=$(grep 'php_version:' "$DDEV_CONFIG" | grep -oP '"\K[^"]+' || echo "")
if [[ -n "$CURRENT_PHP" && "$CURRENT_PHP" != "$PHP_VERSION" ]]; then
  echo "    🐘 PHP changed ($CURRENT_PHP → $PHP_VERSION) — updating DDEV config..."
  sed -i "s/php_version: \".*\"/php_version: \"$PHP_VERSION\"/" "$DDEV_CONFIG"
fi

# -------------------------------------------------------
# Stop current active site
# -------------------------------------------------------
CURRENT_ACTIVE="${ACTIVE_SITE:-}"
if [[ -n "$CURRENT_ACTIVE" && "$CURRENT_ACTIVE" != "$SITE_SLUG" ]]; then
  CURRENT_DIR="$SITES_PATH/$CURRENT_ACTIVE"
  if [[ -d "$CURRENT_DIR/.ddev" ]]; then
    echo "    ⏹️  Stopping: $CURRENT_ACTIVE"
    (cd "$CURRENT_DIR" && ddev stop) || true
  fi
fi

# -------------------------------------------------------
# Start new site
# -------------------------------------------------------
echo "    🚀 Starting DDEV for $SITE_SLUG..."
(cd "$SITE_DIR" && ddev start -y)

# -------------------------------------------------------
# Import DB (first time only)
# -------------------------------------------------------
DB_FILE="$SITE_DIR/db.sql"
if [[ -f "$DB_FILE" && -z "$DB_IMPORTED" ]]; then
  echo "    🗄️  Importing database (first time)..."
  (cd "$SITE_DIR" && ddev import-db --file="$DB_FILE")

  echo "    🔍 Search-replace URLs..."
  (cd "$SITE_DIR" && ddev exec wp search-replace \
    "https://$DOMAIN" "https://$SITE_SLUG.ddev.site" \
    --all-tables --allow-root --quiet --skip-plugins --skip-themes)
  (cd "$SITE_DIR" && ddev exec wp search-replace \
    "http://$DOMAIN" "https://$SITE_SLUG.ddev.site" \
    --all-tables --allow-root --quiet --skip-plugins --skip-themes)

  echo "    ✅ Database imported and URLs replaced"

  TMP=$(mktemp)
  jq --arg slug "$SITE_SLUG" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    'map(if .slug == $slug then .db_imported = $ts else . end)' \
    "$SITES_FILE" > "$TMP" && cat "$TMP" > "$SITES_FILE" && rm "$TMP"

elif [[ -f "$DB_FILE" && -n "$DB_IMPORTED" ]]; then
  echo "    🗄️  DB already imported — skipping (use reimport-db.sh to force)"
fi

# -------------------------------------------------------
# Update ACTIVE_SITE in .env
# -------------------------------------------------------
if grep -q "^ACTIVE_SITE=" "$ROOT_DIR/.env"; then
  TMP=$(mktemp)
  sed "s|^ACTIVE_SITE=.*|ACTIVE_SITE=$SITE_SLUG|" "$ROOT_DIR/.env" > "$TMP" \
    && cat "$TMP" > "$ROOT_DIR/.env" && rm "$TMP"
else
  echo "ACTIVE_SITE=$SITE_SLUG" >> "$ROOT_DIR/.env"
fi

echo ""
echo "✅  Active site: $SITE_SLUG"
echo "    🌐 https://$SITE_SLUG.ddev.site"