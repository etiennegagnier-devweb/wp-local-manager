#!/usr/bin/env bash
# setup-site.sh
# Usage: ./setup-site.sh <site-slug>
# Run once per site. Creates DDEV config, downloads WP core.

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

PHP_VERSION=$(get_field '.php_version // "8.2"')
WP_VERSION=$(get_field  '.wp_version  // "6.5"')
DOMAIN=$(get_field '.domain')
PROXY_UPLOADS=$(get_field '.proxy_uploads // false')

if [[ -z "$DOMAIN" ]]; then
  echo "❌  Site '$SITE_SLUG' not found in sites.json"
  exit 1
fi

echo "⚙️   Setting up: $SITE_SLUG"
echo "    PHP: $PHP_VERSION | WP: $WP_VERSION"
echo "    Local URL: https://$SITE_SLUG.ddev.site"

# -------------------------------------------------------
# Create site directory
# -------------------------------------------------------
mkdir -p "$SITE_DIR"

# -------------------------------------------------------
# Generate .ddev/config.yaml
# -------------------------------------------------------
mkdir -p "$SITE_DIR/.ddev"
cat > "$SITE_DIR/.ddev/config.yaml" << DDEVEOF
name: $SITE_SLUG
type: wordpress
docroot: .
php_version: "$PHP_VERSION"
webserver_type: nginx-fpm
router_http_port: "80"
router_https_port: "443"
DDEVEOF

echo "    ✅ DDEV config created"

# -------------------------------------------------------
# Proxy uploads: wp-config.ddev.php + nginx fallback
# -------------------------------------------------------
if [[ "$PROXY_UPLOADS" == "true" ]]; then
  echo "    🌐 Proxy uploads enabled — writing wp-config.ddev.php and nginx config..."

  cat > "$SITE_DIR/wp-config.ddev.php" << EOF
<?php define('WP_CONTENT_URL', 'https://$DOMAIN/wp-content');
EOF

  mkdir -p "$SITE_DIR/.ddev/nginx_full"
  cat > "$SITE_DIR/.ddev/nginx_full/nginx-site.conf" << NGINXEOF
location ~* /wp-content/uploads/ {
    try_files \$uri @prod_uploads;
}
location @prod_uploads {
    proxy_pass https://$DOMAIN;
}
NGINXEOF

  echo "    ✅ Proxy uploads configured"
else
  rm -f "$SITE_DIR/wp-config.ddev.php"
  rm -f "$SITE_DIR/.ddev/nginx_full/nginx-site.conf"
fi

# -------------------------------------------------------
# Start DDEV
# -------------------------------------------------------
echo "    🚀 Starting DDEV..."
(cd "$SITE_DIR" && ddev start -y)

# -------------------------------------------------------
# Download WP core
# -------------------------------------------------------
echo "    📦 Downloading WordPress $WP_VERSION..."
(cd "$SITE_DIR" && ddev exec wp core download --version="$WP_VERSION" --skip-content --allow-root)

# -------------------------------------------------------
# Create wp-config.php (DDEV internal DB credentials)
# -------------------------------------------------------
(cd "$SITE_DIR" && ddev exec wp config create \
  --dbname=db \
  --dbuser=db \
  --dbpass=db \
  --dbhost=db \
  --allow-root \
  --force)

echo "    ✅ wp-config.php created"

# -------------------------------------------------------
# Mark as setup in sites.json
# -------------------------------------------------------
TMP=$(mktemp)
jq --arg slug "$SITE_SLUG" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  'map(if .slug == $slug then .ddev_setup = $ts else . end)' \
  "$SITES_FILE" > "$TMP" && cat "$TMP" > "$SITES_FILE" && rm "$TMP"

echo ""
echo "✅  Setup complete: $SITE_SLUG"
echo "    Now run: ./scripts/sync-site.sh $SITE_SLUG --db"
echo "    Then:    ./scripts/swap-site.sh $SITE_SLUG"