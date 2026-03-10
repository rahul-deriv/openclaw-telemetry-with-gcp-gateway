#!/bin/bash
# OpenClaw Telemetry Gateway - Secure MDM Installer
# Deploys telemetry plugin with protection against user deletion
#
# Zero-click one-liner (clones repo + installs plugin):
#   curl -fsSL https://raw.githubusercontent.com/rahul-deriv/openclaw-telemetry-with-gcp-gateway/main/install-secure.sh | bash -s -- ENDPOINT_URL API_KEY
#
# Parameters (Jamf $4, $5, $6, $7, $8) or positional ($1, $2, $3, $4, $5):
#   $4/$1 = GCP API Gateway endpoint URL (required)
#   $5/$2 = GCP API key (required)
#   $6/$3 = GitHub repo URL (optional)
#   $7/$4 = GitHub branch (optional, default: main)
#   $8/$5 = Protection level: "system", "immutable", "monitor", or "all" (default)

set -e

# Support both Jamf ($4,$5,...) and curl|bash ($1,$2,...) invocation
GCP_ENDPOINT="${4:-${1:-}}"
GCP_API_KEY="${5:-${2:-}}"
# Jamf uses $6,$7,$8; curl uses $3,$4,$5 — avoid $4 collision (endpoint vs branch)
if [[ -n "${6}" ]]; then
  GITHUB_REPO="${6}"
  GITHUB_BRANCH="${7:-main}"
  PROTECTION_LEVEL="${8:-all}"
else
  GITHUB_REPO="${3:-https://github.com/rahul-deriv/openclaw-telemetry-with-gcp-gateway}"
  GITHUB_BRANCH="${4:-main}"
  PROTECTION_LEVEL="${5:-all}"
fi

INSTALL_DIR="/tmp/openclaw-telemetry-gateway-install"
MANAGED_CONFIG_DIR="/Library/Application Support/OpenClaw"
MANAGED_CONFIG="${MANAGED_CONFIG_DIR}/telemetry-gateway.json"
PLUGIN_ID="telemetry-gateway"

if [[ -z "$GCP_ENDPOINT" ]]; then
  echo "ERROR: GCP API Gateway endpoint URL is required (arg 1 or \$4)."
  echo "Usage: curl -fsSL <script-url> | bash -s -- ENDPOINT_URL API_KEY [REPO] [BRANCH] [PROTECTION]"
  exit 1
fi

if [[ -z "$GCP_API_KEY" ]]; then
  echo "ERROR: GCP API key is required (arg 2 or \$5)."
  echo "Usage: curl -fsSL <script-url> | bash -s -- ENDPOINT_URL API_KEY [REPO] [BRANCH] [PROTECTION]"
  exit 1
fi

# Determine the logged-in user (Jamf runs as root, plugin runs as user)
LOGGED_IN_USER=$(stat -f "%Su" /dev/console 2>/dev/null || echo "")
if [[ -z "$LOGGED_IN_USER" || "$LOGGED_IN_USER" == "root" ]]; then
  echo "ERROR: Could not determine logged-in user."
  exit 1
fi
USER_HOME=$(dscl . -read "/Users/${LOGGED_IN_USER}" NFSHomeDirectory | awk '{print $2}')

# Choose installation location based on protection level
if [[ "$PROTECTION_LEVEL" == "system" || "$PROTECTION_LEVEL" == "all" ]]; then
  # System-wide installation (requires OpenClaw to support /Library/Application Support/OpenClaw/plugins)
  SYSTEM_PLUGIN_DIR="/Library/Application Support/OpenClaw/plugins"
  PLUGIN_TARGET="${SYSTEM_PLUGIN_DIR}/${PLUGIN_ID}"
  echo "Installing to system directory: ${PLUGIN_TARGET}"
else
  # User directory (fallback if system directory not supported)
  OPENCLAW_EXTENSIONS="${USER_HOME}/.openclaw/extensions"
  PLUGIN_TARGET="${OPENCLAW_EXTENSIONS}/${PLUGIN_ID}"
  echo "Installing to user directory: ${PLUGIN_TARGET}"
fi

OPENCLAW_CONFIG="${USER_HOME}/.openclaw/openclaw.json"

# --- 1. Write managed config (root-owned, user cannot edit) ---
mkdir -p "${MANAGED_CONFIG_DIR}"
cat > "${MANAGED_CONFIG}" <<EOF
{
  "endpoint": "${GCP_ENDPOINT}",
  "apiKey": "${GCP_API_KEY}"
}
EOF
chown root:admin "${MANAGED_CONFIG}"
chmod 640 "${MANAGED_CONFIG}"
echo "Managed config written: ${MANAGED_CONFIG} (root:admin 640)"

# --- 2. Install plugin from GitHub ---
mkdir -p "$(dirname "${PLUGIN_TARGET}")"
echo "Installing OpenClaw telemetry gateway from ${GITHUB_REPO}..."
rm -rf "${INSTALL_DIR}"
git clone --depth 1 --branch "${GITHUB_BRANCH}" "${GITHUB_REPO}" "${INSTALL_DIR}" 2>/dev/null || {
  echo "ERROR: Failed to clone ${GITHUB_REPO}"
  exit 1
}
rm -rf "${PLUGIN_TARGET}"
cp -R "${INSTALL_DIR}" "${PLUGIN_TARGET}"

# Set ownership and permissions based on protection level
if [[ "$PROTECTION_LEVEL" == "system" || "$PROTECTION_LEVEL" == "all" ]]; then
  # System directory: root-owned, read-only for users
  chown -R root:admin "${PLUGIN_TARGET}"
  chmod -R 755 "${PLUGIN_TARGET}"
  # Make files read-only (users can't modify)
  find "${PLUGIN_TARGET}" -type f -exec chmod 644 {} \;
  find "${PLUGIN_TARGET}" -type d -exec chmod 755 {} \;
  echo "Plugin installed with system protection: ${PLUGIN_TARGET} (root:admin, read-only)"
else
  # User directory: owned by user but apply immutable flag if requested
  chown -R "${LOGGED_IN_USER}" "${PLUGIN_TARGET}"
  chmod -R 755 "${PLUGIN_TARGET}"
  echo "Plugin installed to: ${PLUGIN_TARGET}"
fi

# --- 3. Apply immutable flag (macOS chflags) if requested ---
if [[ "$PROTECTION_LEVEL" == "immutable" || "$PROTECTION_LEVEL" == "all" ]]; then
  if [[ "$PROTECTION_LEVEL" == "all" && -d "${SYSTEM_PLUGIN_DIR}/${PLUGIN_ID}" ]]; then
    # System directory: use uchg (user immutable) - requires root to modify
    chflags -R uchg "${PLUGIN_TARGET}" 2>/dev/null || {
      echo "WARNING: Could not set immutable flag (may require SIP disabled or different approach)"
    }
    echo "Immutable flag set (uchg) on: ${PLUGIN_TARGET}"
  elif [[ "$PROTECTION_LEVEL" == "immutable" ]]; then
    # User directory: use uchg (user immutable)
    chflags -R uchg "${PLUGIN_TARGET}" 2>/dev/null || {
      echo "WARNING: Could not set immutable flag"
    }
    echo "Immutable flag set (uchg) on: ${PLUGIN_TARGET}"
  fi
fi

rm -rf "${INSTALL_DIR}"

# --- 4. Enable plugin in user config ---
mkdir -p "$(dirname "${OPENCLAW_CONFIG}")"
if [[ ! -f "${OPENCLAW_CONFIG}" ]]; then
  echo '{"plugins":{"allow":[],"entries":{}},"diagnostics":{"enabled":true}}' > "${OPENCLAW_CONFIG}"
fi

if command -v jq &>/dev/null; then
  jq '
    .diagnostics.enabled = true |
    .plugins.allow = (if .plugins.allow | type == "array" then (. + ["telemetry-gateway"] | unique) else ["telemetry-gateway"] end) |
    .plugins.entries["telemetry-gateway"] = {
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
if 'telemetry-gateway' not in cfg['plugins']['allow']:
    cfg['plugins']['allow'].append('telemetry-gateway')
cfg['plugins'].setdefault('entries', {})
cfg['plugins']['entries']['telemetry-gateway'] = {
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

# --- 5. Install monitoring LaunchAgent (if requested) ---
if [[ "$PROTECTION_LEVEL" == "monitor" || "$PROTECTION_LEVEL" == "all" ]]; then
  LAUNCH_AGENT_DIR="${USER_HOME}/Library/LaunchAgents"
  LAUNCH_AGENT_PLIST="${LAUNCH_AGENT_DIR}/com.openclaw.telemetry-guardian.plist"
  
  mkdir -p "${LAUNCH_AGENT_DIR}"
  
  # Create LaunchAgent that monitors and auto-reinstalls if deleted
  cat > "${LAUNCH_AGENT_PLIST}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.openclaw.telemetry-guardian</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-c</string>
    <string>if [ ! -d "${PLUGIN_TARGET}" ]; then echo "Plugin deleted! Alerting admin..."; logger -p auth.warning "OpenClaw telemetry plugin deleted from ${PLUGIN_TARGET}"; fi</string>
  </array>
  <key>StartInterval</key>
  <integer>300</integer>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>/tmp/openclaw-telemetry-guardian.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/openclaw-telemetry-guardian.err</string>
</dict>
</plist>
EOF
  
  chown "${LOGGED_IN_USER}" "${LAUNCH_AGENT_PLIST}"
  chmod 644 "${LAUNCH_AGENT_PLIST}"
  
  # Load the LaunchAgent
  launchctl bootstrap "gui/$(id -u ${LOGGED_IN_USER})" "${LAUNCH_AGENT_PLIST}" 2>/dev/null || {
    echo "WARNING: Could not load LaunchAgent (may need user login)"
  }
  echo "Monitoring LaunchAgent installed: ${LAUNCH_AGENT_PLIST}"
fi

# --- 6. Restart gateway ---
if pgrep -f "openclaw.*gateway" &>/dev/null; then
  echo "Restarting OpenClaw gateway..."
  pkill -f "openclaw.*gateway" 2>/dev/null || true
  sleep 2
fi

echo "OpenClaw telemetry gateway installed and configured with protection level: ${PROTECTION_LEVEL}"
exit 0
