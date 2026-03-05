#!/bin/bash
# OpenClaw Telemetry Gateway - MDM Installer
# Deploys telemetry plugin from GitHub and configures GCP API Gateway
#
# Parameters (e.g. Jamf $4, $5, $6, $7):
#   $4 = GCP API Gateway endpoint URL (required)
#   $5 = GCP API key (required)
#   $6 = GitHub repo URL (optional)
#   $7 = GitHub branch (optional, default: main)
#
# Example (Jamf script fields):
#   $4: https://api-gateway-xyz.run.app/telemetry
#   $5: your-api-key
#   $6: https://github.com/yourorg/openclaw-telemetry-gateway
#   $7: main

set -e

# Both endpoint and API key are injected by MDM — never hardcoded.
GCP_ENDPOINT="${4:-}"
GCP_API_KEY="${5:-}"
GITHUB_REPO="${6:-https://github.com/rahul-deriv/openclaw-telemetry-with-gcp-gateway}"
GITHUB_BRANCH="${7:-main}"
INSTALL_DIR="/tmp/openclaw-telemetry-gateway-install"
MANAGED_CONFIG_DIR="/Library/Application Support/OpenClaw"
MANAGED_CONFIG="${MANAGED_CONFIG_DIR}/telemetry-gateway.json"
PLUGIN_ID="telemetry"

if [[ -z "$GCP_ENDPOINT" ]]; then
  echo "ERROR: GCP API Gateway endpoint URL (\$4) is required."
  exit 1
fi

if [[ -z "$GCP_API_KEY" ]]; then
  echo "ERROR: GCP API key (\$5) is required."
  exit 1
fi

# Determine the logged-in user (Jamf runs as root, plugin runs as user)
LOGGED_IN_USER=$(stat -f "%Su" /dev/console 2>/dev/null || echo "")
if [[ -z "$LOGGED_IN_USER" || "$LOGGED_IN_USER" == "root" ]]; then
  echo "ERROR: Could not determine logged-in user."
  exit 1
fi
USER_HOME=$(dscl . -read "/Users/${LOGGED_IN_USER}" NFSHomeDirectory | awk '{print $2}')
OPENCLAW_EXTENSIONS="${USER_HOME}/.openclaw/extensions"
OPENCLAW_CONFIG="${USER_HOME}/.openclaw/openclaw.json"

# --- 1. Write managed config (root-owned, user cannot edit) ---
mkdir -p "${MANAGED_CONFIG_DIR}"
# Both endpoint and apiKey are written here — neither is in the plugin source code.
cat > "${MANAGED_CONFIG}" <<EOF
{
  "endpoint": "${GCP_ENDPOINT}",
  "apiKey": "${GCP_API_KEY}"
}
EOF
# Root owns it, admin group can read, users cannot write or read
chown root:admin "${MANAGED_CONFIG}"
chmod 640 "${MANAGED_CONFIG}"
echo "Managed config written: ${MANAGED_CONFIG} (root:admin 640)"

# --- 2. Install plugin from GitHub ---
mkdir -p "${OPENCLAW_EXTENSIONS}"
echo "Installing OpenClaw telemetry gateway from ${GITHUB_REPO}..."
rm -rf "${INSTALL_DIR}"
git clone --depth 1 --branch "${GITHUB_BRANCH}" "${GITHUB_REPO}" "${INSTALL_DIR}" 2>/dev/null || {
  echo "ERROR: Failed to clone ${GITHUB_REPO}"
  exit 1
}
PLUGIN_TARGET="${OPENCLAW_EXTENSIONS}/${PLUGIN_ID}"
rm -rf "${PLUGIN_TARGET}"
cp -R "${INSTALL_DIR}" "${PLUGIN_TARGET}"
chown -R "${LOGGED_IN_USER}" "${PLUGIN_TARGET}"
rm -rf "${INSTALL_DIR}"
echo "Plugin installed to ${PLUGIN_TARGET}"

# --- 3. Enable plugin in user config (no API key or endpoint written here) ---
mkdir -p "$(dirname "${OPENCLAW_CONFIG}")"
if [[ ! -f "${OPENCLAW_CONFIG}" ]]; then
  echo '{"plugins":{"allow":[],"entries":{}},"diagnostics":{"enabled":true}}' > "${OPENCLAW_CONFIG}"
fi

if command -v jq &>/dev/null; then
  jq '
    .diagnostics.enabled = true |
    .plugins.allow = (if .plugins.allow | type == "array" then (. + ["telemetry"] | unique) else ["telemetry"] end) |
    .plugins.entries.telemetry = {
      enabled: true,
      config: {
        enabled: true,
        redact: { enabled: true },
        integrity: { enabled: true }
      }
    }
  ' "${OPENCLAW_CONFIG}" > "${OPENCLAW_CONFIG}.tmp" && mv "${OPENCLAW_CONFIG}.tmp" "${OPENCLAW_CONFIG}"
else
  python3 -c "
import json
path = '${OPENCLAW_CONFIG}'
with open(path) as f:
    cfg = json.load(f)
cfg.setdefault('diagnostics', {})['enabled'] = True
cfg.setdefault('plugins', {})
cfg['plugins'].setdefault('allow', [])
if 'telemetry' not in cfg['plugins']['allow']:
    cfg['plugins']['allow'].append('telemetry')
cfg['plugins'].setdefault('entries', {})
cfg['plugins']['entries']['telemetry'] = {
    'enabled': True,
    'config': {
        'enabled': True,
        'redact': {'enabled': True},
        'integrity': {'enabled': True}
    }
}
with open(path, 'w') as f:
    json.dump(cfg, f, indent=2)
"
fi
chown "${LOGGED_IN_USER}" "${OPENCLAW_CONFIG}"
echo "User config updated: ${OPENCLAW_CONFIG}"

# --- 4. Restart gateway ---
if pgrep -f "openclaw.*gateway" &>/dev/null; then
  echo "Restarting OpenClaw gateway..."
  pkill -f "openclaw.*gateway" 2>/dev/null || true
  sleep 2
fi

echo "OpenClaw telemetry gateway installed and configured."
exit 0
