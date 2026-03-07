#!/usr/bin/env bash
# swap-site.sh
# Usage: ./swap-site.sh <site-slug>
# Starts the requested site. Does NOT stop other running sites.

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

echo "🚀  Starting: $SITE_SLUG"
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
# Start site
# -------------------------------------------------------
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
# Update ACTIVE_SITES in .env (comma-separated list)
# -------------------------------------------------------
CURRENT_ACTIVE_SITES="${ACTIVE_SITES:-}"
# Add slug to list if not already present
if echo "$CURRENT_ACTIVE_SITES" | grep -qw "$SITE_SLUG"; then
  : # already in list
else
  if [[ -z "$CURRENT_ACTIVE_SITES" ]]; then
    NEW_ACTIVE_SITES="$SITE_SLUG"
  else
    NEW_ACTIVE_SITES="$CURRENT_ACTIVE_SITES,$SITE_SLUG"
  fi
  if grep -q "^ACTIVE_SITES=" "$ROOT_DIR/.env"; then
    TMP=$(mktemp)
    sed "s|^ACTIVE_SITES=.*|ACTIVE_SITES=$NEW_ACTIVE_SITES|" "$ROOT_DIR/.env" > "$TMP" \
      && cat "$TMP" > "$ROOT_DIR/.env" && rm "$TMP"
  else
    echo "ACTIVE_SITES=$NEW_ACTIVE_SITES" >> "$ROOT_DIR/.env"
  fi
fi

echo ""
echo "✅  Started: $SITE_SLUG"
echo "    🌐 https://$SITE_SLUG.ddev.site"