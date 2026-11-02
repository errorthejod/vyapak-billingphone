#!/usr/bin/env bash
set -Eeuo pipefail

APP_DIR="${APP_DIR:-$HOME/vyapak-billingphone/app/Vyapak-Billing-Pro-Upgrade}"
APP_NAME="${APP_NAME:-vyapak-billing}"
APP_PORT="${APP_PORT:-3000}"
APP_HOST="${APP_HOST:-127.0.0.1}"
CONFIG="$APP_DIR/vite.config.ts"
BACKUP="$CONFIG.before-aws-deploy.$(date +%Y%m%d-%H%M%S).bak"

say() { printf '\n\033[1;34m[Vyapak deploy]\033[0m %s\n' "$*"; }
die() { printf '\n\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

command -v node >/dev/null || die "Node.js is not installed."
command -v npm >/dev/null || die "npm is not installed."
command -v pm2 >/dev/null || die "PM2 is not installed. Install it with: sudo npm install -g pm2"

[[ -d "$APP_DIR" ]] || die "Project folder not found: $APP_DIR"
[[ -f "$CONFIG" ]] || die "vite.config.ts not found: $CONFIG"
cd "$APP_DIR"

say "Checking project and saving a config backup"
cp -a "$CONFIG" "$BACKUP"
printf 'Backup: %s\n' "$BACKUP"

say "Configuring Nitro for a standard Node.js server"
node --input-type=module <<'NODE'
import fs from 'node:fs';

const file = 'vite.config.ts';
let src = fs.readFileSync(file, 'utf8');

if (/preset\s*:\s*["']node-server["']/.test(src)) {
  console.log('Node server preset already appears in vite.config.ts');
} else {
  const marker = 'export default defineConfig({';
  if (!src.includes(marker)) {
    console.error('Could not safely locate defineConfig object; no config changes made.');
    process.exit(2);
  }
  src = src.replace(marker, `${marker}\n  nitro: { preset: "node-server" },`);
  fs.writeFileSync(file, src);
  console.log('Added nitro: { preset: "node-server" }');
}
NODE

say "Building application"
if ! npm run build; then
  cp -a "$BACKUP" "$CONFIG"
  die "Build failed. Original vite.config.ts restored. Review build output above."
fi

if [[ ! -f .output/nitro.json ]]; then
  cp -a "$BACKUP" "$CONFIG"
  die "Build did not produce .output/nitro.json. Original config restored."
fi

PRESET="$(node -e "const x=require('./.output/nitro.json'); process.stdout.write(x.preset || '')")"
if [[ "$PRESET" != "node-server" ]]; then
  cp -a "$BACKUP" "$CONFIG"
  die "Build still uses preset '$PRESET', not node-server. Original config restored. Do not start this build with PM2."
fi

[[ -f .output/server/index.mjs ]] || die "Expected Node server entry .output/server/index.mjs is missing."

say "Starting/restarting PM2 process"
if pm2 describe "$APP_NAME" >/dev/null 2>&1; then
  APP_PORT="$APP_PORT" HOST="$APP_HOST" pm2 restart "$APP_NAME" --update-env
else
  APP_PORT="$APP_PORT" HOST="$APP_HOST" pm2 start .output/server/index.mjs \
    --name "$APP_NAME" --time --update-env
fi

pm2 save

say "Waiting for local HTTP response"
ok=0
for _ in $(seq 1 20); do
  if curl --silent --show-error --fail "http://${APP_HOST}:${APP_PORT}/" >/dev/null 2>&1; then
    ok=1
    break
  fi
  sleep 1
done

if [[ "$ok" -ne 1 ]]; then
  pm2 logs "$APP_NAME" --lines 40 --nostream || true
  die "App did not answer on http://${APP_HOST}:${APP_PORT}/. Nginx was not changed."
fi

say "Deployment successful"
printf 'Preset: %s\nURL: http://%s:%s/\n' "$PRESET" "$APP_HOST" "$APP_PORT"
printf '\nNext: configure Nginx and HTTPS after confirming the EC2 security group allows inbound TCP 80 and 443.\n'
