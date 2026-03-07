const express = require("express");
const http = require("http");
const WebSocket = require("ws");
const { spawn } = require("child_process");
const fs = require("fs");
const path = require("path");

// Load .env from project root (one level up from ui/)
require("dotenv").config({ path: path.join(__dirname, "../.env") });

const app = express();
const server = http.createServer(app);
const wss = new WebSocket.Server({ server });

app.use(express.json());
app.use(express.static(path.join(__dirname, "public")));

const SITES_PATH = process.env.SITES_PATH;
const SCRIPTS_PATH = path.join(__dirname, "../scripts");
const SITES_FILE = path.join(__dirname, "../sites.json");
const ENV_FILE = path.join(__dirname, "../.env");

if (!SITES_PATH) {
  console.error("❌  SITES_PATH not set in .env");
  process.exit(1);
}

// -------------------------------------------------------
// Helpers
// -------------------------------------------------------

function readSites() {
  return JSON.parse(fs.readFileSync(SITES_FILE, "utf8"));
}

function writeSites(sites) {
  fs.writeFileSync(SITES_FILE, JSON.stringify(sites, null, 2));
}

function getSite(slug) {
  return readSites().find((s) => s.slug === slug) || null;
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

function getActiveSite() {
  return readEnv().ACTIVE_SITE || null;
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
    isActive: site.slug === getActiveSite(),
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

  activeProcess.on("error", (err) => {
    activeProcess = null;
    broadcast({ type: "done", code: 1, label });
  });

  return activeProcess;
}

// -------------------------------------------------------
// REST API
// -------------------------------------------------------

app.get("/api/sites", (req, res) => {
  res.json(readSites().map(withStatus));
});

app.get("/api/sites/:slug", (req, res) => {
  const site = getSite(req.params.slug);
  if (!site) return res.status(404).json({ error: "Site not found" });
  res.json(withStatus(site));
});

app.post("/api/sites", (req, res) => {
  const sites = readSites();
  const newSite = req.body;
  if (!newSite.slug) return res.status(400).json({ error: "slug required" });
  if (sites.find((s) => s.slug === newSite.slug))
    return res.status(400).json({ error: "Site already exists" });
  sites.push(newSite);
  writeSites(sites);
  fs.mkdirSync(path.join(SITES_PATH, newSite.slug), { recursive: true });
  res.json({ ok: true, site: withStatus(newSite) });
});

app.put("/api/sites/:slug", (req, res) => {
  const { slug } = req.params;
  const sites = readSites();
  const idx = sites.findIndex((s) => s.slug === slug);
  if (idx === -1) return res.status(404).json({ error: "Site not found" });
  sites[idx] = { ...sites[idx], ...req.body };
  writeSites(sites);
  res.json({ ok: true, site: withStatus(sites[idx]) });
});

// Setup DDEV for a site
app.post("/api/sites/:slug/setup", (req, res) => {
  const { slug } = req.params;
  if (!getSite(slug)) return res.status(404).json({ error: "Site not found" });
  runScript([`${SCRIPTS_PATH}/setup-site.sh`, slug], `Setting up ${slug}`);
  res.json({ ok: true });
});

// Sync (rsync wp-content from remote)
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

// Swap active site
app.post("/api/sites/:slug/swap", (req, res) => {
  const { slug } = req.params;
  if (!getSite(slug)) return res.status(404).json({ error: "Site not found" });
  runScript([`${SCRIPTS_PATH}/swap-site.sh`, slug], `Activating ${slug}`);
  res.json({ ok: true });
});

// Force reimport DB
app.post("/api/sites/:slug/reimport-db", (req, res) => {
  const { slug } = req.params;
  if (!getSite(slug)) return res.status(404).json({ error: "Site not found" });
  runScript([`${SCRIPTS_PATH}/reimport-db.sh`, slug], `Reimporting DB for ${slug}`);
  res.json({ ok: true });
});

// Cancel active process
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

// Status
app.get("/api/status", (req, res) => {
  const env = readEnv();
  const active = env.ACTIVE_SITE || null;
  const site = active ? getSite(active) : null;
  res.json({
    active_site: active,
    php_version: site?.php_version || null,
    wp_version: site?.wp_version || null,
    local_url: active ? `https://${active}.ddev.site` : null,
    busy: activeProcess !== null,
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
});