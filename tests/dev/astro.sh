#!/usr/bin/env bash
# note: dev/astro.md
# env: compose
# timeout: 1200
# A real Astro site with one React island, built with the note's Dockerfile. The posts
# API is a local file server; the build runs on the host network to reach it.
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/compose.sh"
source "$NOTES_ROOT/tests/versions.env"

NOTE=dev/astro
nb() { note_block "$NOTE" "$@"; }
IMG=notes-test/astro-$COMPOSE_PROJECT_NAME
trap 'rc=$?; docker rm -f astro-web astro-nginx >/dev/null 2>&1; kill "$api" 2>/dev/null || true; docker rmi -f "$IMG" >/dev/null 2>&1; _t_finish "$rc"' EXIT
pull node:24-alpine nginxinc/nginx-unprivileged:1.30-alpine nginx:1.30-alpine

section "The site"
mkdir -p site/src/pages site/src/components api && cd site
cat >package.json <<EOF
{ "name": "docs", "private": true, "type": "module",
  "scripts": { "build": "astro build" },
  "dependencies": { "astro": "$ASTRO_VERSION", "@astrojs/react": "$ASTRO_REACT_VERSION",
    "react": "$REACT_VERSION", "react-dom": "$REACT_VERSION" } }
EOF
printf "import react from '@astrojs/react';\nexport default { integrations: [react()] };\n" >astro.config.mjs
cat >src/components/SearchBox.jsx <<'EOF'
import { useState } from 'react';
export default function SearchBox() { const [q, setQ] = useState(''); return <input value={q} onChange={e => setQ(e.target.value)} />; }
EOF
echo '[{"title": "First post"}, {"title": "Second post"}]' >../api/posts
(cd ../api && exec python3 -m http.server 8765 --bind 127.0.0.1 >/dev/null 2>&1) & api=$!
nb Astro 1 | sed 's|https://api.example.com/posts|http://127.0.0.1:8765/posts|' >src/pages/index.astro
cat >src/pages/static.astro <<'EOF'
<html><body><p>No island here.</p></body></html>
EOF
cat >src/pages/later.astro <<'EOF'
---
import SearchBox from '../components/SearchBox.jsx';
---
<html><body><SearchBox client:media="(max-width: 50em)" /><SearchBox client:only="react" /></body></html>
EOF
echo '<html><body><h1>Not found</h1></body></html>' >src/pages/404.astro
nb 'Deploying static output' 3 >Dockerfile
check "npm install writes the lockfile" docker run --rm --network host -v "$PWD:/app" -w /app -u "$(id -u):$(id -g)" -e npm_config_cache=/app/.npm \
  node:24-alpine npm install --package-lock-only --no-audit --no-fund
printf 'node_modules\n.npm\ndist\n' >.dockerignore
check "the note's Dockerfile builds the site" docker build -q --network host -t "$IMG" .
kill "$api"
docker run -d --name astro-web -p 8088:8080 "$IMG" >/dev/null
check "the unprivileged image answers on 8080" wait_http http://localhost:8088/ 30
page=$(curl -fsS http://localhost:8088/)
assert_match "the posts were fetched at build time, into the HTML" '<h2>Second post</h2>' "$page"
assert_match "the island is an astro-island element" '<astro-island' "$page"
check_output "a page with no island ships no script at all" '^0$' bash -c 'curl -fsS http://localhost:8088/static/ | grep -c "<script" || true'
check_output "the client:media and client:only directives build" 'client="media"' curl -fsS http://localhost:8088/later/
check_output "hashed assets are under /_astro/" '/_astro/[^"]*\.js' bash -c 'curl -fsS http://localhost:8088/ | grep -o "/_astro/[^\"]*\.js" | head -1'
check_output "the image runs as a non-root user" '^101$' docker exec astro-web id -u

section "npm ci"
cp package.json package.json.ok
sed -i "s/\"react\": \"$REACT_VERSION\"/\"react\": \"19.0.0\"/" package.json
check_output "npm ci fails when package.json and the lockfile disagree" 'npm ci.*can only install|in sync' \
  bash -c "docker run --rm -v \"$PWD:/app\" -w /app -u $(id -u):$(id -g) -e npm_config_cache=/app/.npm node:24-alpine npm ci --no-audit --no-fund 2>&1; true"
mv package.json.ok package.json

section "nginx"
cd .. && mkdir -p tls www
docker cp astro-web:/usr/share/nginx/html/. www/
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=docs.example.com \
  -keyout tls/docs.example.com.key -out tls/docs.example.com.crt 2>/dev/null
chmod 644 tls/*
nb 'Deploying static output' 2 | sed 's/listen 443 ssl;/listen 8443 ssl;/' >docs.conf
run_nginx() {
  docker rm -f astro-nginx >/dev/null 2>&1
  docker run -d --name astro-nginx --network host -v "$PWD/$1:/etc/nginx/conf.d/default.conf:ro" \
    -v "$PWD/tls:/etc/nginx/tls:ro" -v "$PWD/www:/var/www/docs:ro" nginx:1.30-alpine >/dev/null
  wait_http https://localhost:8443/ 20 -k
}
check "nginx -t accepts the server block" docker run --rm -v "$PWD/docs.conf:/etc/nginx/conf.d/default.conf:ro" \
  -v "$PWD/tls:/etc/nginx/tls:ro" nginx:1.30-alpine nginx -t
check "it serves the site over TLS" run_nginx docs.conf
check_output "a missing page is a 404, with the 404 page" '^404 Not found$' \
  bash -c 'printf "%s %s\n" "$(curl -sk -o /tmp/b -w "%{http_code}" https://localhost:8443/nope)" "$(grep -o "Not found" /tmp/b)"'
check_output "HTTP/2 is on" '^2$' curl -sk -o /dev/null -w '%{http_version}' https://localhost:8443/
asset=$(curl -sk https://localhost:8443/ | grep -o '/_astro/[^"]*\.js' | head -1)
check_output "hashed assets are cached hard" 'immutable' bash -c "curl -skI https://localhost:8443$asset | grep -i cache-control"
sed 's|try_files $uri $uri/ =404;|try_files $uri $uri/ /404.html;|' docs.conf >old.conf
run_nginx old.conf
check_output "try_files ... /404.html would answer 200 for a missing page" '^200$' curl -sk -o /dev/null -w '%{http_code}' https://localhost:8443/nope
check_output "listen ... http2 is deprecated" 'the "listen \.\.\. http2" directive is deprecated' \
  bash -c "sed 's/listen 8443 ssl;/listen 8443 ssl http2;/' docs.conf >h2.conf; docker run --rm -v \"$PWD/h2.conf:/etc/nginx/conf.d/default.conf:ro\" -v \"$PWD/tls:/etc/nginx/tls:ro\" nginx:1.30-alpine nginx -t 2>&1"
grep -v ssl_certificate docs.conf >nocert.conf
check_output "listen ... ssl with no certificate fails nginx -t" 'no "ssl_certificate" is defined' \
  bash -c "docker run --rm -v \"$PWD/nocert.conf:/etc/nginx/conf.d/default.conf:ro\" nginx:1.30-alpine nginx -t 2>&1; true"
