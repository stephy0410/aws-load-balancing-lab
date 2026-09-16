#!/bin/bash
# One-time bootstrap for the Tailscale Funnel edge (trusted public HTTPS, $0 cost,
# no AWS API Gateway / purchased domain / Route53+ACM-DNS needed).
#
# This runs ONCE, by hand, on an already-on machine you own outside AWS (here: a
# Linux box reachable via Tailscale + SSH). It is NOT part of `terraform apply` —
# Terraform only keeps the edge's reverse-proxy target in sync afterwards (see the
# null_resource.edge_proxy_sync in main.tf), because this machine isn't an AWS
# resource Terraform can create/destroy.
#
# Architecture:
#   Browser --HTTPS (Let's Encrypt via Tailscale)--> this machine
#     -> Node reverse proxy on 127.0.0.1:8080 (systemd --user service, no sudo needed
#        after this bootstrap)
#     -> AWS ALB (HTTP) -> round robin across the 2 EC2 instances (untouched)
#
# Run each numbered block on the edge machine itself.

set -euxo pipefail

# --- 1. One-time OS packages + permissions (needs sudo, run by hand) ---
# sudo apt update && sudo apt install -y nodejs
# sudo loginctl enable-linger "$USER"          # keep the user service alive after logout/reboot
# sudo systemctl disable --now nginx           # not used; replaced by the Node proxy below
# sudo tailscale set --operator="$USER"        # let `tailscale funnel`/`serve` run without sudo

# --- 2. Reverse proxy (Node, no external deps) ---
mkdir -p ~/edge-proxy ~/.config/systemd/user

cat > ~/edge-proxy/proxy.js <<'NODEJS'
// Talks HTTPS to the ALB (port 443), NOT HTTP (port 80): the ALB's HTTP listener
// only 301-redirects to HTTPS, it doesn't forward, so a plain-HTTP backend request
// here would just get a redirect back instead of the app's response.
const https = require('https');
const http = require('http');

const target = process.env.ALB_TARGET;
const port = process.env.PORT || 8080;

if (!target) {
  console.error('ALB_TARGET env var is required');
  process.exit(1);
}

const server = http.createServer((req, res) => {
  const proxyReq = https.request(
    {
      host: target,
      port: 443,
      method: req.method,
      path: req.url,
      headers: { ...req.headers, host: target },
      rejectUnauthorized: false, // ALB's cert is self-signed on this internal hop; the public edge (Tailscale Funnel) is what's actually trusted
    },
    (proxyRes) => {
      res.writeHead(proxyRes.statusCode, proxyRes.headers);
      proxyRes.pipe(res);
    }
  );

  proxyReq.on('error', (err) => {
    console.error('proxy error:', err.message);
    if (!res.headersSent) res.writeHead(502, { 'Content-Type': 'text/plain' });
    res.end('Bad Gateway: ' + err.message);
  });

  req.pipe(proxyReq);
});

server.listen(port, '127.0.0.1', () => {
  console.log(`edge proxy listening on 127.0.0.1:${port} -> https://${target}`);
});
NODEJS

# ALB_TARGET here is a placeholder; `terraform apply` overwrites this file with the
# real ALB DNS name on every run via null_resource.edge_proxy_sync.
cat > ~/edge-proxy/env <<'ENVFILE'
ALB_TARGET=CHANGE_ME.elb.amazonaws.com
PORT=8080
ENVFILE

cat > ~/.config/systemd/user/edge-proxy.service <<'UNIT'
[Unit]
Description=Edge reverse proxy to the AWS ALB (fronted by Tailscale Funnel)
After=network-online.target
Wants=network-online.target

[Service]
EnvironmentFile=%h/edge-proxy/env
ExecStart=/usr/bin/node %h/edge-proxy/proxy.js
Restart=always
RestartSec=2

[Install]
WantedBy=default.target
UNIT

systemctl --user daemon-reload
systemctl --user enable --now edge-proxy

# --- 3. Public HTTPS entry point ---
# Requires Funnel to be allowed for this node once, via the link `tailscale funnel`
# prints the first time (approve it at https://login.tailscale.com/f/funnel?node=...).
tailscale funnel --bg 8080

# --- 4. Sanity check ---
sleep 1
curl -sf -o /dev/null http://127.0.0.1:8080/health && echo "local proxy OK" || echo "local proxy FAILED (expected until ALB_TARGET is set for real)"
tailscale funnel status
