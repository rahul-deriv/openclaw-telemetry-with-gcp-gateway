import { readFileSync } from "node:fs";
import type { OpenClawPluginService } from "openclaw/plugin-sdk";
import { onDiagnosticEvent } from "openclaw/plugin-sdk";
import { createIntegrityChain } from "./integrity.js";
import { createRateLimiter } from "./ratelimit.js";
import { createRedactor } from "./redact.js";
import { createGcpApiGatewayWriter, type GcpApiGatewayWriter } from "./gcp-api-gateway.js";
import { createSyslogWriter, type SyslogWriter } from "./syslog.js";
import type { TelemetryConfig, TelemetryEvent, TelemetryEventInput } from "./types.js";
import { createTelemetryWriter, type TelemetryWriter } from "./writer.js";

// Managed config written by MDM (root-owned, user cannot edit).
// Both the endpoint URL and API key are read from here — neither is hardcoded.
const MANAGED_CONFIG_PATH =
  process.env.OPENCLAW_TELEMETRY_MANAGED_CONFIG ??
  "/Library/Application Support/OpenClaw/telemetry-gateway.json";

type ManagedConfig = { endpoint: string; apiKey: string };

function readManagedConfig(): ManagedConfig | null {
  try {
    const raw = readFileSync(MANAGED_CONFIG_PATH, "utf8");
    const parsed = JSON.parse(raw) as Record<string, unknown>;
    const endpoint = parsed.endpoint;
    const apiKey = parsed.apiKey;
    if (
      typeof endpoint === "string" && endpoint.trim() &&
      typeof apiKey === "string" && apiKey.trim()
    ) {
      return { endpoint: endpoint.trim(), apiKey: apiKey.trim() };
    }
    return null;
  } catch {
    return null;
  }
}

export type TelemetryService = OpenClawPluginService & {
  write: (evt: TelemetryEventInput) => void;
};

export function createTelemetryService(): TelemetryService {
  let fileWriter: TelemetryWriter | null = null;
  let syslogWriter: SyslogWriter | null = null;
  let gcpWriter: GcpApiGatewayWriter | null = null;
  let unsubDiag: (() => void) | null = null;
  let redactor = createRedactor();
  let integrity = createIntegrityChain();
  let rateLimiter = createRateLimiter();
  let seq = 0;

  const writeEvent = (evt: TelemetryEventInput) => {
    if (!rateLimiter.allow()) {
      return;
    }
    const redacted = redactor.redact(evt);
    const enriched: TelemetryEvent = {
      ...redacted,
      seq: ++seq,
      ts: Date.now(),
    } as TelemetryEvent;
    const signed = integrity.sign(enriched);

    fileWriter?.write(signed);
    syslogWriter?.write(signed);
    // GCP writer always runs when API key is available — not user-controlled.
    gcpWriter?.write(signed);
  };

  return {
    id: "telemetry-gateway",
    write: writeEvent,
    async start(ctx) {
      // User config — only used for optional settings (file path, redaction, syslog, etc.).
      // GCP forwarding is always on when API key is present regardless of user config.
      const cfg = ctx.config.plugins?.entries?.["telemetry-gateway"]?.config as TelemetryConfig | undefined;

      const filePath = cfg?.filePath ?? `${ctx.stateDir}/logs/telemetry.jsonl`;
      fileWriter = createTelemetryWriter(filePath, cfg?.rotate);
      ctx.logger.info(`telemetry: ${filePath}`);

      // Users may customise redaction patterns — safe, only controls what is scrubbed.
      if (cfg?.redact?.enabled) {
        redactor = createRedactor(cfg.redact);
        ctx.logger.info("telemetry: redaction enabled");
      }
      if (cfg?.rotate?.enabled) ctx.logger.info("telemetry: rotation enabled");
      if (cfg?.integrity?.enabled) {
        integrity = createIntegrityChain(cfg.integrity);
        ctx.logger.info("telemetry: integrity enabled");
      }
      if (cfg?.rateLimit?.enabled) {
        rateLimiter = createRateLimiter(cfg.rateLimit);
        ctx.logger.info("telemetry: rate limiting enabled");
      }
      if (cfg?.syslog?.enabled && cfg.syslog.host) {
        syslogWriter = createSyslogWriter(cfg.syslog);
        ctx.logger.info(`telemetry: syslog -> ${cfg.syslog.host}:${cfg.syslog.port ?? 514}`);
      }

      // GCP forwarding: both endpoint and API key come from the MDM-managed file only.
      // User config values for gcpApiGateway are intentionally ignored here.
      const managed = readManagedConfig();
      if (managed) {
        gcpWriter = createGcpApiGatewayWriter({ endpoint: managed.endpoint, apiKey: managed.apiKey });
        ctx.logger.info(`telemetry: GCP API Gateway -> ${managed.endpoint}`);
      } else {
        ctx.logger.warn(
          `telemetry: GCP API Gateway config not found at ${MANAGED_CONFIG_PATH} — forwarding disabled until endpoint and key are deployed`,
        );
      }

      unsubDiag = onDiagnosticEvent((evt) => {
        if (evt.type === "model.usage") {
          writeEvent({
            type: "llm.usage",
            sessionKey: evt.sessionKey,
            provider: evt.provider,
            model: evt.model,
            inputTokens: evt.usage.input,
            outputTokens: evt.usage.output,
            cacheTokens: evt.usage.cacheRead,
            durationMs: evt.durationMs,
            costUsd: evt.costUsd,
          });
        }
      });
    },
    async stop() {
      unsubDiag?.();
      unsubDiag = null;
      await fileWriter?.flush();
      fileWriter = null;
      await syslogWriter?.close();
      syslogWriter = null;
      await gcpWriter?.close();
      gcpWriter = null;
    },
  };
}
