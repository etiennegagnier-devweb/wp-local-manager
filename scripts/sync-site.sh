#!/usr/bin/env bash
# sync-site.sh
# Usage: ./sync-site.sh <site-slug> [--db] [--force]
# Rsyncs wp-content from remote server. Run from host (not inside Docker).

set -euo pipefail

SITE_SLUG="${1:-}"
PULL_DB=false
FORCE=false
INITIAL=false

for arg in "${@:2}"; do
  case $arg in
    --db) PULL_DB=true ;;
    --force) FORCE=true ;;
    --initial) INITIAL=true ;;
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
SSH_KEY="${SSH_KEY_PATH:-$HOME/.ssh/wp_local_manager}"

# -------------------------------------------------------
# Read config from sites.json
# -------------------------------------------------------
get_field() {
  jq -r ".[] | select(.slug == \"$SITE_SLUG\") | $1" "$SITES_FILE"
}

SSH_USER=$(get_field '.host.ssh_user')
SSH_HOST=$(get_field '.host.ssh_host')
SSH_PORT=$(get_field '.host.ssh_port // 22')
SITE_PATH=$(get_field '.host.site_path')
GIT_REMOTE=$(get_field '.git_remote // empty')
THEME_FOLDER=$(get_field '.theme_folder // empty')
R2_OFFLOAD=$(get_field '.r2_offload // false')
PROXY_UPLOADS=$(get_field '.proxy_uploads // false')

if [[ -z "$SSH_HOST" ]]; then
  echo "❌  Site '$SITE_SLUG' not found in sites.json"
  exit 1
fi

# SSH and git use the same key
SSH_CMD="ssh -p $SSH_PORT -i $SSH_KEY -o LogLevel=ERROR -o StrictHostKeyChecking=accept-new"
export GIT_SSH_COMMAND="ssh -i $SSH_KEY -o LogLevel=ERROR -o StrictHostKeyChecking=accept-new"

echo "🔄  Syncing: $SITE_SLUG"
echo "    Host: $SSH_USER@$SSH_HOST:$SSH_PORT"
echo "    Remote path: $SITE_PATH"

mkdir -p "$SITE_DIR/wp-content"

# -------------------------------------------------------
# Build rsync excludes
# -------------------------------------------------------
EXCLUDES=(
  --exclude=".git"
  --exclude="*.log"
  --exclude="/cache/"
  --exclude="/upgrade/"
  --exclude="cfdb7_uploads/"
  --exclude="wp_dndcf7_uploads/"
  --exclude="webp-express/"
)

if [[ "$R2_OFFLOAD" == "true" ]]; then
  echo "    ☁️  R2 offload — skipping uploads/"
  EXCLUDES+=(--exclude="uploads/")
fi

if [[ "$PROXY_UPLOADS" == "true" ]]; then
  echo "    🌐 Proxy uploads — skipping uploads/"
  EXCLUDES+=(--exclude="uploads/")
fi

if [[ -n "$GIT_REMOTE" && -n "$THEME_FOLDER" ]]; then
  echo "    🌿 Theme '$THEME_FOLDER' managed by git — skipping from rsync"
  EXCLUDES+=(--exclude="themes/$THEME_FOLDER/")
fi

# -------------------------------------------------------
# Rsync wp-content
# -------------------------------------------------------
RSYNC_OPTS=(-avz --delete --info=progress2 "${EXCLUDES[@]}")

if [[ "$INITIAL" == "true" ]]; then
  echo "    📦 Initial sync (checksum verification)..."
  RSYNC_OPTS+=(--checksum)
elif [[ "$FORCE" == "true" ]] || [[ ! -d "$SITE_DIR/wp-content/themes" ]]; then
  echo "    📦 Full sync..."
else
  echo "    📦 Incremental sync..."
  RSYNC_OPTS+=(--update)
fi

rsync "${RSYNC_OPTS[@]}" \
  -e "$SSH_CMD" \
  "$SSH_USER@$SSH_HOST:$SITE_PATH/wp-content/" \
  "$SITE_DIR/wp-content/"

# -------------------------------------------------------
# Git theme
# -------------------------------------------------------
if [[ -n "$GIT_REMOTE" && -n "$THEME_FOLDER" ]]; then
  THEME_DIR="$SITE_DIR/wp-content/themes/$THEME_FOLDER"
  git config --global --add safe.directory "$THEME_DIR" 2>/dev/null || true

  if [[ -d "$THEME_DIR/.git" ]]; then
    echo "    🌿 Pulling theme from git..."
    git -C "$THEME_DIR" pull origin master --ff-only 2>/dev/null || \
    git -C "$THEME_DIR" pull origin main --ff-only 2>/dev/null || \
    echo "    ⚠️  Git pull skipped (local changes or conflict)"
  else
    echo "    🌿 Cloning theme from git..."
    rm -rf "$THEME_DIR"
    mkdir -p "$SITE_DIR/wp-content/themes"
    git clone "$GIT_REMOTE" "$THEME_DIR"
  fi
fi

# -------------------------------------------------------
# Database export
# -------------------------------------------------------
if [[ "$PULL_DB" == "true" ]]; then
  echo "    🗄️  Exporting remote database..."

  DB_NAME_REMOTE=$($SSH_CMD "$SSH_USER@$SSH_HOST" \
    "grep DB_NAME $SITE_PATH/wp-config.php | grep -oP \"', '\\K[^']+\"")
  DB_USER_REMOTE=$($SSH_CMD "$SSH_USER@$SSH_HOST" \
    "grep DB_USER $SITE_PATH/wp-config.php | grep -oP \"', '\\K[^']+\"")
  DB_PASS_REMOTE=$($SSH_CMD "$SSH_USER@$SSH_HOST" \
    "grep DB_PASSWORD $SITE_PATH/wp-config.php | grep -oP \"', '\\K[^']+\"")

  $SSH_CMD "$SSH_USER@$SSH_HOST" \
    "mysqldump -u '$DB_USER_REMOTE' -p'$DB_PASS_REMOTE' '$DB_NAME_REMOTE' 2>/dev/null" \
    > "$SITE_DIR/db.sql"

  echo "    ✅ DB saved to $SITE_DIR/db.sql"

  TMP=$(mktemp)
  jq --arg slug "$SITE_SLUG" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    'map(if .slug == $slug then .db_synced = $ts else . end)' \
    "$SITES_FILE" > "$TMP" && cat "$TMP" > "$SITES_FILE" && rm "$TMP"
fi

# -------------------------------------------------------
# Update last_synced
# -------------------------------------------------------
TMP=$(mktemp)
jq --arg slug "$SITE_SLUG" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  'map(if .slug == $slug then .last_synced = $ts else . end)' \
  "$SITES_FILE" > "$TMP" && cat "$TMP" > "$SITES_FILE" && rm "$TMP"

echo ""
echo "✅  Sync complete: $SITE_SLUG"
echo "    Run: ./scripts/swap-site.sh $SITE_SLUG"