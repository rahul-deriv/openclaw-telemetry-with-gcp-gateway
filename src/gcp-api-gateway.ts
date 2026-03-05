import type { GcpApiGatewayConfig, TelemetryEvent } from "./types.js";

type SignedEvent = TelemetryEvent & { prevHash?: string; hash?: string };

export type GcpApiGatewayWriter = {
  write: (evt: SignedEvent) => void;
  flush: () => Promise<void>;
  close: () => Promise<void>;
};

export function createGcpApiGatewayWriter(
  config: GcpApiGatewayConfig,
): GcpApiGatewayWriter {
  let eventBuffer: SignedEvent[] = [];
  let flushTimer: ReturnType<typeof setTimeout> | null = null;
  let flushing = false;

  const batchSize = config.batchSize ?? 100;
  const flushIntervalMs = config.flushIntervalMs ?? 5000;
  const maxRetries = config.maxRetries ?? 3;
  const retryDelayMs = config.retryDelayMs ?? 1000;
  const timeoutMs = config.timeoutMs ?? 10000;

  const sendBatch = async (events: SignedEvent[]): Promise<void> => {
    if (events.length === 0) return;

    const headers: Record<string, string> = {
      "Content-Type": "application/json",
      "x-api-key": config.apiKey,
    };

    // Send array directly, matching Python ngaisoc_logger pattern
    let attempts = 0;
    while (attempts <= maxRetries) {
      try {
        const controller = new AbortController();
        const timeoutId = setTimeout(() => controller.abort(), timeoutMs);

        const response = await fetch(config.endpoint, {
          method: "POST",
          headers,
          body: JSON.stringify(events),
          signal: controller.signal,
        });

        clearTimeout(timeoutId);

        if (!response.ok) {
          const errorText = await response.text().catch(() => "unknown error");
          throw new Error(
            `GCP API Gateway returned ${response.status}: ${errorText}`,
          );
        }
        return;
      } catch (error) {
        attempts++;
        if (attempts > maxRetries) {
          console.error(
            `[telemetry-gcp] Failed to send ${events.length} events after ${maxRetries} attempts:`,
            error,
          );
          return;
        }
        await new Promise((resolve) =>
          setTimeout(resolve, retryDelayMs * attempts),
        );
      }
    }
  };

  const doFlush = async () => {
    if (flushing || eventBuffer.length === 0) return;
    flushing = true;
    const batch = [...eventBuffer];
    eventBuffer = [];
    try {
      await sendBatch(batch);
    } finally {
      flushing = false;
    }
    if (eventBuffer.length > 0) {
      scheduleFlush();
    }
  };

  const scheduleFlush = () => {
    if (flushTimer) clearTimeout(flushTimer);
    flushTimer = setTimeout(() => void doFlush(), flushIntervalMs);
  };

  return {
    write(evt: SignedEvent) {
      eventBuffer.push(evt);
      if (eventBuffer.length >= batchSize) {
        void doFlush();
      } else {
        scheduleFlush();
      }
    },
    async flush() {
      while (eventBuffer.length > 0 || flushing) {
        await doFlush();
        if (flushing) {
          await new Promise((r) => setTimeout(r, 10));
        }
      }
    },
    async close() {
      if (flushTimer) {
        clearTimeout(flushTimer);
        flushTimer = null;
      }
      await this.flush();
    },
  };
}
