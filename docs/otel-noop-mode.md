# OTel Noop Mode — Running Without Telemetry Collection

Run the complete OpenTelemetry Demo with all 22 microservices fully operational, but with the
OpenTelemetry Collector replaced by a lightweight noop stub that accepts and silently discards all
telemetry. Jaeger, Grafana, and Prometheus remain accessible — they simply show no data.

---

## Table of Contents

- [What Is Noop Mode?](#what-is-noop-mode)
- [Architecture: Normal vs Noop](#architecture-normal-vs-noop)
- [Quick Start](#quick-start)
- [How It Works](#how-it-works)
- [Mode Comparison](#mode-comparison)
- [Command Reference](#command-reference)
- [Verifying Noop Mode Is Active](#verifying-noop-mode-is-active)
- [Switching Back to Full Mode](#switching-back-to-full-mode)
- [Troubleshooting](#troubleshooting)

---

## What Is Noop Mode?

Noop mode replaces the real OpenTelemetry Collector with a stub that speaks the same OTLP protocol but
drops every span, metric, and log it receives. All application services start normally and operate
without errors — they simply produce no observable telemetry output.

**When to use it:**

- **Application-only demos** — You want to demonstrate the microservices application behavior (shopping
  cart, checkout, recommendations) without the overhead of the full observability stack producing data.

- **Connectivity testing** — You need to verify that services can start and communicate with each other,
  independent of whether the telemetry pipeline is healthy.

- **Reduced resource footprint** — The observability backend (OpenSearch, Prometheus, Jaeger) still runs
  but consumes no write I/O. Useful on machines where you want the UIs available but not under load.

- **"Before OTel" demonstrations** — Show an audience what the Grafana dashboards look like with zero
  data, then switch to full mode to illustrate the value of instrumentation.

> **Note:** Noop mode does **not** remove OTel instrumentation from the application code. Services are
> still instrumented — they just export to a sink that discards everything. This is intentional: the
> behavior demonstrates that well-instrumented services work correctly with or without a live collector.

---

## Architecture: Normal vs Noop

### Normal Mode (Full OTel Pipeline)

```
┌─────────────────────────────────────────────────────────────────┐
│                        Application Services                      │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐        │
│  │ checkout │  │  frontend│  │  payment │  │  (+ 18)  │        │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬─────┘        │
│       │              │              │              │             │
│       └──────────────┴──────────────┴──────────────┘            │
│                              │ OTLP (gRPC :4317 / HTTP :4318)   │
└──────────────────────────────┼──────────────────────────────────┘
                               ▼
              ┌────────────────────────────────┐
              │     OTel Collector (otelcol)   │
              │   ┌──────────┬─────────────┐  │
              │   │ Receivers│  Exporters  │  │
              │   │  OTLP    │ → Jaeger    │  │
              │   │  HTTP    │ → Prometheus│  │
              │   │  check   │ → OpenSearch│  │
              │   └──────────┴─────────────┘  │
              └────────────────────────────────┘
                    │              │          │
                    ▼              ▼          ▼
               ┌─────────┐  ┌──────────┐  ┌────────────┐
               │  Jaeger │  │Prometheus│  │ OpenSearch │
               │ (traces)│  │(metrics) │  │  (logs)    │
               └────┬────┘  └─────┬────┘  └─────┬──────┘
                    │             │               │
                    └─────────────┴───────────────┘
                                  │
                             ┌────▼─────┐
                             │  Grafana │
                             │(dashbds) │
                             └──────────┘
```

### Noop Mode (Stub Collector)

```
┌─────────────────────────────────────────────────────────────────┐
│                        Application Services                      │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐        │
│  │ checkout │  │  frontend│  │  payment │  │  (+ 18)  │        │
│  │SDK=off * │  │SDK=off * │  │SDK=off * │  │          │        │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬─────┘        │
│       │              │              │              │             │
│       └──────────────┴──────────────┴──────────────┘            │
│                              │ OTLP (same ports — no errors)    │
└──────────────────────────────┼──────────────────────────────────┘
                               ▼
              ┌────────────────────────────────┐
              │    Noop Stub (otelcol)         │
              │   ┌──────────┬─────────────┐  │
              │   │ Receivers│  Exporters  │  │
              │   │  OTLP    │ → debug     │  │
              │   │  (same   │   (drops    │  │
              │   │  ports)  │ everything) │  │
              │   └──────────┴─────────────┘  │
              └────────────────────────────────┘
                               │
                               ▼ (no pipelines to backends)
              ┌───────────────────────────────────────┐
              │  Jaeger  │  Prometheus  │  OpenSearch  │
              │  (empty) │   (empty)   │   (empty)    │
              └──────────┴─────────────┴──────────────┘
                                    │
                               ┌────▼─────┐
                               │  Grafana │
                               │(no data) │
                               └──────────┘

* OTEL_SDK_DISABLED=true for Java, .NET, Node.js, Python, Ruby, PHP services.
  Go, C++, and Rust services connect to the noop stub and export harmlessly.
```

---

## Quick Start

```bash
# Start the demo in noop mode — one command, no flags
make start-no-otel
```

The demo will be available at **http://localhost:8080** within 1–2 minutes.

---

## How It Works

### The Noop Stub Collector

The core of noop mode is a Docker Compose override file (`docker-compose.no-otel.yml`) that changes the
`otelcol` service to use a minimal configuration (`src/otelcollector/otelcol-config-noop.yml`) instead of
the full production config.

**Noop config structure:**

```yaml
# src/otelcollector/otelcol-config-noop.yml
receivers:
  otlp:
    protocols:
      grpc:       # port 4317 — same as production
      http:       # port 4318 — same as production
        cors:
          allowed_origins: ["http://*", "https://*"]

exporters:
  debug:
    verbosity: basic   # minimal console output

service:
  pipelines:
    traces:   {receivers: [otlp], exporters: [debug]}
    metrics:  {receivers: [otlp], exporters: [debug]}
    logs:     {receivers: [otlp], exporters: [debug]}
```

The stub runs on the **same ports** as the real collector (4317 gRPC, 4318 HTTP) and speaks the **same
OTLP protocol**. Every service connects successfully — there are no connection refused errors, no
reconnection loops, no log spam.

**Why not simply remove otelcol?**

All 14 application services declare `depends_on: otelcol` in `docker-compose.yml`. Docker Compose
cannot conditionally remove a `depends_on` entry via environment variable. Removing the service entirely
would require listing all 14 services in the override file just to null out their dependencies — fragile
and hard to maintain. The noop stub satisfies all dependencies cleanly without touching a single
`depends_on` entry in the base file.

### Per-Language SDK Behavior

Different language SDKs respond differently to the `OTEL_SDK_DISABLED=true` environment variable.
The override file sets this for all SDKs that honor it, while Go/C++/Rust services rely on the noop stub:

| Service | Language | OTEL_SDK_DISABLED honored? | Noop behavior |
|---------|----------|---------------------------|---------------|
| `adservice` | Java | ✓ Yes — SDK does not initialize | SDK fully disabled |
| `cartservice` | C# / .NET | ✓ Yes — SDK does not initialize | SDK fully disabled |
| `checkoutservice` | Go | ✗ No — SDK ignores this env var | Connects to noop stub; data dropped |
| `currencyservice` | C++ | ✗ No — SDK ignores this env var | Connects to noop stub; data dropped |
| `emailservice` | Ruby | ✓ Yes — SDK does not initialize | SDK fully disabled |
| `frauddetectionservice` | Java | ✓ Yes — SDK does not initialize | SDK fully disabled |
| `frontend` | Node.js | ✓ Yes — SDK does not initialize | SDK fully disabled |
| `imageprovider` | nginx (OTel module) | ✗ No module flag | Connects to noop stub; data dropped |
| `kafka` | Java | ✓ Yes — SDK does not initialize | SDK fully disabled |
| `loadgenerator` | Python | ✓ Yes — SDK does not initialize | SDK fully disabled |
| `paymentservice` | Node.js | ✓ Yes — SDK does not initialize | SDK fully disabled |
| `productcatalogservice` | Go | ✗ No — SDK ignores this env var | Connects to noop stub; data dropped |
| `quoteservice` | PHP | ✓ Yes (partial) — autoload disabled | SDK fully disabled |
| `recommendationservice` | Python | ✓ Yes — SDK does not initialize | SDK fully disabled |
| `shippingservice` | Rust | ✗ No — SDK ignores this env var | Connects to noop stub; data dropped |
| `accountingservice` | Go | ✗ No — SDK ignores this env var | Connects to noop stub; data dropped |

> **Note:** Go services use non-blocking gRPC dial by default, so connection failures do not crash the
> service. Since the noop stub is always running, Go services connect on the first attempt and export
> data that is silently discarded.

### How the Compose Override Works

`docker-compose.no-otel.yml` is a **merge override** — it does not replace `docker-compose.yml` but
rather modifies specific fields. Docker Compose applies the override on top of the base file:

```
docker-compose.yml          docker-compose.no-otel.yml     Result
─────────────────────────   ──────────────────────────────  ──────────────────────
otelcol:                    otelcol:                        otelcol:
  command: [full config]  ←   command: [noop config]    →    command: [noop config]
  volumes: [full vols]        volumes: [noop vol]             volumes: [full + noop]
  depends_on: {jaeger}        depends_on: {}                  depends_on: {}
                          ←                              →
adservice:                  adservice:                        adservice:
  environment: [...]          environment:                    environment: [...]
                                - OTEL_SDK_DISABLED=true   →    + OTEL_SDK_DISABLED=true
```

The `command` field is **replaced** (last value wins). The `volumes` list is **merged** (appended).
The `depends_on` object is **replaced** (empty `{}` removes the Jaeger dependency from otelcol).

> **Note:** The `otelcol-config-extras.yml` volume (for Grafana Cloud) is still mounted in noop mode —
> it's harmless because the noop `command` only loads the noop config file.

### flagd Metrics Disabling

The feature flag daemon (`flagd`) exports its own metrics to the OTel Collector via:
```
FLAGD_METRICS_EXPORTER=otel
FLAGD_OTEL_COLLECTOR_URI=otelcol:4317
```

In noop mode, the override sets:
```yaml
flagd:
  environment:
    - FLAGD_METRICS_EXPORTER=   # empty string disables the otel exporter
    - FLAGD_OTEL_COLLECTOR_URI= # URI becomes irrelevant
```

Setting `FLAGD_METRICS_EXPORTER` to an empty string causes flagd to fall back to its default no-op
metrics exporter. No OTel SDK call is made, so no connection to the collector is attempted.

### Envoy Frontend Proxy

The Envoy proxy (`frontendproxy`) is configured with an OTel tracing provider pointing at
`otelcol:4317`. In noop mode, Envoy connects to the noop stub on the same address and port — it sends
trace spans that are accepted and discarded. No configuration change is needed.

### Browser Faro SDK

The Grafana Faro RUM SDK is initialized in `src/frontend/utils/telemetry/FaroTracer.ts`:

```typescript
// FaroTracer.ts:15 — only initializes when a URL is provided
if (url) {
  initializeFaro({ /* ... */ });
}
```

Since `GRAFANA_FARO_ENDPOINT` defaults to empty in `.env`, Faro does not initialize in any local mode
(noop or full). It only activates when you explicitly set a Grafana Cloud Faro endpoint.

---

## Mode Comparison

| Capability | Full Mode (`make start`) | Noop Mode (`make start-no-otel`) |
|------------|:------------------------:|:--------------------------------:|
| Application services running | ✓ | ✓ |
| Feature flags working | ✓ | ✓ |
| Shopping flow (cart, checkout) | ✓ | ✓ |
| Load generator generating traffic | ✓ | ✓ |
| Jaeger UI accessible | ✓ | ✓ (no data) |
| Grafana dashboards accessible | ✓ | ✓ (no data) |
| Prometheus metrics | ✓ | ✓ (no data) |
| Traces collected | ✓ | ✗ dropped |
| Metrics collected | ✓ | ✗ dropped |
| Logs collected | ✓ | ✗ dropped |
| OTel Collector running | ✓ full pipeline | ✓ noop stub |
| OTel Collector image | same (`otel/collector-contrib`) | same (lighter config) |
| Services crash on collector absence | — | ✗ never (stub always up) |

---

## Command Reference

| Command | Effect |
|---------|--------|
| `make start-no-otel` | Start full demo in noop mode (recommended) |
| `OTEL_ENABLED=false make start` | Same as above — env var approach |
| `make start` | Start full demo with complete OTel pipeline (default) |
| `OTEL_ENABLED=true make start` | Explicit full mode (same as `make start`) |
| `make stop` | Stop all services (works from either mode) |
| `docker compose -f docker-compose.yml -f docker-compose.no-otel.yml up -d` | Manual Compose invocation |
| `docker compose logs otelcol` | View noop stub logs (shows data is being received and dropped) |

---

## Verifying Noop Mode Is Active

After running `make start-no-otel`, confirm noop mode is working with these checks:

**1. Verify the noop config is loaded:**

```bash
docker compose logs otelcol | head -20
```

Expected output includes `"otelcol-config-noop.yml"` in the startup line — not `otelcol-config.yml`.

**2. Confirm services start without errors:**

```bash
docker compose ps
```

All services should show `running` status. None should be in `exited` or `restarting`.

**3. Confirm no OTLP connection errors in services:**

```bash
docker compose logs adservice 2>&1 | grep -i "error\|failed\|connection"
docker compose logs checkoutservice 2>&1 | grep -i "error\|failed\|connection"
```

Expected: no output (no errors). Go services may log a brief "connecting" message on startup but
resolve immediately once the noop stub accepts the connection.

**4. Confirm application works normally:**

Open **http://localhost:8080** — add items to the cart, complete a checkout. Everything should work.

**5. Confirm Jaeger shows no traces:**

Open **http://localhost:8080/jaeger/ui** — select any service from the dropdown and search. Expected:
"Sorry, no results found".

**6. Confirm Grafana shows empty dashboards:**

Open **http://localhost:8080/grafana/** — open any dashboard. Expected: all panels show "No data".

---

## Switching Back to Full Mode

```bash
# Stop noop mode
make stop

# Start with full OTel collection
make start
```

The `make stop` target always cleans up both modes (it references both compose files). After restarting
with `make start`, the full OTel pipeline becomes active immediately — Jaeger, Prometheus, and OpenSearch
will begin receiving data within seconds.

> **Tip:** You don't need to rebuild any images when switching modes. The same container images are used
> in both modes — only the OTel Collector configuration file changes.

---

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| Services in `exited` or `restarting` state | Missing Docker image — images haven't been built yet | Run `make build` first, then `make start-no-otel` |
| `docker compose logs otelcol` shows `otelcol-config.yml` (not noop) | Wrong compose command used | Ensure you're running `make start-no-otel` or `docker compose -f docker-compose.yml -f docker-compose.no-otel.yml up` |
| adservice logs show repeated connection errors | Noop stub started but adservice started before it | Wait 30 seconds; adservice retries automatically |
| Grafana shows data despite noop mode | Previous data from a full-mode run was retained in OpenSearch/Prometheus | Run `make stop` (removes volumes) then `make start-no-otel` |
| `make stop` leaves containers running | Using `docker compose down` manually without the override file | Always use `make stop`, or pass both `-f` flags manually |
| `OTEL_SDK_DISABLED=true` has no effect on a Go service | Go SDK does not read this env var | Expected behavior — Go services rely on the noop stub, not SDK disabling |
