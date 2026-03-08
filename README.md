# WP Local Manager

Local WordPress development environment for agencies and freelancers managing multiple client sites. Uses DDEV for the local runtime (PHP, nginx, MariaDB, WP-CLI) and a Node.js UI for multi-site management.

**Features:** multi-site sidebar · rsync from remote · DB import + search-replace · DDEV snapshots · Mailpit email testing · auto wp-admin login · dark/light mode · multi-workspace support

---

## Requirements

- WSL2 (Ubuntu)
- Docker Desktop with WSL2 integration enabled
- DDEV
- Docker Buildx 0.17.0+
- Node.js 20+
- `jq`
- SSH key access to your hosting servers

---

## First Time Setup

### 1. Install WSL dependencies

```bash
sudo apt update && sudo apt install -y jq
```

### 2. Install Node.js via nvm

```bash
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
source ~/.bashrc
nvm install 20 && nvm use 20
```

### 3. Update Docker Buildx

DDEV requires Buildx 0.17.0 or later. The version bundled with Docker Desktop is often outdated.

```bash
docker buildx version
```

If it shows lower than `v0.17.0`:

```bash
mkdir -p ~/.docker/cli-plugins
curl -L https://github.com/docker/buildx/releases/download/v0.19.3/buildx-v0.19.3.linux-amd64 \
  -o ~/.docker/cli-plugins/docker-buildx
chmod +x ~/.docker/cli-plugins/docker-buildx
docker buildx version  # should show v0.19.3
```

### 4. Install DDEV

```bash
curl -fsSL https://pkg.ddev.com/apt/gpg.key | gpg --dearmor | sudo tee /etc/apt/trusted.gpg.d/ddev.gpg > /dev/null
echo "deb [signed-by=/etc/apt/trusted.gpg.d/ddev.gpg] https://pkg.ddev.com/apt/ * *" | sudo tee /etc/apt/sources.list.d/ddev.list
sudo apt update && sudo apt install -y ddev
mkcert -install
```

### 5. Trust local SSL certificates in Windows browsers

DDEV generates HTTPS certs using mkcert. On WSL2, Windows and WSL generate separate root CAs by default — you need them to share the same one so Chrome trusts DDEV sites automatically.

**Step 1 — Install mkcert on Windows:**
Download `mkcert-v*-windows-amd64.exe` from https://github.com/FiloSottile/mkcert/releases, rename to `mkcert.exe`, place in `C:\Windows\System32\`.

**Step 2 — Generate and install the Windows CA (PowerShell as Administrator):**
```powershell
mkcert -install
```

**Step 3 — Copy the Windows CA into WSL:**
```bash
mkdir -p $HOME/.local/share/mkcert
cp /mnt/c/Users/YOUR_WINDOWS_USERNAME/AppData/Local/mkcert/rootCA.pem $HOME/.local/share/mkcert/rootCA.pem
cp /mnt/c/Users/YOUR_WINDOWS_USERNAME/AppData/Local/mkcert/rootCA-key.pem $HOME/.local/share/mkcert/rootCA-key.pem
mkcert -install
```

Replace `YOUR_WINDOWS_USERNAME` with your actual Windows username.

**Step 4 — Regenerate certs for any existing sites:**
```bash
cd ~/wp-sites/your-site && ddev stop && ddev start
```

**Firefox only:** Go to **Settings → Privacy & Security → Certificates → Authorities → Import** and import `%LOCALAPPDATA%\mkcert\rootCA.pem`.

### 6. Generate SSH keys

```bash
# Server access key
ssh-keygen -t ed25519 -C "wp-local-manager" -f ~/.ssh/wp_local_manager

# GitHub key (for theme repos)
ssh-keygen -t ed25519 -C "wp-local-manager-github" -f ~/.ssh/wp_local_manager_github
```

### 7. Configure SSH

```bash
cat >> ~/.ssh/config << 'SSHEOF'
Host whc-prod
  HostName YOUR_SERVER_IP
  User root
  IdentityFile ~/.ssh/wp_local_manager
  IdentitiesOnly yes
  Port 22

Host github.com
  HostName github.com
  User git
  IdentityFile ~/.ssh/wp_local_manager_github
  IdentitiesOnly yes
SSHEOF
chmod 600 ~/.ssh/config
```

Add one `Host` block per server if you have sites on multiple hosts.

### 8. Install the server key on your host

```bash
ssh-copy-id -i ~/.ssh/wp_local_manager.pub root@YOUR_SERVER_IP
# If non-standard port:
ssh-copy-id -i ~/.ssh/wp_local_manager.pub -p 2243 root@YOUR_SERVER_IP
ssh whc-prod "echo works"
```

### 9. Install the GitHub key

```bash
cat ~/.ssh/wp_local_manager_github.pub
```

Copy the output → GitHub **Settings → SSH and GPG keys → New SSH key**.

```bash
ssh -T git@github.com
# Hi yourusername! You've successfully authenticated...
```

If your org uses SAML SSO, click **Configure SSO** next to the key in GitHub settings.

### 10. Clone the repo and configure

```bash
git clone git@github.com:etiennegagnier-devweb/wp-local-manager.git ~/wp-local-manager
cd ~/wp-local-manager
cp .env.example .env
```

Edit `.env` — at minimum set:
```
SITES_PATH=/home/yourname/wp-sites
SSH_KEY_PATH=/home/yourname/.ssh/wp_local_manager
```

### 11. Make scripts executable and install UI

```bash
chmod +x scripts/*.sh
mkdir -p ~/wp-sites
cd ui && npm install && cd ..
```

### 12. Start the UI

```bash
cd ui && npm start
```

Open **http://localhost:3000**

---

## Adding a new site

### First time (never worked on locally)

```bash
# 1. Click "+ Add" in the UI and fill in the form, or add manually to sites.json

# 2. Set up DDEV — creates config.yaml, downloads WP core
./scripts/setup-site.sh my-client

# 3. Sync files and DB from remote server
./scripts/sync-site.sh my-client --db

# 4. Start
./scripts/swap-site.sh my-client
# → https://my-client.ddev.site
```

### Start an already-setup site

```bash
./scripts/swap-site.sh my-client
```

Multiple sites can run simultaneously. Each gets its own URL.

### Stop a running site

```bash
./scripts/stop-site.sh my-client
# or use the Stop button in the UI
# or "Stop all" in the header to stop everything at once
```

---

## Daily workflow

```bash
# Start working
./scripts/swap-site.sh my-client

# Sync latest files from server
./scripts/sync-site.sh my-client

# Sync files + fresh DB
./scripts/sync-site.sh my-client --db

# Force reimport DB without re-syncing files
./scripts/reimport-db.sh my-client

# Force full rsync (ignore timestamps)
./scripts/sync-site.sh my-client --force

# Stop a specific site
./scripts/stop-site.sh my-client

# Stop everything
ddev stop --all
```

---

## Multi-workspace setup

If you manage sites across multiple contexts (freelance clients, agency job, personal projects), you can maintain separate `sites.*.json` files and switch between them in the UI.

**In your `.env`:**
```
SITES_FILES=/home/yourname/wp-local-manager/sites.freelance.json,/home/yourname/wp-local-manager/sites.agency.json
```

The workspace name is derived from the filename — `sites.freelance.json` becomes the **freelance** workspace. When multiple workspaces are configured, the sidebar shows filter tabs and each site gets a color chip indicating its workspace. The **+ Add** form lets you pick which workspace a new site belongs to.

Each file is independent — you can share one workspace's file with a colleague without exposing the other.

---

## DDEV snapshots

Before making risky changes (big DB migration, WooCommerce upgrade, etc.), save a snapshot:

```bash
ddev snapshot                        # auto-named
ddev snapshot --name before-upgrade  # named
ddev snapshot restore --latest       # restore most recent
ddev snapshot restore before-upgrade # restore by name
```

Snapshots are also available via the **Dev Tools** section in the UI when a site is running.

---

## Mailpit — local email testing

Every DDEV site automatically intercepts outgoing PHP mail. Instead of emails going out, they land in Mailpit's inbox. Useful for testing WooCommerce order emails, contact forms, password resets, etc.

Access it at **https://your-site.ddev.site:8026** or click the **Mailpit** button in the Dev Tools section of the UI (only visible when the site is running).

Note: Mailpit only intercepts `mail()`. If the site is configured to send via SMTP (e.g. WP Mail SMTP plugin pointing to an external server), emails will bypass it.

---

## Theme development (git)

```bash
cd ~/wp-sites/my-client/wp-content/themes/your-theme
git checkout -b feature/my-feature
# make changes
git add . && git commit -m "feat: description"
git push origin feature/my-feature
```

Syncing pulls the theme via `git pull`, not rsync — your local branch is safe.

---

## Directory structure

```
~/wp-local-manager/           ← this repo
  scripts/
    setup-site.sh             ← init DDEV + download WP core (run once per site)
    sync-site.sh              ← rsync wp-content from remote server
    swap-site.sh              ← start a site, import DB on first activation
    stop-site.sh              ← stop a running site
    reimport-db.sh            ← force DB reimport + search-replace
  ui/
    server.js                 ← Node UI server
    public/index.html         ← control panel
  sites.json                  ← your sites (gitignored)
  sites.*.json                ← additional workspaces (gitignored)
  sites.json.example          ← schema reference
  .env                        ← local config (gitignored)
  .env.example                ← template

~/wp-sites/                   ← SITES_PATH (outside repo)
  my-client/
    .ddev/config.yaml         ← generated by setup-site.sh
    wp-content/               ← rsynced from remote
    wp-admin/                 ← WP core
    wp-includes/              ← WP core
    wp-config.php             ← generated by DDEV
    db.sql                    ← exported from remote by sync-site.sh
```

---

## Adding a junior developer

1. They clone the repo and follow steps 1–12 above (their own SSH keys)
2. Send you their `~/.ssh/wp_local_manager.pub`
3. You add it to the server: `cat their-key.pub >> ~/.ssh/authorized_keys`
4. They set their own `SITES_PATH` and `SSH_KEY_PATH` in `.env`
5. Share the relevant `sites.json` file — they run `setup-site.sh` per site as needed

---

## Auto-start UI with pm2 (recommended)

```bash
npm install -g pm2
pm2 start ~/wp-local-manager/ui/server.js --name wplm
pm2 save && pm2 startup
```

UI stays running at `http://localhost:3000` without a terminal window.

```bash
# to restart the server
pm2 restart wplm
```