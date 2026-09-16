#!/bin/bash
set -euxo pipefail

# Log everything from this script to a file for debugging (tail -f /var/log/user-data.log)
exec > >(tee -a /var/log/user-data.log) 2>&1
echo "=== user-data started $(date -u) ==="

# --- Install Node.js (Amazon Linux 2023) ---
for i in 1 2 3 4 5; do
  dnf install -y nodejs && break
  echo "dnf install failed (attempt $i), retrying in 10s..."
  sleep 10
done
node --version

# --- Application ---
mkdir -p /opt/webapp

cat > /opt/webapp/app.js <<'EOF'
const http = require('http');
const os = require('os');

const port = process.env.PORT || 80;
const METADATA_BASE = 'http://169.254.169.254/latest';

// Track how many requests this specific instance has served, to make
// round-robin behavior across the two EC2s visible when you hit the ALB repeatedly.
let hitCount = 0;

function request(method, path, headers = {}) {
  return new Promise((resolve, reject) => {
    const req = http.request(METADATA_BASE + path, { method, headers, timeout: 2000 }, (res) => {
      let body = '';
      res.on('data', (chunk) => (body += chunk));
      res.on('end', () => resolve(body));
    });
    req.on('error', reject);
    req.on('timeout', () => req.destroy(new Error('timeout')));
    req.end();
  });
}

// Fetch instance identity via IMDSv2 (token required, matches metadata_options in Terraform)
async function getMetadata() {
  try {
    const token = await request('PUT', '/api/token', {
      'X-aws-ec2-metadata-token-ttl-seconds': '21600',
    });
    const headers = { 'X-aws-ec2-metadata-token': token };
    const [instanceId, localIpv4, az] = await Promise.all([
      request('GET', '/meta-data/instance-id', headers),
      request('GET', '/meta-data/local-ipv4', headers),
      request('GET', '/meta-data/placement/availability-zone', headers),
    ]);
    return { instanceId, localIpv4, az };
  } catch (err) {
    console.error('metadata fetch failed:', err.message);
    return { instanceId: 'unknown', localIpv4: 'unknown', az: 'unknown' };
  }
}

async function main() {
  const meta = await getMetadata();
  const hostname = os.hostname();
  console.log('resolved metadata:', { hostname, ...meta });

  const server = http.createServer((req, res) => {
    if (req.url === '/health') {
      res.writeHead(200, { 'Content-Type': 'text/plain' });
      res.end('ok');
      return;
    }

    if (req.url === '/api/whoami') {
      hitCount += 1;
      // Force the underlying TCP connection closed after this response, so the
      // browser opens a fresh connection on its next poll and the ALB gets a
      // brand new routing decision each time -> visible round robin, live.
      res.writeHead(200, { 'Content-Type': 'application/json', Connection: 'close' });
      res.end(JSON.stringify({ hostname, hits: hitCount, ...meta }));
      return;
    }

    hitCount += 1;
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    res.end(`<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>SD lab02 &middot; Load Balancer</title>
  <style>
    :root { color-scheme: light; }
    * { box-sizing: border-box; }
    body {
      font-family: system-ui, -apple-system, sans-serif;
      max-width: 44rem;
      margin: 0 auto;
      padding: 2.5rem 1.25rem 4rem;
      color: #2b1014;
      background: #faf1ee;
    }
    h1 { font-size: 1.5rem; margin-bottom: 0.25rem; color: #4a0d1c; }
    .sub { color: #8c5b62; margin-top: 0; margin-bottom: 1.75rem; }
    .badge { display: inline-block; background: linear-gradient(135deg, #6e1423, #a13347); color: #fbe9e9; border-radius: 999px; padding: 0.15rem 0.75rem; font-size: 0.75rem; vertical-align: middle; }
    .card {
      border: 1px solid #ecd9d9;
      border-radius: 16px;
      padding: 1.5rem 1.75rem;
      background: #fffaf8;
      box-shadow: 0 1px 3px rgba(110, 20, 35, 0.08);
      margin-bottom: 1.25rem;
    }
    .current-row { display: flex; align-items: center; gap: 0.75rem; margin-bottom: 1rem; }
    .dot { width: 14px; height: 14px; border-radius: 50%; flex: none; box-shadow: 0 0 0 4px rgba(110, 20, 35, 0.06); }
    .current-row h2 { font-size: 1.1rem; margin: 0; color: #4a0d1c; }
    dl { display: grid; grid-template-columns: auto 1fr; gap: 0.4rem 1rem; margin: 0; }
    dt { font-weight: 600; color: #8c5b62; font-size: 0.85rem; }
    dd { margin: 0; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 0.9rem; }
    .card h3 { font-size: 0.9rem; text-transform: uppercase; letter-spacing: 0.04em; color: #a1717a; margin: 0 0 0.9rem; }
    .dist-row { display: grid; grid-template-columns: 9.5rem 1fr 5.5rem; align-items: center; gap: 0.6rem; margin-bottom: 0.55rem; font-size: 0.85rem; }
    .dist-label { font-family: ui-monospace, monospace; font-weight: 600; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .dist-bar-bg { background: #f1e0df; border-radius: 999px; height: 10px; overflow: hidden; }
    .dist-bar { height: 100%; border-radius: 999px; transition: width 0.4s ease; }
    .dist-pct { text-align: right; color: #8c5b62; }
    ul#log { list-style: none; margin: 0; padding: 0; max-height: 14rem; overflow-y: auto; font-size: 0.85rem; }
    ul#log li { display: flex; align-items: center; gap: 0.5rem; padding: 0.35rem 0; border-bottom: 1px solid #f3e4e2; font-family: ui-monospace, monospace; }
    ul#log li .dot { width: 9px; height: 9px; box-shadow: none; }
    button#ping-now { border: none; background: #6e1423; color: #fbe9e9; padding: 0.5rem 1rem; border-radius: 8px; font-size: 0.85rem; cursor: pointer; }
    button#ping-now:hover { background: #56101c; }
    .foot { color: #a1717a; font-size: 0.8rem; margin-top: 1.5rem; line-height: 1.5; }
    .foot code { background: #f1e0df; color: #4a0d1c; padding: 0.1rem 0.35rem; border-radius: 4px; }
    .foot a { color: #6e1423; }
  </style>
</head>
<body>
  <h1>Load-balanced app <span class="badge">lab02</span></h1>
  <p class="sub">Application Load Balancer &middot; HTTPS &middot; round robin across 2 EC2 instances</p>

  <div class="card">
    <div class="current-row">
      <span class="dot" id="cur-dot" style="background:#6e1423"></span>
      <h2>Currently served by <span id="cur-id" style="font-family: ui-monospace, monospace;">${meta.instanceId}</span></h2>
    </div>
    <dl>
      <dt>Private IPv4</dt><dd id="cur-ip">${meta.localIpv4}</dd>
      <dt>Availability zone</dt><dd id="cur-az">${meta.az}</dd>
      <dt>Hostname</dt><dd>${hostname}</dd>
    </dl>
  </div>

  <div class="card">
    <h3>Live distribution (this browser session)</h3>
    <div id="dist"><p style="color:#999; font-size:0.85rem;">Polling&hellip;</p></div>
    <button id="ping-now" type="button">Ping now</button>
  </div>

  <div class="card">
    <h3>Recent responses</h3>
    <ul id="log"></ul>
  </div>

  <p class="foot">
    This page polls <code>/api/whoami</code> every ~1.5s over a fresh connection each time, so the Instance ID/IP above alternates live as the ALB round-robins between the two EC2s &mdash; no manual reload needed.
    Certificate is self-signed (no public domain available in this AWS Academy account), so your browser may warn once; for the API directly: <code>curl -k</code>.
  </p>

  <script>
    var MAX_LOG = 12;
    var palette = ['#6e1423', '#c9a227', '#3a5a40', '#a1717a', '#4a3728', '#2f6690'];
    var colors = {};
    var colorIdx = 0;
    var counts = {};
    var log = [];

    function colorFor(id) {
      if (!colors[id]) {
        colors[id] = palette[colorIdx % palette.length];
        colorIdx++;
      }
      return colors[id];
    }

    function render(data) {
      var id = data.instanceId;
      counts[id] = (counts[id] || 0) + 1;
      log.unshift({
        instanceId: data.instanceId,
        localIpv4: data.localIpv4,
        time: new Date().toLocaleTimeString(),
        color: colorFor(id)
      });
      if (log.length > MAX_LOG) log.pop();

      document.getElementById('cur-id').textContent = data.instanceId;
      document.getElementById('cur-ip').textContent = data.localIpv4;
      document.getElementById('cur-az').textContent = data.az;
      document.getElementById('cur-dot').style.background = colorFor(id);

      var total = 0;
      for (var k in counts) total += counts[k];

      var distEl = document.getElementById('dist');
      distEl.innerHTML = '';
      for (var instId in counts) {
        var c = counts[instId];
        var pct = Math.round((c / total) * 100);
        var row = document.createElement('div');
        row.className = 'dist-row';
        row.innerHTML =
          '<span class="dist-label" style="color:' + colorFor(instId) + '">' + instId + '</span>' +
          '<div class="dist-bar-bg"><div class="dist-bar" style="width:' + pct + '%; background:' + colorFor(instId) + '"></div></div>' +
          '<span class="dist-pct">' + c + ' (' + pct + '%)</span>';
        distEl.appendChild(row);
      }

      var logEl = document.getElementById('log');
      logEl.innerHTML = log.map(function (l) {
        return '<li><span class="dot" style="background:' + l.color + '"></span>' +
          l.time + ' &mdash; <strong>' + l.instanceId + '</strong> (' + l.localIpv4 + ')</li>';
      }).join('');
    }

    function ping() {
      fetch('/api/whoami', { cache: 'no-store' })
        .then(function (res) { return res.json(); })
        .then(render)
        .catch(function (err) { console.error(err); });
    }

    ping();
    setInterval(ping, 1500);
    document.getElementById('ping-now').addEventListener('click', ping);
  </script>
</body>
</html>`);
  });

  server.listen(port, () => console.log(`listening on ${port}`));
}

main();
EOF

# --- Run as a systemd service ---
cat > /etc/systemd/system/webapp.service <<'EOF'
[Unit]
Description=Node.js web app
After=network.target

[Service]
ExecStart=/usr/bin/node /opt/webapp/app.js
Restart=always
User=root
Environment=PORT=80
WorkingDirectory=/opt/webapp

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now webapp.service
systemctl --no-pager status webapp.service || true

echo "=== user-data finished $(date -u) ==="
