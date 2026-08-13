#!/usr/bin/env bash
# =============================================================================
# CTF Scoreboard Setup Script
# Runs inside a Debian 12 LXC container
# Usage: bash setup.sh
# =============================================================================
set -euo pipefail

APP_DIR="/opt/scoreboard"
DB_PATH="${APP_DIR}/ctf.db"
VENV_DIR="${APP_DIR}/venv"
APP_USER="www-data"

echo "========================================"
echo "  CTF Scoreboard - Setup Script"
echo "========================================"

# -----------------------------------------------------------
# 1. System packages
# -----------------------------------------------------------
echo "[*] Updating packages and installing dependencies..."
apt-get update -qq
apt-get install -y -qq python3 python3-pip python3-venv nginx sqlite3 > /dev/null

# -----------------------------------------------------------
# 2. Application directory & virtualenv
# -----------------------------------------------------------
echo "[*] Creating application directory at ${APP_DIR}..."
mkdir -p "${APP_DIR}/templates"

echo "[*] Setting up Python virtual environment..."
python3 -m venv "${VENV_DIR}"
"${VENV_DIR}/bin/pip" install --quiet --upgrade pip
"${VENV_DIR}/bin/pip" install --quiet flask gunicorn

# -----------------------------------------------------------
# 3. Flask application
# -----------------------------------------------------------
echo "[*] Writing Flask application..."

cat > "${APP_DIR}/app.py" << 'PYEOF'
import os
import sqlite3
import hashlib
from datetime import datetime
from flask import Flask, render_template, request, jsonify

app = Flask(__name__)
DB_PATH = "/opt/scoreboard/ctf.db"

# ---------------------------------------------------------------------------
# Flag definitions
# ---------------------------------------------------------------------------
CHALLENGES = {
    "web": {
        "id": "web",
        "name": "Web Exploitation",
        "order": 1,
        "description": "Probe vulnerable web applications for injection flaws, cross-site scripting, and server-side request forgery.",
        "hints": [
            "Look for user input reflected without sanitisation",
            "Think about what the server trusts on the backend",
            "Sometimes the database speaks if you ask nicely",
        ],
        "flags": [
            {"flag": "FLAG{sql_1nj3ct10n_m4st3r_2024}", "difficulty": "Easy",   "points": 100, "label": "SQL Injection"},
            {"flag": "FLAG{st0r3d_xss_c00k13_th13f}",   "difficulty": "Medium", "points": 200, "label": "Stored XSS"},
            {"flag": "FLAG{ssrf_1nt3rn4l_s3rv1c3_pwn3d}","difficulty": "Hard",   "points": 300, "label": "SSRF"},
        ],
    },
    "privesc": {
        "id": "privesc",
        "name": "Linux Privilege Escalation",
        "order": 2,
        "description": "Escalate from low-privilege shell to root by abusing misconfigurations, cron jobs, and SUID binaries.",
        "hints": [
            "Enumerate SUID binaries and writable scripts",
            "Check what runs on a schedule",
            "sudo -l is your best friend",
            "Sometimes /etc/passwd is more open than it should be",
        ],
        "flags": [
            {"flag": "FLAG{su1d_b1n4ry_3xpl01t_ez}",        "difficulty": "Easy",   "points": 100, "label": "SUID Binary"},
            {"flag": "FLAG{cr0n_j0b_wr1t4bl3_scr1pt}",      "difficulty": "Medium", "points": 200, "label": "Cron Job"},
            {"flag": "FLAG{sud0_m1sc0nf1g_v1m_sh3ll}",       "difficulty": "Medium", "points": 200, "label": "Sudo Misconfiguration"},
            {"flag": "FLAG{p4sswd_wr1t4bl3_r00t_4cc3ss}",    "difficulty": "Hard",   "points": 300, "label": "Writable passwd"},
        ],
    },
    "crypto": {
        "id": "crypto",
        "name": "Crypto & Forensics",
        "order": 3,
        "description": "Decode ciphers, analyse disk images and log files, and recover hidden artefacts.",
        "hints": [
            "Not everything encoded is encrypted",
            "Steganography hides in plain sight",
            "Log correlation can reveal XOR keys",
        ],
        "flags": [
            {"flag": "FLAG{b4s3_s1xty_f0ur_d3c0d3d}",   "difficulty": "Easy",   "points": 100, "label": "Base64 Decode"},
            {"flag": "FLAG{h1dd3n_1n_pl41n_s1ght}",      "difficulty": "Medium", "points": 200, "label": "Steganography"},
            {"flag": "FLAG{l0g_4n4lys1s_x0r_m4st3r}",    "difficulty": "Hard",   "points": 300, "label": "Log Analysis / XOR"},
        ],
    },
    "recon": {
        "id": "recon",
        "name": "Network Recon",
        "order": 4,
        "description": "Scan, enumerate, and exploit network services to uncover hidden flags.",
        "hints": [
            "Anonymous access is sometimes left enabled",
            "Not all services run on well-known ports",
            "Some doors only open when you knock correctly",
        ],
        "flags": [
            {"flag": "FLAG{4n0nym0us_ftp_l00t}",        "difficulty": "Easy",   "points": 100, "label": "Anonymous FTP"},
            {"flag": "FLAG{h1dd3n_p0rt_s3rv1c3}",       "difficulty": "Medium", "points": 200, "label": "Hidden Port"},
            {"flag": "FLAG{p0rt_kn0ck_s3cr3t_d00r}",    "difficulty": "Hard",   "points": 300, "label": "Port Knocking"},
        ],
    },
}

# Build a quick lookup: flag_text -> metadata
FLAG_LOOKUP = {}
for cat_id, cat in CHALLENGES.items():
    for f in cat["flags"]:
        FLAG_LOOKUP[f["flag"]] = {
            "category": cat_id,
            "label": f["label"],
            "difficulty": f["difficulty"],
            "points": f["points"],
        }

TOTAL_POSSIBLE = sum(f["points"] for f in FLAG_LOOKUP.values())  # 2500

# ---------------------------------------------------------------------------
# Database helpers
# ---------------------------------------------------------------------------

def get_db():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn


def init_db():
    conn = get_db()
    conn.execute("""
        CREATE TABLE IF NOT EXISTS captures (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            flag       TEXT    NOT NULL UNIQUE,
            category   TEXT    NOT NULL,
            label      TEXT    NOT NULL,
            difficulty TEXT    NOT NULL,
            points     INTEGER NOT NULL,
            captured_at TEXT   NOT NULL
        )
    """)
    conn.commit()
    conn.close()


def get_captures():
    conn = get_db()
    rows = conn.execute("SELECT * FROM captures ORDER BY captured_at ASC").fetchall()
    conn.close()
    return [dict(r) for r in rows]


def get_captured_flags():
    return {c["flag"] for c in get_captures()}


def get_total_score():
    conn = get_db()
    row = conn.execute("SELECT COALESCE(SUM(points),0) AS total FROM captures").fetchone()
    conn.close()
    return row["total"]


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

@app.route("/")
def index():
    captured = get_captured_flags()
    score = get_total_score()
    ordered = sorted(CHALLENGES.values(), key=lambda c: c["order"])
    return render_template(
        "index.html",
        challenges=ordered,
        captured=captured,
        score=score,
        total_possible=TOTAL_POSSIBLE,
        total_flags=len(FLAG_LOOKUP),
        captured_count=len(captured),
    )


@app.route("/submit", methods=["POST"])
def submit_flag():
    data = request.get_json(silent=True) or {}
    flag = data.get("flag", "").strip()

    if not flag:
        return jsonify({"success": False, "message": "No flag provided."}), 400

    if flag not in FLAG_LOOKUP:
        return jsonify({"success": False, "message": "Invalid flag. Keep trying!"}), 200

    meta = FLAG_LOOKUP[flag]

    conn = get_db()
    existing = conn.execute("SELECT id FROM captures WHERE flag = ?", (flag,)).fetchone()
    if existing:
        conn.close()
        return jsonify({"success": False, "message": f"Flag already captured: {meta['label']}"}), 200

    now = datetime.utcnow().strftime("%Y-%m-%d %H:%M:%S")
    conn.execute(
        "INSERT INTO captures (flag, category, label, difficulty, points, captured_at) VALUES (?,?,?,?,?,?)",
        (flag, meta["category"], meta["label"], meta["difficulty"], meta["points"], now),
    )
    conn.commit()

    new_score = conn.execute("SELECT COALESCE(SUM(points),0) AS total FROM captures").fetchone()["total"]
    captured_count = conn.execute("SELECT COUNT(*) AS cnt FROM captures").fetchone()["cnt"]
    conn.close()

    return jsonify({
        "success": True,
        "message": f"+{meta['points']}pts - {meta['label']} ({meta['difficulty']})",
        "category": meta["category"],
        "flag": flag,
        "points": meta["points"],
        "score": new_score,
        "captured_count": captured_count,
    }), 200


@app.route("/reset", methods=["POST"])
def reset_progress():
    conn = get_db()
    conn.execute("DELETE FROM captures")
    conn.commit()
    conn.close()
    return jsonify({"success": True, "message": "Progress reset. All flags cleared."}), 200


@app.route("/status")
def status():
    captures = get_captures()
    return jsonify({
        "score": get_total_score(),
        "total_possible": TOTAL_POSSIBLE,
        "captured_count": len(captures),
        "total_flags": len(FLAG_LOOKUP),
        "captures": captures,
    })


# ---------------------------------------------------------------------------
# Init
# ---------------------------------------------------------------------------
init_db()

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, debug=True)
PYEOF

# -----------------------------------------------------------
# 4. Jinja2 template (single file, inline CSS + JS)
# -----------------------------------------------------------
echo "[*] Writing HTML template..."

cat > "${APP_DIR}/templates/index.html" << 'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>PROXMOX CTF LAB</title>
<style>
  /* ── Reset & Base ─────────────────────────────────────── */
  *, *::before, *::after { margin:0; padding:0; box-sizing:border-box; }
  :root {
    --bg:        #0a0e12;
    --surface:   #111921;
    --border:    #1a2636;
    --green:     #00ff88;
    --green-dim: #00cc6a;
    --amber:     #ffb800;
    --red:       #ff4444;
    --text:      #c0ccda;
    --text-dim:  #5a6a7a;
    --mono:      'Courier New', 'Fira Code', 'Consolas', monospace;
    --glow:      0 0 12px rgba(0,255,136,.25);
  }
  html { scroll-behavior: smooth; }
  body {
    background: var(--bg);
    color: var(--text);
    font-family: var(--mono);
    font-size: 14px;
    line-height: 1.6;
    min-height: 100vh;
  }

  /* ── Scanline overlay ─────────────────────────────────── */
  body::after {
    content: "";
    position: fixed; inset: 0;
    background: repeating-linear-gradient(
      0deg,
      transparent,
      transparent 2px,
      rgba(0,0,0,.06) 2px,
      rgba(0,0,0,.06) 4px
    );
    pointer-events: none;
    z-index: 9999;
  }

  a { color: var(--green); text-decoration: none; }

  /* ── Layout ───────────────────────────────────────────── */
  .container { max-width: 1100px; margin: 0 auto; padding: 0 20px 60px; }

  /* ── Header ───────────────────────────────────────────── */
  header {
    text-align: center;
    padding: 36px 0 20px;
    border-bottom: 1px solid var(--border);
    margin-bottom: 28px;
  }
  header h1 {
    font-size: 2rem;
    color: var(--green);
    text-shadow: var(--glow);
    letter-spacing: 6px;
    text-transform: uppercase;
  }
  .score-banner {
    margin-top: 14px;
    display: flex;
    justify-content: center;
    gap: 40px;
    flex-wrap: wrap;
  }
  .score-banner .stat {
    display: flex;
    flex-direction: column;
    align-items: center;
  }
  .score-banner .stat-value {
    font-size: 2.2rem;
    font-weight: bold;
    color: var(--green);
    text-shadow: var(--glow);
  }
  .score-banner .stat-label {
    font-size: .75rem;
    color: var(--text-dim);
    text-transform: uppercase;
    letter-spacing: 2px;
  }
  .progress-bar-container {
    margin-top: 14px;
    width: 100%;
    max-width: 500px;
    height: 10px;
    background: var(--border);
    border-radius: 5px;
    overflow: hidden;
    margin-left: auto;
    margin-right: auto;
  }
  .progress-bar-fill {
    height: 100%;
    background: var(--green);
    box-shadow: var(--glow);
    transition: width .5s ease;
  }

  /* ── Sticky flag submission ───────────────────────────── */
  .submit-section {
    position: sticky;
    top: 0;
    z-index: 100;
    background: var(--bg);
    padding: 16px 0 12px;
    border-bottom: 1px solid var(--border);
    margin-bottom: 28px;
  }
  .submit-row {
    display: flex;
    gap: 10px;
    max-width: 700px;
    margin: 0 auto;
  }
  .submit-row input[type="text"] {
    flex: 1;
    background: var(--surface);
    border: 1px solid var(--border);
    color: var(--green);
    font-family: var(--mono);
    font-size: .95rem;
    padding: 10px 16px;
    border-radius: 4px;
    outline: none;
    transition: border-color .2s;
  }
  .submit-row input[type="text"]:focus {
    border-color: var(--green);
    box-shadow: 0 0 6px rgba(0,255,136,.2);
  }
  .submit-row input[type="text"]::placeholder { color: var(--text-dim); }
  .btn {
    background: transparent;
    color: var(--green);
    border: 1px solid var(--green);
    font-family: var(--mono);
    font-size: .85rem;
    padding: 10px 22px;
    border-radius: 4px;
    cursor: pointer;
    text-transform: uppercase;
    letter-spacing: 1px;
    transition: background .2s, color .2s;
    white-space: nowrap;
  }
  .btn:hover { background: var(--green); color: var(--bg); }
  .btn-danger { border-color: var(--red); color: var(--red); }
  .btn-danger:hover { background: var(--red); color: #fff; }

  /* ── Toast notification ───────────────────────────────── */
  .toast {
    position: fixed;
    top: 80px;
    left: 50%;
    transform: translateX(-50%) translateY(-20px);
    padding: 12px 28px;
    border-radius: 4px;
    font-family: var(--mono);
    font-size: .9rem;
    opacity: 0;
    pointer-events: none;
    transition: opacity .3s, transform .3s;
    z-index: 200;
    text-align: center;
    max-width: 90vw;
  }
  .toast.visible { opacity: 1; transform: translateX(-50%) translateY(0); }
  .toast.success { background: #0b2e1a; border: 1px solid var(--green); color: var(--green); box-shadow: var(--glow); }
  .toast.error   { background: #2e0b0b; border: 1px solid var(--red);   color: var(--red); }
  .toast.info    { background: #1a1800; border: 1px solid var(--amber); color: var(--amber); }

  /* ── Challenge cards ──────────────────────────────────── */
  .cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(480px, 1fr)); gap: 20px; }
  .card {
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: 6px;
    padding: 22px 26px;
    transition: border-color .25s;
  }
  .card:hover { border-color: var(--green-dim); }
  .card-header {
    display: flex;
    justify-content: space-between;
    align-items: baseline;
    margin-bottom: 10px;
  }
  .card-title {
    font-size: 1.1rem;
    color: var(--green);
    text-shadow: var(--glow);
  }
  .card-completion {
    font-size: .8rem;
    color: var(--text-dim);
  }
  .card-desc {
    font-size: .85rem;
    color: var(--text-dim);
    margin-bottom: 14px;
    line-height: 1.5;
  }

  /* flag rows inside cards */
  .flag-row {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 6px 0;
    border-top: 1px solid var(--border);
    font-size: .85rem;
  }
  .flag-row:first-of-type { border-top: none; }
  .flag-icon { width: 20px; text-align: center; font-size: 1rem; }
  .flag-icon.captured { color: var(--green); text-shadow: var(--glow); }
  .flag-icon.pending  { color: var(--text-dim); }
  .flag-label { flex: 1; }
  .badge {
    font-size: .7rem;
    padding: 2px 8px;
    border-radius: 3px;
    text-transform: uppercase;
    letter-spacing: 1px;
  }
  .badge-easy   { background: #0b2e1a; color: var(--green); }
  .badge-medium { background: #2e2800; color: var(--amber); }
  .badge-hard   { background: #2e0b0b; color: var(--red); }
  .pts { color: var(--text-dim); font-size: .8rem; min-width: 50px; text-align: right; }

  /* hints */
  .hints {
    margin-top: 12px;
    padding-top: 10px;
    border-top: 1px solid var(--border);
  }
  .hints summary {
    cursor: pointer;
    font-size: .8rem;
    color: var(--text-dim);
    letter-spacing: 1px;
    text-transform: uppercase;
  }
  .hints ul { margin-top: 6px; padding-left: 20px; }
  .hints li { font-size: .8rem; color: var(--text-dim); margin-bottom: 3px; }

  /* ── Footer ───────────────────────────────────────────── */
  .footer-row {
    margin-top: 36px;
    display: flex;
    justify-content: space-between;
    align-items: center;
    flex-wrap: wrap;
    gap: 12px;
  }
  .footer-row .meta { font-size: .75rem; color: var(--text-dim); }

  /* ── Responsive ───────────────────────────────────────── */
  @media (max-width: 560px) {
    .cards { grid-template-columns: 1fr; }
    .score-banner { gap: 20px; }
    .submit-row { flex-direction: column; }
  }

  /* ── Confetti-like flash for captures ─────────────────── */
  @keyframes flashGreen {
    0%   { box-shadow: 0 0 0 0 rgba(0,255,136,.6); }
    100% { box-shadow: 0 0 30px 10px rgba(0,255,136,0); }
  }
  .card.flash { animation: flashGreen .6s ease-out; }
</style>
</head>
<body>

<!-- Toast -->
<div id="toast" class="toast"></div>

<div class="container">

  <!-- Header -->
  <header>
    <h1>[ PROXMOX CTF LAB ]</h1>
    <div class="score-banner">
      <div class="stat">
        <span class="stat-value" id="scoreVal">{{ score }}</span>
        <span class="stat-label">Points</span>
      </div>
      <div class="stat">
        <span class="stat-value" id="flagsVal">{{ captured_count }}/{{ total_flags }}</span>
        <span class="stat-label">Flags</span>
      </div>
      <div class="stat">
        <span class="stat-value">{{ total_possible }}</span>
        <span class="stat-label">Total Possible</span>
      </div>
    </div>
    <div class="progress-bar-container">
      <div class="progress-bar-fill" id="progressBar"
           style="width: {{ (score / total_possible * 100) | round(1) if total_possible else 0 }}%"></div>
    </div>
  </header>

  <!-- Flag submission (sticky) -->
  <div class="submit-section">
    <form id="flagForm" class="submit-row" autocomplete="off">
      <input type="text" id="flagInput" placeholder="Enter flag... FLAG{...}" spellcheck="false" autofocus>
      <button type="submit" class="btn">Submit</button>
    </form>
  </div>

  <!-- Challenge cards -->
  <div class="cards">
    {% for ch in challenges %}
    <div class="card" id="card-{{ ch.id }}">
      <div class="card-header">
        <span class="card-title">{{ ch.name }}</span>
        {% set ns = namespace(done=0) %}
        {% for f in ch.flags %}
          {% if f.flag in captured %}{% set ns.done = ns.done + 1 %}{% endif %}
        {% endfor %}
        <span class="card-completion">{{ ns.done }}/{{ ch.flags | length }}</span>
      </div>
      <div class="card-desc">{{ ch.description }}</div>

      {% for f in ch.flags %}
      <div class="flag-row" data-flag="{{ f.flag }}">
        {% if f.flag in captured %}
        <span class="flag-icon captured">&#10003;</span>
        {% else %}
        <span class="flag-icon pending">&#9679;</span>
        {% endif %}
        <span class="flag-label">{{ f.label }}</span>
        <span class="badge badge-{{ f.difficulty | lower }}">{{ f.difficulty }}</span>
        <span class="pts">{{ f.points }}pts</span>
      </div>
      {% endfor %}

      <details class="hints">
        <summary>Hints</summary>
        <ul>
          {% for h in ch.hints %}
          <li>{{ h }}</li>
          {% endfor %}
        </ul>
      </details>
    </div>
    {% endfor %}
  </div>

  <!-- Footer -->
  <div class="footer-row">
    <span class="meta">Proxmox CTF Lab &mdash; 4 categories &middot; 13 flags &middot; 2500 pts</span>
    <button class="btn btn-danger" id="resetBtn">Reset Progress</button>
  </div>

</div>

<script>
(function(){
  const toast    = document.getElementById("toast");
  const flagForm = document.getElementById("flagForm");
  const flagIn   = document.getElementById("flagInput");
  const scoreVal = document.getElementById("scoreVal");
  const flagsVal = document.getElementById("flagsVal");
  const progBar  = document.getElementById("progressBar");
  const resetBtn = document.getElementById("resetBtn");
  const TOTAL    = {{ total_possible }};
  const TOTAL_F  = {{ total_flags }};

  function showToast(msg, type, duration){
    duration = duration || 3000;
    toast.textContent = msg;
    toast.className = "toast " + type + " visible";
    clearTimeout(toast._t);
    toast._t = setTimeout(function(){ toast.classList.remove("visible"); }, duration);
  }

  flagForm.addEventListener("submit", function(e){
    e.preventDefault();
    var flag = flagIn.value.trim();
    if(!flag) return;

    fetch("/submit", {
      method: "POST",
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify({flag: flag})
    })
    .then(function(r){ return r.json(); })
    .then(function(d){
      if(d.success){
        showToast(d.message, "success", 4000);
        scoreVal.textContent = d.score;
        flagsVal.textContent = d.captured_count + "/" + TOTAL_F;
        progBar.style.width = ((d.score / TOTAL) * 100).toFixed(1) + "%";

        /* Update the specific flag row */
        var rows = document.querySelectorAll('.flag-row[data-flag="' + CSS.escape(d.flag) + '"]');
        rows.forEach(function(row){
          var icon = row.querySelector(".flag-icon");
          if(icon){ icon.innerHTML = "&#10003;"; icon.className = "flag-icon captured"; }
        });

        /* Update card completion counter */
        var card = document.getElementById("card-" + d.category);
        if(card){
          card.classList.add("flash");
          setTimeout(function(){ card.classList.remove("flash"); }, 700);
          var checks = card.querySelectorAll(".flag-icon.captured").length;
          var total  = card.querySelectorAll(".flag-row").length;
          var comp   = card.querySelector(".card-completion");
          if(comp) comp.textContent = checks + "/" + total;
        }

        flagIn.value = "";
      } else {
        showToast(d.message, d.message.indexOf("already") !== -1 ? "info" : "error");
      }
    })
    .catch(function(){ showToast("Network error", "error"); });
  });

  resetBtn.addEventListener("click", function(){
    if(!confirm("Reset all progress? This cannot be undone.")) return;
    fetch("/reset", {method:"POST"})
    .then(function(r){ return r.json(); })
    .then(function(d){
      if(d.success){
        showToast(d.message, "info");
        setTimeout(function(){ location.reload(); }, 800);
      }
    })
    .catch(function(){ showToast("Network error", "error"); });
  });
})();
</script>
</body>
</html>
HTMLEOF

# -----------------------------------------------------------
# 5. Gunicorn systemd service
# -----------------------------------------------------------
echo "[*] Creating systemd service..."

cat > /etc/systemd/system/scoreboard.service << EOF
[Unit]
Description=CTF Scoreboard (Gunicorn)
After=network.target

[Service]
User=${APP_USER}
Group=${APP_USER}
WorkingDirectory=${APP_DIR}
ExecStart=${VENV_DIR}/bin/gunicorn --workers 2 --bind 127.0.0.1:5000 app:app
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

# -----------------------------------------------------------
# 6. Nginx reverse proxy
# -----------------------------------------------------------
echo "[*] Configuring nginx..."

cat > /etc/nginx/sites-available/scoreboard << 'NGINX'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    location / {
        proxy_pass         http://127.0.0.1:5000;
        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
    }
}
NGINX

# Enable site, disable default
rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/scoreboard /etc/nginx/sites-enabled/scoreboard

# -----------------------------------------------------------
# 7. Fix permissions and start services
# -----------------------------------------------------------
echo "[*] Setting permissions..."
chown -R "${APP_USER}:${APP_USER}" "${APP_DIR}"

echo "[*] Starting services..."
systemctl daemon-reload
systemctl enable --now scoreboard.service
systemctl restart nginx
systemctl enable nginx

# -----------------------------------------------------------
# 8. Verify
# -----------------------------------------------------------
echo ""
echo "========================================"
echo "  Setup complete!"
echo "========================================"
echo ""
echo "  Scoreboard URL:  http://$(hostname -I | awk '{print $1}')"
echo "  App directory:   ${APP_DIR}"
echo "  Database:        ${DB_PATH}"
echo "  Service:         systemctl status scoreboard"
echo ""
echo "  Total flags: 13  |  Total points: 2500"
echo ""
