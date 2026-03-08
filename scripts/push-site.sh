#!/usr/bin/env bash
# push-site.sh
# Usage: ./push-site.sh <site-slug> [--db] [--force]
# Pushes local wp-content to the STAGING server only.
# ⚠️  Never pushes to production.

set -euo pipefail

SITE_SLUG="${1:-}"
PUSH_DB=false
FORCE=false

AUTO_YES=false
for arg in "${@:2}"; do
  case $arg in
    --db) PUSH_DB=true ;;
    --force) FORCE=true ;;
    --yes) AUTO_YES=true ;;
  esac
done

if [[ -z "$SITE_SLUG" ]]; then
  echo "Usage: $0 <site-slug> [--db] [--force]"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
source "$ROOT_DIR/.env"

# -------------------------------------------------------
# Resolve which sites file contains this slug
# -------------------------------------------------------
resolve_sites_file() {
  local slug="$1"
  if [[ -n "${SITES_FILES:-}" ]]; then
    IFS=',' read -ra FILES <<< "$SITES_FILES"
    for f in "${FILES[@]}"; do
      f="${f// /}"
      if [[ -f "$f" ]] && jq -e ".[] | select(.slug == \"$slug\")" "$f" > /dev/null 2>&1; then
        echo "$f"
        return 0
      fi
    done
  fi
  local default="${SITES_FILE:-$ROOT_DIR/sites.json}"
  echo "$default"
}

SITES_FILE="$(resolve_sites_file "$SITE_SLUG")"
SITE_DIR="$SITES_PATH/$SITE_SLUG"
SSH_KEY="${SSH_KEY_PATH:-$HOME/.ssh/wp_local_manager}"

# -------------------------------------------------------
# Read config
# -------------------------------------------------------
get_field() {
  jq -r ".[] | select(.slug == \"$SITE_SLUG\") | $1" "$SITES_FILE"
}

# Staging target
SSH_USER=$(get_field '.staging.ssh_user // empty')
SSH_HOST=$(get_field '.staging.ssh_host // empty')
SSH_PORT=$(get_field '.staging.ssh_port // 22')
SITE_PATH=$(get_field '.staging.site_path // empty')
STAGING_URL=$(get_field '.staging.url // empty')

# Production host — used only to guard against accidental prod push
PROD_HOST=$(get_field '.host.ssh_host // empty')
PROD_PATH=$(get_field '.host.site_path // empty')

GIT_REMOTE=$(get_field '.git_remote // empty')
THEME_FOLDER=$(get_field '.theme_folder // empty')
R2_OFFLOAD=$(get_field '.r2_offload // false')

# -------------------------------------------------------
# Pre-flight safety checks
# -------------------------------------------------------
if [[ -z "$SSH_HOST" ]]; then
  echo "❌  No staging server configured for '$SITE_SLUG'"
  echo "    Add staging host details in the UI (Host & SSH → Staging tab)"
  exit 1
fi

if [[ -z "$SITE_PATH" ]]; then
  echo "❌  Staging site path is empty for '$SITE_SLUG'"
  echo "    Add staging host details in the UI (Host & SSH → Staging tab)"
  exit 1
fi

# Hard guard: refuse if staging host/path matches production
if [[ "$SSH_HOST" == "$PROD_HOST" && "$SITE_PATH" == "$PROD_PATH" ]]; then
  echo "❌  ABORTED: staging host and path are identical to production."
  echo "    Staging: $SSH_HOST:$SITE_PATH"
  echo "    Prod:    $PROD_HOST:$PROD_PATH"
  echo "    Fix your staging config before pushing."
  exit 1
fi

if [[ "$PUSH_DB" == "true" && -z "$STAGING_URL" ]]; then
  echo "❌  ABORTED: staging.url is not set for '$SITE_SLUG'"
  echo "    Without a staging URL, search-replace cannot run safely."
  echo "    Set the URL in the UI (Host & SSH → Staging tab) and try again."
  exit 1
fi

if [[ ! -d "$SITE_DIR/wp-content" ]]; then
  echo "❌  No local wp-content found for '$SITE_SLUG' — sync first"
  exit 1
fi

SSH_CMD="ssh -p $SSH_PORT -i $SSH_KEY -o LogLevel=ERROR -o StrictHostKeyChecking=accept-new"

# -------------------------------------------------------
# Confirmation prompt
# -------------------------------------------------------
echo ""
echo "┌─────────────────────────────────────────────────┐"
echo "│  ⚠️   STAGING PUSH — PLEASE CONFIRM              │"
echo "├─────────────────────────────────────────────────┤"
echo "│  Site:   $SITE_SLUG"
echo "│  Target: $SSH_USER@$SSH_HOST:$SITE_PATH"
[[ -n "$STAGING_URL" ]] && echo "│  URL:    $STAGING_URL"
[[ "$PUSH_DB" == "true" ]] && echo "│  DB:     YES — remote DB will be overwritten"
[[ "$PUSH_DB" == "false" ]] && echo "│  DB:     No"
echo "└─────────────────────────────────────────────────┘"
echo ""
if [[ "$AUTO_YES" == "true" ]]; then
  echo "    ✓ Confirmed via --yes flag"
else
  read -r -p "    Type 'yes' to continue: " CONFIRM
  if [[ "$CONFIRM" != "yes" ]]; then
    echo "    Aborted."
    exit 0
  fi
fi
echo ""

# -------------------------------------------------------
# Build rsync excludes
# -------------------------------------------------------
EXCLUDES=(
  --exclude=".git"
  --exclude="*.log"
  --exclude="cache/"
  --exclude="wp-content/cache/"
  --exclude="wp-content/upgrade/"
)

if [[ "$R2_OFFLOAD" == "true" ]]; then
  echo "    ☁️  R2 offload — skipping uploads/"
  EXCLUDES+=(--exclude="wp-content/uploads/")
fi

if [[ -n "$GIT_REMOTE" && -n "$THEME_FOLDER" ]]; then
  echo "    🌿 Theme '$THEME_FOLDER' managed by git — skipping from push"
  EXCLUDES+=(--exclude="wp-content/themes/$THEME_FOLDER/")
fi

# -------------------------------------------------------
# Rsync wp-content → staging
# -------------------------------------------------------
RSYNC_OPTS=(-avz --info=progress2 "${EXCLUDES[@]}")

if [[ "$FORCE" == "true" ]]; then
  echo "    📦 Force push (--delete enabled)..."
  RSYNC_OPTS+=(--delete)
else
  echo "    📦 Pushing changed files..."
fi

rsync "${RSYNC_OPTS[@]}" \
  -e "$SSH_CMD" \
  "$SITE_DIR/wp-content/" \
  "$SSH_USER@$SSH_HOST:$SITE_PATH/wp-content/"

echo "    ✅ Files pushed"

# -------------------------------------------------------
# Push database
# -------------------------------------------------------
if [[ "$PUSH_DB" == "true" ]]; then
  echo ""
  echo "    🗄️  Exporting local database..."

  DUMP_FILENAME="push-db-staging.sql"
  LOCAL_DUMP_REPLACED="$SITE_DIR/$DUMP_FILENAME"
  LOCAL_URL="https://${SITE_SLUG}.ddev.site"

  # Export with search-replace baked in via WP-CLI --export flag.
  # Uses a relative filename so WP-CLI writes to /var/www/html/ inside
  # the DDEV container, which maps to $SITE_DIR on the host.
  # Does not modify the local DB.
  echo "    🔄 Exporting with search-replace..."
  echo "        $LOCAL_URL → $STAGING_URL"
  (cd "$SITE_DIR" && ddev wp search-replace "$LOCAL_URL" "$STAGING_URL" \
    --all-tables --skip-plugins --skip-themes \
    --export="$DUMP_FILENAME")

  if [[ ! -f "$LOCAL_DUMP_REPLACED" ]]; then
    echo "❌  Export failed — dump file not found at $LOCAL_DUMP_REPLACED"
    echo "    Run manually to debug: cd $SITE_DIR && ddev wp search-replace --export=$DUMP_FILENAME"
    exit 1
  fi

  # Read remote DB credentials from wp-config.php
  DB_NAME_REMOTE=$($SSH_CMD "$SSH_USER@$SSH_HOST" \
    "grep DB_NAME $SITE_PATH/wp-config.php | grep -oP \"', '\K[^']+\"")
  DB_USER_REMOTE=$($SSH_CMD "$SSH_USER@$SSH_HOST" \
    "grep DB_USER $SITE_PATH/wp-config.php | grep -oP \"', '\K[^']+\"")
  DB_PASS_REMOTE=$($SSH_CMD "$SSH_USER@$SSH_HOST" \
    "grep DB_PASSWORD $SITE_PATH/wp-config.php | grep -oP \"', '\K[^']+\"")

  echo "    📤 Uploading dump to staging..."
  scp -P "$SSH_PORT" -i "$SSH_KEY" -o LogLevel=ERROR \
    "$LOCAL_DUMP_REPLACED" "$SSH_USER@$SSH_HOST:/tmp/${SITE_SLUG}-push.sql"

  echo "    💾 Importing on remote..."
  $SSH_CMD "$SSH_USER@$SSH_HOST" \
    "mysql --default-character-set=utf8mb4 -u '$DB_USER_REMOTE' -p'$DB_PASS_REMOTE' '$DB_NAME_REMOTE' < /tmp/${SITE_SLUG}-push.sql && \
     rm /tmp/${SITE_SLUG}-push.sql"

  rm -f "$LOCAL_DUMP_REPLACED"
  echo "    ✅ Database pushed with URLs replaced"
fi

echo ""
echo "✅  Staging push complete: $SITE_SLUG → $SSH_USER@$SSH_HOST"