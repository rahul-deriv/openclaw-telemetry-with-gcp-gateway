# OpenClaw Telemetry Plugin

> **Observability for OpenClaw.** Capture every tool call, LLM request, and agent session — with built-in redaction, tamper-proof hash chains, syslog/SIEM forwarding, and rate limiting. Drop it in and know exactly what your agents are doing.

**Repository:** https://github.com/rahul-deriv/openclaw-telemetry-with-gcp-gateway

---

# OpenClaw Telemetry Plugin - TL;DR

Captures tool calls, LLM usage, agent lifecycle, and message events. Outputs to JSONL file and optionally to syslog for SIEM integration.

## Quick Start

### 1. Install

Clone the repository:
```bash
git clone https://github.com/rahul-deriv/openclaw-telemetry-with-gcp-gateway.git
cd openclaw-telemetry-with-gcp-gateway
```

Then install:
```bash
openclaw plugins install .
```

Or copy manually:
```bash
cp -R . ~/.openclaw/extensions/telemetry
```

### 2. Configure

Via Control UI: **Settings → Config → plugins.entries.telemetry**

Or edit `~/.openclaw/config.json`:
```json
{
  "plugins": {
    "entries": {
      "telemetry": {
        "enabled": true,
        "config": {
          "enabled": true
        }
      }
    }
  }
}
```

### 3. Restart Gateway

```bash
openclaw gateway
```

Logs write to `~/.openclaw/logs/telemetry.jsonl` by default.

### Package Installation (Coming Soon)

```bash
openclaw plugins install @openclaw/telemetry-gateway
```

## Configuration

### Core Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enabled` | boolean | `false` | Enable telemetry capture |
| `filePath` | string | `~/.openclaw/logs/telemetry.jsonl` | JSONL output file path |

### GCP API Gateway Output

Forward events to a GCP API Gateway via HTTP with API key authentication.

> **Admin-managed:** The endpoint URL and API key are **not** user-configurable. They are written to a root-owned file (`/Library/Application Support/OpenClaw/telemetry-gateway.json`, mode `640`) by MDM at deploy time. Users cannot read or modify them. The options below are the only tuning knobs exposed to end users.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `gcpApiGateway.batchSize` | number | `100` | Events per batch |
| `gcpApiGateway.flushIntervalMs` | number | `5000` | Max wait before flush (ms) |
| `gcpApiGateway.maxRetries` | number | `3` | Retry attempts |
| `gcpApiGateway.retryDelayMs` | number | `1000` | Delay between retries (ms) |
| `gcpApiGateway.timeoutMs` | number | `10000` | Request timeout (ms) |

**MDM deployment (Jamf):** Use `install.sh`. Script parameters:
- `$4` — GCP API Gateway endpoint URL
- `$5` — GCP API key
- `$6` — GitHub repo URL (optional)
- `$7` — GitHub branch (optional, default: `main`)

### Syslog Output

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `syslog.enabled` | boolean | `false` | Enable syslog output |
| `syslog.host` | string | required | Syslog server hostname |
| `syslog.port` | number | `514` | Syslog server port |
| `syslog.protocol` | string | `udp` | Transport: `udp`, `tcp`, or `tcp-tls` |
| `syslog.format` | string | `cef` | Message format: `cef` or `json` |
| `syslog.facility` | number | `16` | Syslog facility (16 = local0) |
| `syslog.appName` | string | `openclaw` | App name in syslog messages |

### Sensitive Data Redaction

Automatically redacts sensitive data (API keys, tokens, passwords) from tool parameters before logging.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `redact.enabled` | boolean | `false` | Enable redaction |
| `redact.patterns` | string[] | (built-in) | Regex patterns to match. Prefix with `(?i)` for case-insensitive |
| `redact.replacement` | string | `[REDACTED]` | Replacement text |

Default patterns detect:
- OpenAI keys (`sk-...`)
- GitHub tokens (`ghp_...`, `gho_...`)
- GitLab tokens (`glpat-...`)
- Slack tokens (`xox[baprs]-...`)
- AWS credentials
- Bearer tokens
- Common `api_key`, `password`, `secret`, `token` patterns

### Event Integrity (Hash Chain)

Adds cryptographic hash chain to events for tamper detection. Each event includes `prevHash` and `hash` fields, forming a verifiable chain.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `integrity.enabled` | boolean | `false` | Enable hash chain |
| `integrity.algorithm` | string | `sha256` | Hash algorithm |

### Rate Limiting

Prevents runaway agents from flooding outputs. Uses token bucket algorithm.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `rateLimit.enabled` | boolean | `false` | Enable rate limiting |
| `rateLimit.maxEventsPerSecond` | number | `100` | Sustained event rate |
| `rateLimit.burstSize` | number | `200` | Burst capacity |

### Log Rotation

Rotates JSONL files to prevent unbounded growth.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `rotate.enabled` | boolean | `false` | Enable rotation |
| `rotate.maxSizeBytes` | number | `10485760` | Max file size (10MB) |
| `rotate.maxFiles` | number | `5` | Rotated files to keep |
| `rotate.compress` | boolean | `true` | Gzip rotated files |

## Example Configurations

### Basic

```json
{
  "plugins": {
    "telemetry": {
      "enabled": true
    }
  }
}
```

### Enterprise (all security features)

```json
{
  "plugins": {
    "telemetry": {
      "enabled": true,
      "redact": {
        "enabled": true
      },
      "integrity": {
        "enabled": true
      },
      "rateLimit": {
        "enabled": true,
        "maxEventsPerSecond": 50
      },
      "rotate": {
        "enabled": true,
        "maxSizeBytes": 52428800,
        "maxFiles": 10
      },
      "syslog": {
        "enabled": true,
        "host": "siem.company.com",
        "port": 6514,
        "protocol": "tcp-tls",
        "format": "cef"
      }
    }
  }
}
```

### Custom Redaction Patterns

```json
{
  "plugins": {
    "telemetry": {
      "enabled": true,
      "redact": {
        "enabled": true,
        "patterns": [
          "(?i)internal-secret-[a-z0-9]+",
          "COMPANY-[A-Z]{4}-[0-9]{8}"
        ],
        "replacement": "***"
      }
    }
  }
}
```

## Events

| Event | Description |
|-------|-------------|
| `tool.start` | Tool invocation started |
| `tool.end` | Tool invocation completed (success/failure, duration) |
| `message.in` | Inbound message received |
| `message.out` | Outbound message sent |
| `llm.usage` | LLM API call (tokens, cost, duration) |
| `agent.start` | Agent session started |
| `agent.end` | Agent session completed |

### JSONL Format

Basic event:
```json
{"type":"tool.start","toolName":"bash","params":{"cmd":"ls"},"sessionKey":"telegram:123","seq":1,"ts":1738517700000}
```

With integrity enabled:
```json
{"type":"tool.start","toolName":"bash","params":{"cmd":"ls"},"seq":1,"ts":1738517700000,"prevHash":"0000000000000000000000000000000000000000000000000000000000000000","hash":"a1b2c3d4e5f6..."}
```

With redaction (before):
```json
{"type":"tool.start","toolName":"bash","params":{"cmd":"curl -H 'Authorization: Bearer sk-abc123...'"}}
```

With redaction (after):
```json
{"type":"tool.start","toolName":"bash","params":{"cmd":"curl -H 'Authorization: [REDACTED]'"}}
```

### CEF Format (syslog)

```
CEF:0|OpenClaw|openclaw|1.0|1001|Tool Invocation Started|3|rt=1738517700000 cs1=telegram:123 cs1Label=sessionKey act=bash cs5=a1b2c3... cs5Label=hash cs6=0000... cs6Label=prevHash
```

## Verifying Hash Chain Integrity

```bash
# Verify chain integrity with jq
jq -s '
  reduce .[] as $evt (
    {valid: true, prev: ("0" * 64)};
    if .valid and $evt.prevHash == .prev
    then {valid: true, prev: $evt.hash}
    else {valid: false, prev: .prev, broken_at: $evt.seq}
    end
  )
' ~/.openclaw/logs/telemetry.jsonl
```

## Querying

```bash
# Follow live events
tail -f ~/.openclaw/logs/telemetry.jsonl | jq .

# Filter by event type
jq 'select(.type=="tool.end")' ~/.openclaw/logs/telemetry.jsonl

# Get LLM costs
jq 'select(.type=="llm.usage") | {model, costUsd}' ~/.openclaw/logs/telemetry.jsonl

# Correlate by session
jq 'select(.sessionKey=="telegram:123456")' ~/.openclaw/logs/telemetry.jsonl

# Find failed tool calls
jq 'select(.type=="tool.end" and .success==false)' ~/.openclaw/logs/telemetry.jsonl
```

## Rotated Files

When rotation is enabled, files are named:
- `telemetry.jsonl` - current file
- `telemetry.jsonl.1.gz` - most recent rotated (compressed)
- `telemetry.jsonl.2.gz` - older
- ...up to `maxFiles`

To read compressed logs:
```bash
zcat ~/.openclaw/logs/telemetry.jsonl.1.gz | jq .
```

## SIEM Integration

The file-based output works with log shippers:
- **Filebeat**: Configure a `filestream` input pointing to the JSONL file
- **Fluentd**: Use `in_tail` with JSON parser
- **Splunk Universal Forwarder**: Monitor the file path

The syslog output connects directly to:
- Splunk (syslog input)
- QRadar (CEF supported natively)
- ArcSight (CEF supported natively)
- Elastic SIEM (via Logstash syslog input)
- Any RFC 5424 compliant collector

## License

Apache 2.0 — see LICENSE for details.
