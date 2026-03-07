# WP Local Manager v2

Local WordPress development environment for agencies managing multiple client sites.
Uses DDEV for the local runtime (PHP, nginx, MariaDB, WP-CLI).
Custom Node UI for multi-site management, rsync, and git theme integration.

## Requirements

- WSL2 (Ubuntu)
- Docker Desktop (with WSL2 integration enabled)
- DDEV
- Docker Buildx 0.17.0+
- Node.js 20+
- jq
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
nvm install 20
nvm use 20
```

### 3. Update Docker Buildx

DDEV requires Docker Buildx 0.17.0 or later. The version bundled with Docker Desktop
is often outdated. Check your version first:

```bash
docker buildx version
```

If it shows lower than `v0.17.0`, update it:

```bash
mkdir -p ~/.docker/cli-plugins
curl -L https://github.com/docker/buildx/releases/download/v0.19.3/buildx-v0.19.3.linux-amd64 \
  -o ~/.docker/cli-plugins/docker-buildx
chmod +x ~/.docker/cli-plugins/docker-buildx
```

Verify:
```bash
docker buildx version
# Should show v0.19.3
```

### 4. Install DDEV

```bash
curl -fsSL https://pkg.ddev.com/apt/gpg.key | gpg --dearmor | sudo tee /etc/apt/trusted.gpg.d/ddev.gpg > /dev/null
echo "deb [signed-by=/etc/apt/trusted.gpg.d/ddev.gpg] https://pkg.ddev.com/apt/ * *" | sudo tee /etc/apt/sources.list.d/ddev.list
sudo apt update && sudo apt install -y ddev
mkcert -install
```

### 5. Trust local SSL certificates (Windows browsers)

DDEV generates local HTTPS certificates using mkcert. The trick on WSL2 is that
Windows and WSL each generate their own separate root CA by default — Chrome trusts
the Windows one, but DDEV uses the WSL one. You need to make them share the same CA.

**Step 1 — Install mkcert on Windows:**
Go to https://github.com/FiloSottile/mkcert/releases and download
`mkcert-v*-windows-amd64.exe`. Rename it to `mkcert.exe` and place it in
`C:\Windows\System32\` or anywhere in your Windows PATH.

**Step 2 — Generate and install the Windows CA (PowerShell as Administrator):**
```powershell
mkcert -install
```

This creates the CA at `C:\Users\yourname\AppData\Local\mkcert\`.

**Step 3 — Copy the Windows CA into WSL so DDEV uses it (WSL):**
```bash
mkdir -p $HOME/.local/share/mkcert
cp /mnt/c/Users/YOUR_WINDOWS_USERNAME/AppData/Local/mkcert/rootCA.pem $HOME/.local/share/mkcert/rootCA.pem
cp /mnt/c/Users/YOUR_WINDOWS_USERNAME/AppData/Local/mkcert/rootCA-key.pem $HOME/.local/share/mkcert/rootCA-key.pem
mkcert -install
```

Replace `YOUR_WINDOWS_USERNAME` with your actual Windows username (check `C:\Users\` if unsure).

Now both Windows and WSL use the same root CA. Any site started with DDEV will be
trusted by Chrome automatically.

**Step 4 — For any sites already set up, regenerate their certificates:**
```bash
cd ~/wp-sites/your-site
ddev stop && ddev start
```

**Firefox only:** Firefox has its own certificate store. Go to
**Settings → Privacy & Security → Certificates → View Certificates → Authorities → Import**
and import `%LOCALAPPDATA%\mkcert\rootCA.pem`.

### 6. Generate SSH keys

You need two keys — one for your hosting servers, one for GitHub.
Run all commands from inside WSL.

**Server key:**
```bash
ssh-keygen -t ed25519 -C "wp-local-manager" -f ~/.ssh/wp_local_manager
```
Hit enter twice for no passphrase.

**GitHub key:**
```bash
ssh-keygen -t ed25519 -C "wp-local-manager-github" -f ~/.ssh/wp_local_manager_github
```
Hit enter twice for no passphrase.

### 7. Add keys to ~/.ssh/config

```bash
# If ~/.ssh/config doesn't exist yet, use > instead of >> on the first run
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

Replace `YOUR_SERVER_IP` with your actual server IP or hostname.
If your server uses a non-standard SSH port, update `Port` accordingly.
Add one `Host` block per server if you have sites on multiple hosts.

### 8. Install the server key on WHC

```bash
ssh-copy-id -i ~/.ssh/wp_local_manager.pub root@YOUR_SERVER_IP
```

If your server uses a non-standard port:
```bash
ssh-copy-id -i ~/.ssh/wp_local_manager.pub -p 2243 root@YOUR_SERVER_IP
```

Test it:
```bash
ssh whc-prod "echo works"
```

### 9. Install the GitHub key

```bash
cat ~/.ssh/wp_local_manager_github.pub
```

Copy the output. In GitHub: **Settings → SSH and GPG keys → New SSH key**, paste it in.

Test it:
```bash
ssh -T git@github.com
# Should say: Hi yourusername! You've successfully authenticated...
```

If your GitHub org uses SAML SSO, you may need to authorize the key:
GitHub → **Settings → SSH keys** → click **Configure SSO** next to the key.

### 10. Harden SSH on your server (recommended)

While connected to your server, edit `/etc/ssh/sshd_config`:
```
PermitRootLogin prohibit-password
PasswordAuthentication no
```

Then:
```bash
systemctl restart sshd
```

This ensures only key-based login is possible going forward.

### 11. Clone the repo and configure

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

Replace `yourname` with your actual WSL username (`echo $USER`).

### 12. Make scripts executable and install UI

```bash
chmod +x scripts/*.sh
mkdir -p ~/wp-sites
cd ui && npm install && cd ..
```

### 13. Start the UI

```bash
cd ui && npm start
```

UI available at **http://localhost:3000**

---

## Adding a new site

### First time (new site never worked on locally)

```bash
# 1. Add to sites.json (or use + Add in the UI)

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

### Stop a running site

```bash
./scripts/stop-site.sh my-client
```

---

## Daily workflow

**Start working on a site:**
```bash
./scripts/swap-site.sh my-client
```

**Get latest files from server:**
```bash
./scripts/sync-site.sh my-client
```

**Get latest files + fresh DB:**
```bash
./scripts/sync-site.sh my-client --db
./scripts/reimport-db.sh my-client
```

**Force reimport DB without re-syncing:**
```bash
./scripts/reimport-db.sh my-client
```

**Force full rsync (ignore timestamps):**
```bash
./scripts/sync-site.sh my-client --force
```

**Stop a specific site:**
```bash
./scripts/stop-site.sh my-client
```

**Stop all running sites:**
```bash
ddev stop --all
```

---

## Theme development (git)

```bash
cd ~/wp-sites/my-client/wp-content/themes/your-theme
git checkout -b feature/my-feature
# make changes
git add . && git commit -m "feat: description"
git push origin feature/my-feature
```

Syncing the site pulls the theme via `git pull`, not rsync — local branches are safe.

---

## Directory structure

```
~/wp-local-manager/          ← this repo
  scripts/
    setup-site.sh            ← init DDEV + download WP core (run once per site)
    sync-site.sh             ← rsync wp-content from remote server
    swap-site.sh             ← start a site, import DB on first activation
    stop-site.sh             ← stop a running site
    reimport-db.sh           ← force DB reimport + search-replace
  ui/
    server.js                ← Node UI server (runs on WSL host)
    public/index.html        ← control panel
  sites.json.example         ← schema reference for sites config
  sites.json                 ← your site configs (gitignored)
  .env                       ← local paths and keys (gitignored)
  .env.example               ← template for .env

~/wp-sites/                  ← SITES_PATH (outside repo, set in .env)
  my-client/
    .ddev/config.yaml        ← generated by setup-site.sh
    wp-content/              ← rsynced from remote
    wp-admin/                ← WP core (downloaded by setup-site.sh)
    wp-includes/             ← WP core
    wp-config.php            ← generated by DDEV
    db.sql                   ← exported from remote by sync-site.sh
  client-beta/
    ...
```

---

## Adding a junior developer

1. They clone the repo
2. They follow steps 1–13 above (their own SSH keys)
3. Send you their `~/.ssh/wp_local_manager.pub`
4. You add it to the server:
```bash
cat their-key.pub >> ~/.ssh/authorized_keys  # on the server
```
5. They set their own `SITES_PATH` and `SSH_KEY_PATH` in `.env`
6. Share your `sites.json` with them — they run `setup-site.sh` per site as needed

---

## Recommended: auto-start UI with pm2

```bash
npm install -g pm2
pm2 start ~/wp-local-manager/ui/server.js --name wplm
pm2 save && pm2 startup
```

UI stays running at `http://localhost:3000` without manually starting it each time.