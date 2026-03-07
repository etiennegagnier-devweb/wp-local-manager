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
const SITES_FILE = process.env.SITES_FILE || path.join(__dirname, "../sites.json");
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
      const ourSlugs = new Set(readSites().map(s => s.slug));
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
  console.log(`SITES_FILE: ${SITES_FILE}`);
});