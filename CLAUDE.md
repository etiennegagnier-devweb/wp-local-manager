# CLAUDE.md — WP Local Manager

AI assistant guidance for working with this codebase.

---

## Project Overview

**WP Local Manager** is a local WordPress development environment manager designed for agencies handling multiple client sites. It orchestrates [DDEV](https://ddev.com/) containers via a Node.js/Express backend with a vanilla-JS single-page frontend, automating file sync, database import/export, and staging pushes through Bash scripts.

**Target environment:** WSL2 Ubuntu on Windows + Docker Desktop.

---

## Repository Structure

```
wp-local-manager/
├── .env.example            # Template — copy to .env and fill in values
├── sites.json.example      # Template — copy to sites.json (or named workspaces)
├── scripts/                # Bash automation scripts (core logic)
│   ├── setup-site.sh       # Initialize DDEV for a new site (run once per site)
│   ├── swap-site.sh        # Start a site; import DB on first activation
│   ├── sync-site.sh        # Rsync wp-content from remote; optional DB pull
│   ├── stop-site.sh        # ddev stop and remove from ACTIVE_SITES
│   ├── reimport-db.sh      # Force reimport db.sql with search-replace
│   └── push-site.sh        # Push local changes to staging only (never prod)
└── ui/
    ├── server.js           # Express backend + WebSocket server (466 lines)
    ├── package.json        # npm metadata; scripts: start, dev
    └── public/
        └── index.html      # Single-page frontend — no build step (1682 lines)
```

---

## Technology Stack

| Layer | Technology |
|---|---|
| Backend | Node.js 20+, Express 4.18.2, ws 8.16.0 |
| Frontend | Vanilla JS + HTML/CSS (no framework, no build step) |
| Local dev | DDEV (Docker-based), MariaDB, Nginx-FPM |
| Scripting | Bash + jq |
| File sync | rsync over SSH |
| State | `sites.json` (site configs), `.env` (runtime state) |

---

## Environment Configuration

Copy `.env.example` to `.env` in the repo root. Key variables:

| Variable | Required | Description |
|---|---|---|
| `SITES_PATH` | Yes | Absolute WSL path where site folders live (e.g. `/home/user/sites`) |
| `SSH_KEY_PATH` | Yes | Path to SSH private key for remote server access |
| `SITES_FILE` | No | Path to a single `sites.json` (default: `sites.json` in repo root) |
| `SITES_FILES` | No | Comma-separated paths for **multi-workspace** mode; takes precedence over `SITES_FILE` |
| `ACTIVE_SITES` | No | Auto-managed by scripts — comma-separated slugs of running sites |
| `UI_PORT` | No | Port for the Express UI server (default: `3000`) |
| `R2_BUCKET_URL` | No | Cloudflare R2 / S3 URL for media offload (skips `uploads/` in rsync) |

> **Never commit `.env` or `sites.json`** — both are in `.gitignore`.

---

## Site Configuration Schema

Sites are defined in one or more JSON files (default: `sites.json`). See `sites.json.example` for the full schema. Key fields:

```jsonc
{
  "slug": "client-alpha",        // Unique kebab-case identifier — used in all script calls
  "label": "Client Alpha",       // Display name in UI
  "domain": "clientalpha.com",   // Production domain (used in DB search-replace)
  "php_version": "8.2",
  "wp_version": "6.5",
  "table_prefix": "wp_",
  "git_remote": "git@github.com:org/theme.git",  // Optional: theme is managed via git
  "theme_folder": "client-alpha-theme",           // Excluded from rsync if git_remote set
  "r2_offload": false,           // true = skip uploads/ in rsync
  "host": {
    "provider": "whc|generic",
    "ssh_user": "root",
    "ssh_host": "server.example.com",
    "ssh_port": 22,
    "site_path": "/home/clientalpha/public_html"
  },
  "staging": {                   // Optional — required for push-site.sh
    "ssh_user": "root",
    "ssh_host": "staging.example.com",
    "ssh_port": 22,
    "site_path": "/home/clientalpha/staging",
    "url": "https://staging.example.com"
  },
  // Auto-managed timestamps (ISO 8601):
  "last_synced": "...",
  "db_synced": "...",
  "ddev_setup": "...",
  "db_imported": "..."
}
```

**Multi-workspace mode:** Use separate files (e.g. `sites.freelance.json`, `sites.agency.json`) and set `SITES_FILES` to a comma-separated list. The workspace name is derived from the filename (before `.json`).

---

## Development Workflows

### Starting the UI server

```bash
cd ui
npm install        # First time only
npm run dev        # Development (nodemon auto-restart)
npm start          # Production
```

Open `http://localhost:3000` (or `UI_PORT`).

### Adding a new site (full first-time setup)

```bash
# 1. Add site config to sites.json
# 2. Initialize DDEV environment
./scripts/setup-site.sh <slug>
# 3. Sync files + database from production
./scripts/sync-site.sh <slug> --db
# 4. Start site and import DB
./scripts/swap-site.sh <slug>
```

### Daily workflow (existing site)

```bash
./scripts/swap-site.sh <slug>          # Start site (DB already imported)
./scripts/sync-site.sh <slug>          # Sync files only (incremental)
./scripts/sync-site.sh <slug> --db     # Sync files + fresh DB
./scripts/stop-site.sh <slug>          # Stop when done
```

### Pushing to staging

```bash
./scripts/push-site.sh <slug>              # Files only
./scripts/push-site.sh <slug> --db        # Files + database with URL rewrite
./scripts/push-site.sh <slug> --db --yes  # Skip confirmation (used by UI)
```

> `push-site.sh` will **refuse** if staging host/path matches production. Always prompts for confirmation unless `--yes` is passed.

### Database snapshots (via DDEV)

The UI's "Dev Tools" section exposes DDEV snapshot management. Scripts call:
- `ddev snapshot` — create
- `ddev snapshot restore <name>` — restore

### Reimporting DB manually

```bash
./scripts/reimport-db.sh <slug>
```

Requires `db.sql` to already exist in the site folder (created by `sync-site.sh --db`).

---

## Backend API Reference (`ui/server.js`)

All endpoints are relative to `http://localhost:3000`.

### Site CRUD
| Method | Path | Description |
|---|---|---|
| `GET` | `/api/sites` | List all sites across all workspace files |
| `GET` | `/api/sites/:slug` | Get a single site by slug |
| `GET` | `/api/workspaces` | List configured workspace names |
| `POST` | `/api/sites` | Create a new site (appends to correct workspace file) |
| `PUT` | `/api/sites/:slug` | Update site config |

### Actions (spawn bash scripts)
| Method | Path | Description |
|---|---|---|
| `POST` | `/api/sites/:slug/setup` | Run `setup-site.sh` |
| `POST` | `/api/sites/:slug/sync` | Run `sync-site.sh`; body: `{ db, force }` |
| `POST` | `/api/sites/:slug/swap` | Run `swap-site.sh` (start) |
| `POST` | `/api/sites/:slug/stop` | Run `stop-site.sh` |
| `POST` | `/api/sites/:slug/reimport-db` | Run `reimport-db.sh` |
| `POST` | `/api/sites/:slug/push` | Run `push-site.sh`; body: `{ db, force }` |
| `POST` | `/api/stop-all` | Stop all running sites |

### Dev Tools
| Method | Path | Description |
|---|---|---|
| `GET` | `/api/sites/:slug/disk` | Disk usage breakdown |
| `POST` | `/api/sites/:slug/autologin` | Generate WP-CLI login URL (no password) |
| `GET` | `/api/sites/:slug/snapshots` | List DDEV snapshots |
| `POST` | `/api/sites/:slug/snapshot` | Create snapshot |
| `POST` | `/api/sites/:slug/snapshot/restore` | Restore snapshot; body: `{ name }` |

### Process control
| Method | Path | Description |
|---|---|---|
| `GET` | `/api/status` | Active sites list + whether a process is running |
| `POST` | `/api/cancel` | Cancel the currently running process |

**Only one process runs at a time.** The server tracks a single `activeProcess` variable. All log output is broadcast over WebSocket.

---

## Code Conventions

### Bash scripts

- Always start with `set -euo pipefail` for strict error handling.
- Source `.env` at the top: `. "$SCRIPT_DIR/../.env"`.
- Each script contains a local `resolve_sites_file()` helper that honours both `SITES_FILES` (multi-workspace) and `SITES_FILE` (single).
- Use `jq` for all JSON reads/writes to `sites.json`.
- Timestamps written as ISO 8601 (`date -u +"%Y-%m-%dT%H:%M:%SZ"`).
- Progress output uses emoji prefixes (🚀 ⚙️ 🗄️ 🔄 ✅ ❌) for visual scanning.
- Rsync exclude patterns are built as arrays and splatted: `"${EXCLUDES[@]}"`.

### Node.js (`server.js`)

- Helper functions are pure and at the top: `getSitesFiles()`, `workspaceFromFile()`, `readAllSites()`, `writeSite()`, `getSite()`.
- Bash scripts are spawned via `child_process.spawn`; stdout/stderr are piped to WebSocket via `broadcastLog()`.
- `activeProcess` is set/cleared around every script invocation to enforce single-process exclusivity.
- Site status helpers (`isSynced()`, `isSetup()`, `isRunning()`) are stateless functions that inspect site JSON fields + ACTIVE_SITES.
- JSON files are read/written synchronously (`fs.readFileSync` / `fs.writeFileSync`) — acceptable given single-user local tool.

### Frontend (`index.html`)

- No framework. No build step. Edit and refresh.
- CSS variables control theming; `data-theme="dark|light"` on `<html>`.
- Fonts: **Plus Jakarta Sans** (UI) and **Geist Mono** (logs) via Google Fonts.
- All HTTP calls use `fetch()` with `async/await`.
- Real-time logs are streamed over a persistent WebSocket connection and appended as coloured `<span>` elements.
- Theme preference persisted in `localStorage`.
- Site slugs are `kebab-case`; workspace names are lowercase (derived from filename).

### Naming conventions

| Thing | Convention | Example |
|---|---|---|
| Site slugs | kebab-case | `client-alpha` |
| Workspace names | lowercase | `freelance`, `agency` |
| JSON config fields | snake_case | `ssh_user`, `php_version` |
| Script flags | kebab-case | `--db`, `--force`, `--yes` |
| Env variables | SCREAMING_SNAKE_CASE | `SITES_PATH`, `UI_PORT` |

---

## Key Constraints & Safety Rules

1. **`push-site.sh` is staging-only.** It actively checks that `staging.ssh_host` + `staging.site_path` do not match the production values and aborts if they match. Never modify this check.

2. **Single active process.** The backend enforces one bash process at a time via `activeProcess`. Do not bypass this when adding new API endpoints.

3. **`.env` and `sites.json` are never committed.** They contain credentials and local paths. Always edit `.env.example` and `sites.json.example` when changing the schema.

4. **No build step.** The frontend is plain HTML/JS/CSS. Do not introduce a bundler without explicit agreement.

5. **WSL2 paths only.** `SITES_PATH` must be a native Linux path (e.g. `/home/user/sites`), not a Windows mount (`/mnt/c/...`). DDEV performance degrades severely on mounted paths.

6. **jq is required** for all scripts. Validate it is installed (`command -v jq`) before adding new JSON manipulation.

---

## Testing

There is currently no automated test suite. All testing is manual via the UI or by running scripts directly from the command line:

```bash
./scripts/setup-site.sh <slug>
./scripts/swap-site.sh <slug>
# etc.
```

When adding new features, test the happy path, the error path (e.g. missing config, DDEV not running), and the UI interaction manually.

---

## Common Tasks for AI Assistants

### Adding a new script action

1. Write the Bash script in `scripts/` following existing conventions (`set -euo pipefail`, source `.env`, `resolve_sites_file`, emoji output).
2. Add a `POST /api/sites/:slug/<action>` endpoint in `server.js` that spawns the script via `runScript()` pattern (see existing endpoints for reference).
3. Add the corresponding button/handler in `ui/public/index.html`.

### Adding a new site config field

1. Add the field to `sites.json.example` with a comment.
2. Update `.env.example` if it requires a new environment variable.
3. Update any relevant Bash scripts that use `jq` to read/write the field.
4. Update the Add/Edit site form in `index.html` if the field should be user-editable.
5. Document the field in this file.

### Modifying rsync behaviour

Rsync exclude arrays are built in `sync-site.sh` (pull) and `push-site.sh` (push). Both check `r2_offload` and `git_remote` to conditionally exclude `uploads/` and the theme folder. Keep both scripts in sync when changing exclude logic.

### Changing the multi-workspace logic

`getSitesFiles()` and `readAllSites()` in `server.js` control how workspace files are discovered. Each Bash script has its own inline `resolve_sites_file()` — update all six scripts if the resolution logic changes.
