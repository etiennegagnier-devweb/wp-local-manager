const express = require("express");
const http = require("http");
const WebSocket = require("ws");
const { spawn, exec } = require("child_process");
const crypto = require("crypto");
const fs = require("fs");
const path = require("path");

require("dotenv").config({ path: path.join(__dirname, "../.env") });

const app = express();
const server = http.createServer(app);
const wss = new WebSocket.Server({ server });

app.use(express.json());
app.use(express.static(path.join(__dirname, "public")));

const SITES_PATH = process.env.SITES_PATH;
const SCRIPTS_PATH = path.join(__dirname, "../scripts");
const ENV_FILE = path.join(__dirname, "../.env");

if (!SITES_PATH) {
  console.error("❌  SITES_PATH not set in .env");
  process.exit(1);
}

// -------------------------------------------------------
// Multi-workspace helpers
// -------------------------------------------------------

function getSitesFiles() {
  if (process.env.SITES_FILES) {
    return process.env.SITES_FILES.split(",").map(s => s.trim()).filter(Boolean);
  }
  return [process.env.SITES_FILE || path.join(__dirname, "../sites.json")];
}

function workspaceFromFile(filePath) {
  const base = path.basename(filePath, ".json"); // e.g. "sites.freelance" or "sites"
  const match = base.match(/^sites\.(.+)$/);
  return match ? match[1] : base;
}

// Returns all sites across all files, each tagged with _workspace and _file
function readAllSites() {
  const all = [];
  for (const file of getSitesFiles()) {
    if (!fs.existsSync(file)) continue;
    try {
      const sites = JSON.parse(fs.readFileSync(file, "utf8"));
      const workspace = workspaceFromFile(file);
      for (const site of sites) {
        all.push({ ...site, _workspace: workspace, _file: file });
      }
    } catch (e) {
      console.error(`Failed to read ${file}:`, e.message);
    }
  }
  return all;
}

// Find which file a slug lives in; returns null if not found
function findSiteFile(slug) {
  for (const file of getSitesFiles()) {
    if (!fs.existsSync(file)) continue;
    try {
      const sites = JSON.parse(fs.readFileSync(file, "utf8"));
      if (sites.find(s => s.slug === slug)) return file;
    } catch (e) {}
  }
  return null;
}

// Read/write a single file safely
function readFile(filePath) {
  if (!fs.existsSync(filePath)) return [];
  return JSON.parse(fs.readFileSync(filePath, "utf8"));
}

function writeFile(filePath, sites) {
  // Strip internal metadata before writing
  const clean = sites.map(({ _workspace, _file, ...rest }) => rest);
  fs.writeFileSync(filePath, JSON.stringify(clean, null, 2));
}

function getSite(slug) {
  return readAllSites().find(s => s.slug === slug) || null;
}

function readEnv() {
  const raw = fs.readFileSync(ENV_FILE, "utf8");
  const result = {};
  for (const line of raw.split("\n")) {
    const match = line.match(/^([^#=]+)=(.*)$/);
    if (match) result[match[1].trim()] = match[2].trim();
  }
  return result;
}

function getActiveSites() {
  const env = readEnv();
  // Support both old ACTIVE_SITE and new ACTIVE_SITES
  const val = env.ACTIVE_SITES || env.ACTIVE_SITE || "";
  return val ? val.split(",").map(s => s.trim()).filter(Boolean) : [];
}

function isSynced(slug) {
  return fs.existsSync(path.join(SITES_PATH, slug, "wp-content"));
}

function hasDb(slug) {
  return fs.existsSync(path.join(SITES_PATH, slug, "db.sql"));
}

function isDdevSetup(slug) {
  return fs.existsSync(path.join(SITES_PATH, slug, ".ddev", "config.yaml"));
}


function withStatus(site) {
  return {
    ...site,
    isActive: getActiveSites().includes(site.slug),
    isSynced: isSynced(site.slug),
    hasDb: hasDb(site.slug),
    isDdevSetup: isDdevSetup(site.slug),
  };
}

function broadcast(data) {
  const msg = typeof data === "string" ? data : JSON.stringify(data);
  wss.clients.forEach((c) => {
    if (c.readyState === WebSocket.OPEN) c.send(msg);
  });
}

// -------------------------------------------------------
// Process management
// -------------------------------------------------------

let activeProcess = null;

function runScript(args, label) {
  if (activeProcess) {
    activeProcess.kill("SIGTERM");
    activeProcess = null;
  }

  broadcast({ type: "start", label });

  activeProcess = spawn("bash", args, {
    env: { ...process.env },
    cwd: path.join(__dirname, ".."),
  });

  activeProcess.stdout.on("data", (d) => broadcast({ type: "log", text: d.toString() }));
  activeProcess.stderr.on("data", (d) => broadcast({ type: "log", text: d.toString() }));

  activeProcess.on("close", (code) => {
    activeProcess = null;
    broadcast({ type: "done", code, label });
  });

  activeProcess.on("error", () => {
    activeProcess = null;
    broadcast({ type: "done", code: 1, label });
  });

  return activeProcess;
}

// -------------------------------------------------------
// REST API — Sites CRUD
// -------------------------------------------------------

app.get("/api/sites", (req, res) => {
  res.json(readAllSites().map(withStatus));
});

app.get("/api/workspaces", (req, res) => {
  const files = getSitesFiles();
  res.json(files.map(f => ({ name: workspaceFromFile(f), file: f, exists: fs.existsSync(f) })));
});

app.get("/api/sites/:slug", (req, res) => {
  const site = getSite(req.params.slug);
  if (!site) return res.status(404).json({ error: "Site not found" });
  res.json(withStatus(site));
});

app.post("/api/sites", (req, res) => {
  const newSite = req.body;
  if (!newSite.slug) return res.status(400).json({ error: "slug required" });

  const allSites = readAllSites();
  if (allSites.find(s => s.slug === newSite.slug))
    return res.status(400).json({ error: "Site already exists" });

  // Determine which file to write to
  const { _file: targetFile, ...siteData } = newSite;
  const file = targetFile || getSitesFiles()[0];
  const sites = readFile(file);
  sites.push(siteData);
  writeFile(file, sites);
  fs.mkdirSync(path.join(SITES_PATH, newSite.slug), { recursive: true });
  res.json({ ok: true, site: withStatus({ ...siteData, _workspace: workspaceFromFile(file), _file: file }) });
});

app.put("/api/sites/:slug", (req, res) => {
  const { slug } = req.params;
  const file = findSiteFile(slug);
  if (!file) return res.status(404).json({ error: "Site not found" });

  const sites = readFile(file);
  const idx = sites.findIndex(s => s.slug === slug);
  const { _workspace, _file, ...updates } = req.body;
  sites[idx] = { ...sites[idx], ...updates };
  writeFile(file, sites);
  res.json({ ok: true, site: withStatus({ ...sites[idx], _workspace: workspaceFromFile(file), _file: file }) });
});

// -------------------------------------------------------
// REST API — Actions
// -------------------------------------------------------

app.post("/api/sites/:slug/setup", (req, res) => {
  const { slug } = req.params;
  if (!getSite(slug)) return res.status(404).json({ error: "Site not found" });
  runScript([`${SCRIPTS_PATH}/setup-site.sh`, slug], `Setting up ${slug}`);
  res.json({ ok: true });
});

app.post("/api/sites/:slug/sync", (req, res) => {
  const { slug } = req.params;
  const { db, force } = req.body;
  if (!getSite(slug)) return res.status(404).json({ error: "Site not found" });
  const args = [`${SCRIPTS_PATH}/sync-site.sh`, slug];
  if (db) args.push("--db");
  if (force) args.push("--force");
  runScript(args, `Syncing ${slug}`);
  res.json({ ok: true });
});

app.post("/api/sites/:slug/swap", (req, res) => {
  const { slug } = req.params;
  if (!getSite(slug)) return res.status(404).json({ error: "Site not found" });
  runScript([`${SCRIPTS_PATH}/swap-site.sh`, slug], `Activating ${slug}`);
  res.json({ ok: true });
});

app.post("/api/sites/:slug/stop", (req, res) => {
  const { slug } = req.params;
  if (!getSite(slug)) return res.status(404).json({ error: "Site not found" });
  runScript([`${SCRIPTS_PATH}/stop-site.sh`, slug], `Stopping ${slug}`);
  res.json({ ok: true });
});

app.post("/api/sites/:slug/reimport-db", (req, res) => {
  const { slug } = req.params;
  if (!getSite(slug)) return res.status(404).json({ error: "Site not found" });
  runScript([`${SCRIPTS_PATH}/reimport-db.sh`, slug], `Reimporting DB for ${slug}`);
  res.json({ ok: true });
});

// -------------------------------------------------------
// REST API — Disk usage
// -------------------------------------------------------

app.get("/api/sites/:slug/disk", (req, res) => {
  const { slug } = req.params;
  if (!getSite(slug)) return res.status(404).json({ error: "Site not found" });

  const siteDir = path.join(SITES_PATH, slug);
  if (!fs.existsSync(siteDir)) return res.json({ total: null, breakdown: [] });

  exec(
    `du -sh "${siteDir}" "${siteDir}/wp-content" "${siteDir}/db.sql" 2>/dev/null`,
    (err, stdout) => {
      const lines = stdout.trim().split("\n").filter(Boolean);
      const parse = (line) => {
        const [size, ...parts] = line.split("\t");
        return { size: size.trim(), path: parts.join("\t").trim() };
      };
      const rows = lines.map(parse);
      const total = rows.find(r => r.path === siteDir)?.size || null;
      const breakdown = rows
        .filter(r => r.path !== siteDir)
        .map(r => ({ label: path.basename(r.path), size: r.size }));
      res.json({ total, breakdown });
    }
  );
});

// -------------------------------------------------------
// REST API — Auto login
// -------------------------------------------------------

app.post("/api/sites/:slug/autologin", (req, res) => {
  const { slug } = req.params;
  if (!getSite(slug)) return res.status(404).json({ error: "Site not found" });

  const siteDir = path.join(SITES_PATH, slug);
  if (!fs.existsSync(path.join(siteDir, ".ddev", "config.yaml"))) {
    return res.status(400).json({ error: "DDEV not set up" });
  }

  const token = crypto.randomBytes(16).toString("hex");
  const filename = `wplm-login-${token}.php`;
  const phpCode = `<?php
require_once(dirname(__FILE__) . '/wp-load.php');
$users = get_users(array('role' => 'administrator', 'number' => 1));
if (!empty($users)) {
  wp_set_auth_cookie($users[0]->ID, true);
  unlink(__FILE__);
  wp_redirect(admin_url());
  exit;
}
unlink(__FILE__);
wp_redirect(home_url());
exit;
`;

  try {
    fs.writeFileSync(path.join(siteDir, filename), phpCode);
    res.json({ url: `https://${slug}.ddev.site/${filename}` });
  } catch (e) {
    res.status(500).json({ error: "Failed to create login file" });
  }
});


// -------------------------------------------------------
// REST API — Snapshots
// -------------------------------------------------------

app.get("/api/sites/:slug/snapshots", (req, res) => {
  const { slug } = req.params;
  if (!getSite(slug)) return res.status(404).json({ error: "Site not found" });
  const siteDir = path.join(SITES_PATH, slug);
  exec(`cd "${siteDir}" && ddev snapshot --list --json 2>/dev/null`, { timeout: 10000 }, (err, stdout) => {
    try {
      const data = JSON.parse(stdout);
      // ddev returns array of snapshot names or objects
      const snapshots = Array.isArray(data) ? data : (data.snapshots || []);
      res.json({ snapshots });
    } catch {
      res.json({ snapshots: [] });
    }
  });
});

app.post("/api/sites/:slug/snapshot", (req, res) => {
  const { slug } = req.params;
  const { name } = req.body;
  if (!getSite(slug)) return res.status(404).json({ error: "Site not found" });
  const siteDir = path.join(SITES_PATH, slug);
  const nameFlag = name ? ` --name="${name}"` : "";
  const cmd = `ddev snapshot${nameFlag}`;
  runScript(["-c", `cd "${siteDir}" && ${cmd}`], `Snapshot: ${slug}`);
  res.json({ ok: true });
});

app.post("/api/sites/:slug/snapshot/restore", (req, res) => {
  const { slug } = req.params;
  const { name } = req.body;
  if (!getSite(slug)) return res.status(404).json({ error: "Site not found" });
  const siteDir = path.join(SITES_PATH, slug);
  const nameArg = name ? ` "${name}"` : " --latest";
  runScript(["-c", `cd "${siteDir}" && ddev snapshot restore${nameArg}`], `Restoring snapshot: ${slug}`);
  res.json({ ok: true });
});

// -------------------------------------------------------
// REST API — Stop all
// -------------------------------------------------------

app.post("/api/stop-all", (req, res) => {
  runScript(["-c", "ddev stop --all"], "Stopping all sites");
  // Clear ACTIVE_SITES in .env immediately
  try {
    let envContent = fs.readFileSync(ENV_FILE, "utf8");
    envContent = envContent.replace(/^ACTIVE_SITES=.*/m, "ACTIVE_SITES=");
    fs.writeFileSync(ENV_FILE, envContent);
  } catch (e) {}
  res.json({ ok: true });
});

// -------------------------------------------------------
// REST API — Cancel / Status
// -------------------------------------------------------

app.post("/api/cancel", (req, res) => {
  if (activeProcess) {
    activeProcess.kill("SIGTERM");
    activeProcess = null;
    broadcast({ type: "done", code: 1, label: "Cancelled by user" });
    res.json({ ok: true });
  } else {
    res.json({ ok: false, message: "No active process" });
  }
});

app.get("/api/status", (req, res) => {
  exec("ddev list --json-output 2>/dev/null", { timeout: 10000 }, (err, stdout) => {
    let ddevRunning = null;
    try {
      const parsed = JSON.parse(stdout);
      const ourSlugs = new Set(readAllSites().map(s => s.slug));
      ddevRunning = (parsed.raw || [])
        .filter(s => s.status === "running" && ourSlugs.has(s.name))
        .map(s => s.name);
    } catch (e) {}

    // Reconcile .env if ddev state differs from what is stored
    if (ddevRunning !== null) {
      const stored = getActiveSites();
      const same = stored.length === ddevRunning.length &&
        stored.every(s => ddevRunning.includes(s));
      if (!same) {
        try {
          let envContent = fs.readFileSync(ENV_FILE, "utf8");
          const newVal = ddevRunning.join(",");
          if (envContent.match(/^ACTIVE_SITES=/m)) {
            envContent = envContent.replace(/^ACTIVE_SITES=.*/m, `ACTIVE_SITES=${newVal}`);
          } else {
            envContent += `\nACTIVE_SITES=${newVal}`;
          }
          fs.writeFileSync(ENV_FILE, envContent);
        } catch (e) {}
      }
    }

    res.json({
      active_sites: ddevRunning ?? getActiveSites(),
      busy: activeProcess !== null,
    });
  });
});

// -------------------------------------------------------
// WebSocket
// -------------------------------------------------------
wss.on("connection", (ws) => {
  ws.send(JSON.stringify({ type: "connected" }));
});

// -------------------------------------------------------
// Start
// -------------------------------------------------------
const PORT = process.env.UI_PORT || 3000;
server.listen(PORT, () => {
  console.log(`WP Local Manager UI running at http://localhost:${PORT}`);
  console.log(`SITES_PATH: ${SITES_PATH}`);
  console.log(`SITES_FILES: ${getSitesFiles().join(", ")}`);
});