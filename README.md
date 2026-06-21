# logstash-azure-proxy

A production-ready Logstash container that ingests **F5 BIG-IP Telemetry
Streaming** events over HTTP, **parses and structures** them per module, and
ships them to **Azure Log Analytics** — one custom table per F5 event type.

It ships pre-configured with:

- A purpose-built **F5 Telemetry Streaming pipeline** (HTTP input → classify →
  per-module parsing → per-table Azure output). Supports **LTM** and **ASM**
  today, with **AFM**, **APM**, and **AVR** routed and scaffolded for easy
  extension.
- The **`http` input** plugin (listening on `:8080`) matching the F5
  `Generic_HTTP` Telemetry Consumer.
- **Persistent Queues** (`queue.type: persisted`) for durable, on-disk
  buffering so events survive restarts and downstream Azure outages.
- The **`microsoft-logstash-output-azure-loganalytics`** output plugin
  pre-installed.
- An end-to-end **CI/CD pipeline** that builds the image and publishes it to the
  **GitHub Container Registry (GHCR)**.

## Image

```
ghcr.io/zollo/logstash-azure-proxy:latest
```

Built and pushed automatically by
[`.github/workflows/docker-publish.yml`](.github/workflows/docker-publish.yml)
on every push to `main` and on version tags (`vX.Y.Z`).

## How F5 telemetry flows through the proxy

```
[ F5 BIG-IP ]
  ├─ Telemetry_System  (System Poller: systemInfo snapshots)
  └─ Telemetry_Listener (LTM / ASM / AFM / APM / AVR event logs)
        │   Generic_HTTP consumer, JSON over HTTP POST
        ▼
[ Logstash http input :8080 ]
        ▼
[ 10-classify ]  -> resolve telemetryEventCategory (or infer it)
        ▼
[ 20/30/40/50 ] -> per-module parsing (types, arrays, timestamps)
        ▼
[ Persistent Queue ] (shock absorber, on disk)
        ▼
[ 90-output ] -> route each category to its own Azure custom table
        ▼
[ Azure Log Analytics ]
   F5Telemetry_LTM_CL · F5Telemetry_ASM_CL · F5Telemetry_System_CL · …
```

## Pipeline layout

The single `f5-telemetry` pipeline is assembled from ordered, modular files in
[`pipeline/`](pipeline/). Logstash concatenates them alphabetically, so the
numeric prefixes define execution order:

| File | Responsibility |
| ---- | -------------- |
| [`01-input.conf`](pipeline/01-input.conf) | HTTP input (`:8080`, JSON codec) |
| [`10-classify.conf`](pipeline/10-classify.conf) | Resolve the F5 TS category from `telemetryEventCategory`, or infer it from the event shape; add common fields (`f5_telemetry_category`, `f5_device_hostname`) |
| [`12-clean.conf`](pipeline/12-clean.conf) | Strip F5 placeholder values (`N/A` / `-` / empty) so columns are absent rather than noisy |
| [`20-ltm.conf`](pipeline/20-ltm.conf) | LTM request-log typing, `response_code_class` bucket, timestamp |
| [`30-asm.conf`](pipeline/30-asm.conf) | ASM/WAF: split multi-value fields to arrays, type coercion, timestamp |
| [`40-system.conf`](pipeline/40-system.conf) | System Poller: promote key device fields **and numeric CPU/memory metrics**, use the snapshot timestamp |
| [`50-modules-future.conf`](pipeline/50-modules-future.conf) | AFM / APM / AVR baseline parsing + clearly marked extension points |
| [`70-normalize.conf`](pipeline/70-normalize.conf) | Cross-module common schema (`f5_src_ip`, `f5_dest_ip`, …) + GeoIP enrichment of public source IPs |
| [`80-finalize.conf`](pipeline/80-finalize.conf) | Set `EventTime` (→ Azure `TimeGenerated`) |
| [`90-output.conf`](pipeline/90-output.conf) | Route each category to its own Azure custom table |

A second, small **`dlq`** pipeline ([`dlq/dlq.conf`](dlq/dlq.conf)) drains the
Dead Letter Queue — events the main pipeline cannot process — to the
`F5Telemetry_DLQ_CL` table instead of dropping them. See
[Reliability: the Dead Letter Queue](#reliability-the-dead-letter-queue).

### Event classification

Every event is tagged with a category, stored in `[@metadata][f5_category]`
(for routing) and mirrored to the queryable field `f5_telemetry_category`:

1. If F5 set `telemetryEventCategory` (the normal case), that value is used.
2. Otherwise the category is inferred from the document shape —
   `event_source: request_logging` → **LTM**, a `system` object → **systemInfo**,
   `support_id` + `policy_name` → **ASM**, `acl_policy_name`/`acl_rule_name` →
   **AFM**, `Access_Profile`/`Access_Policy_Result` → **APM**.
3. Anything still unidentified is labelled `event` and sent to the fallback
   table, so data is never dropped.

### Cross-module normalization & enrichment

After per-module parsing, [`70-normalize.conf`](pipeline/70-normalize.conf) adds
a small **common schema** so an SRE can correlate the same entity across tables
without learning each module's native field names:

- `f5_src_ip` / `f5_dest_ip` — source/dest IP, filled from LTM `client_ip`/`server_ip`,
  ASM `ip_client`/`dest_ip`, AFM `source_ip`/`dest_ip`.
- `f5_http_method`, `f5_response_code` — normalized request attributes.
- `f5_src_country` / `f5_src_city` — **GeoIP** of the source IP (public addresses
  only; RFC1918 / loopback / CGNAT ranges are skipped).

[`12-clean.conf`](pipeline/12-clean.conf) drops F5's `N/A` / `-` / empty
placeholder values so those columns are simply absent on records they don't
apply to. See [`azure/README.md`](azure/README.md#24-normalized-cross-module-columns-present-on-every-table)
for the full column reference.

### Destination tables

Because the Microsoft Azure output plugin does **not** support dynamic
(sprintf) table names, each category is routed by a conditional output to its
own statically-named, env-overridable table. Azure appends the `_CL` suffix:

| Category | Env var | Default table (Azure table) |
| -------- | ------- | --------------------------- |
| LTM        | `AZURE_TABLE_LTM`    | `F5Telemetry_LTM` (`_CL`) |
| ASM        | `AZURE_TABLE_ASM`    | `F5Telemetry_ASM` (`_CL`) |
| systemInfo | `AZURE_TABLE_SYSTEM` | `F5Telemetry_System` (`_CL`) |
| AFM        | `AZURE_TABLE_AFM`    | `F5Telemetry_AFM` (`_CL`) |
| APM        | `AZURE_TABLE_APM`    | `F5Telemetry_APM` (`_CL`) |
| AVR        | `AZURE_TABLE_AVR`    | `F5Telemetry_AVR` (`_CL`) |
| _fallback_ | `AZURE_LOG_TABLE`    | `F5Telemetry_Event` (`_CL`) |
| _dead-letter_ | `AZURE_TABLE_DLQ` | `F5Telemetry_DLQ` (`_CL`) |

### Adding a new module (e.g. fully enabling AFM)

1. Add/extend the `if [@metadata][f5_category] == "AFM"` block in
   [`50-modules-future.conf`](pipeline/50-modules-future.conf) with the field
   conversions and parsing you need.
2. The classifier and the per-table output for AFM already exist — no other
   wiring is required.

## Configuring F5 BIG-IP

POST a Telemetry Streaming declaration to
`https://<BIG-IP>/mgmt/shared/telemetry/declare`. The example in
[`ts.json.example`](ts.json.example) configures a System Poller, an Event
Listener (the source of LTM/ASM/AFM/APM/AVR logs), and the `Generic_HTTP`
consumer pointing at this proxy:

```json
{
    "class": "Telemetry",
    "My_System":   { "class": "Telemetry_System", "systemPoller": { "interval": 60 } },
    "My_Listener": { "class": "Telemetry_Listener", "port": 6514 },
    "Logstash_Buffer_Consumer": {
        "class": "Telemetry_Consumer",
        "type": "Generic_HTTP",
        "host": "10.0.x.x",
        "protocol": "http",
        "port": 8080,
        "path": "/",
        "method": "POST",
        "outputMode": "processed"
    }
}
```

> Note: LTM/ASM/AFM/APM log streams are **not** configured by Telemetry
> Streaming itself — you must point those modules' logging profiles at the
> Event Listener (typically via AS3 or TMSH). See F5's docs for per-module
> logging-profile setup.

## Running with Docker Compose

The provided [`docker-compose.yml`](docker-compose.yml) is production-ready with
dynamic CPU/memory allocation and mounted volumes for the queue and config.

1. Copy the env template and fill in your Azure workspace credentials:

   ```bash
   cp .env.example .env
   # edit .env -> set AZURE_WORKSPACE_ID and AZURE_WORKSPACE_KEY
   ```

2. Start the stack:

   ```bash
   docker compose up -d
   ```

3. Send the bundled sample F5 events (LTM, ASM, System Poller):

   ```bash
   ./scripts/send-test-events.sh
   # or a single event:
   curl -XPOST http://localhost:8080 -H 'Content-Type: application/json' \
        --data-binary @examples/events/asm-event.json
   ```

   Set `DEBUG_STDOUT=true` to watch events get classified and routed in the
   container logs (`docker compose logs -f`).

### Tunable values (`.env`)

| Variable             | Default | Purpose                                   |
| -------------------- | ------- | ----------------------------------------- |
| `LS_CPU_LIMIT`       | `2`     | CPU limit for the container               |
| `LS_MEM_LIMIT`       | `4g`    | Memory limit (also drives the JVM heap)   |
| `LS_CPU_RESERVATION` | `1`     | Reserved CPUs                             |
| `LS_MEM_RESERVATION` | `2g`    | Reserved memory                           |
| `LS_QUEUE_PATH`      | `/var/lib/logstash/queue` | Persistent queue location |
| `LS_QUEUE_MAX_BYTES` | `60gb`  | Max persistent queue size                 |
| `LS_DLQ_PATH`        | `/var/lib/logstash/dlq` | Dead Letter Queue location  |
| `LS_DLQ_MAX_BYTES`   | `1gb`   | Max Dead Letter Queue size                |
| `HTTP_INPUT_PORT`    | `8080`  | HTTP input listen port                    |
| `API_PORT`           | `9600`  | Logstash monitoring API port              |
| `AZURE_WORKSPACE_ID` | —       | **Required** — Log Analytics workspace ID |
| `AZURE_WORKSPACE_KEY`| —       | **Required** — Log Analytics primary key  |
| `AZURE_FLUSH_INTERVAL` | `5`   | Output flush interval (seconds)           |
| `AZURE_MAX_ITEMS`    | `2000`  | Max items per Azure batch                 |
| `AZURE_TABLE_LTM` / `_ASM` / `_SYSTEM` / `_AFM` / `_APM` / `_AVR` | `F5Telemetry_*` | Per-category destination tables |
| `AZURE_LOG_TABLE`    | `F5Telemetry_Event` | Fallback table for unclassified events |
| `AZURE_TABLE_DLQ`    | `F5Telemetry_DLQ`   | Table for un-processable events drained from the DLQ |
| `DEBUG_STDOUT`       | `false` | Echo every event to the container logs    |

### Volumes

- `logstash-queue` — a named Docker volume mounted at `LS_QUEUE_PATH` to persist
  the on-disk queue across container restarts/upgrades.
- `./config/logstash.yml`, `./config/pipelines.yml`, `./pipeline/` — bind-mounted
  read-only so configuration can be tuned without rebuilding the image.

## Persistent queue configuration

The queue settings default to the values below and are overridable via
environment variables (using Logstash's `${VAR:default}` substitution in
[`config/logstash.yml`](config/logstash.yml)):

| Setting           | Env var              | Default                    |
| ----------------- | -------------------- | -------------------------- |
| `path.queue`      | `LS_QUEUE_PATH`      | `/var/lib/logstash/queue`  |
| `queue.max_bytes` | `LS_QUEUE_MAX_BYTES` | `60gb`                     |
| `path.dead_letter_queue` | `LS_DLQ_PATH`        | `/var/lib/logstash/dlq` |
| `dead_letter_queue.max_bytes` | `LS_DLQ_MAX_BYTES` | `1gb`            |

## Memory

The JVM is configured to claim a **majority (75%) of the container's memory
limit** via `-XX:MaxRAMPercentage=75` (set through `LS_JAVA_OPTS`). The stock
`-Xms`/`-Xmx` lines are stripped from `jvm.options` at build time so the
percentage flags take effect. Because the JVM reads the cgroup memory limit,
the heap scales automatically with whatever memory the container is granted —
set `LS_MEM_LIMIT` in Compose and the heap follows.

## Logstash as a "Shock Absorber"

```
[ F5 BIG-IP ] --(Unregulated Bursts)--> [ Logstash HTTP Input ]
                                                |
                                    (Immediate Flush to Disk)
                                                |
                                    [ Persistent Queue (PQ) ]
                                                |
                                    (Regulated, Batched Flow)
                                                |
                                 [ Microsoft Azure Output Plugin ]
                                                |
                                  (Throttled API Calls / Retries)
                                                |
                                 [ Azure Log Analytics Workspace ]
```

When Azure reaches its ingestion limit or throttles connections, the Microsoft
output plugin tells the Logstash pipeline, "Stop sending, I am backed up."
Logstash immediately responds by stopping the output flow, but the HTTP input
continues to accept incoming bursts from the F5. Those spikes safely pool inside
the `/var/lib/logstash/queue` directory on disk. Once Azure stops throttling,
Logstash drains the disk queue at a controlled pace until it catches up.

## Reliability: the Dead Letter Queue

The persistent queue absorbs *backpressure*, but an individual event that a
plugin cannot process (a mapping or serialization failure) would otherwise be
dropped. To preserve the "never lose data" guarantee end to end, the Dead Letter
Queue is enabled (`dead_letter_queue.enable: true`) on a persisted volume, and a
small second pipeline ([`dlq/dlq.conf`](dlq/dlq.conf)) drains it to the
`F5Telemetry_DLQ_CL` table — annotated with the failure reason and offending
plugin — so dead events are **visible, queryable, and recoverable** rather than
silently aged out.

> That table should normally be **empty**; a non-zero count is itself a useful
> alert condition (see [`azure/queries/dlq-health.kql`](azure/queries/dlq-health.kql)).
> The DLQ only captures events from plugins that implement the DLQ API plus
> pipeline-level mapping errors — it is a safety net, not a catch-all.

## Observability: Azure Workbooks & Monitor alerts

Once telemetry is landing in Azure Log Analytics, the [`azure/`](azure/)
directory provides an SRE-ready observability layer on top of it:

- **Workbooks** — [`azure/workbooks/`](azure/workbooks/): an **LTM** golden-signals
  dashboard, an **ASM/WAF** security-operations dashboard, and an **Ingestion &
  Pipeline Health** dashboard.
- **Alerts** — [`azure/alerts/`](azure/alerts/): ten deployable Azure Monitor
  scheduled-query rules (one ARM template) covering **low-ingestion / no-data**,
  ingestion latency, LTM error-rate and latency, ASM critical-attack spikes, and
  BIG-IP device health and **CPU/memory saturation**.
- **KQL cookbook** — [`azure/queries/`](azure/queries/): reusable, parameterized
  queries (top talkers, error budget, attack triage, cross-table pivot by client
  IP, DLQ health, device saturation) to paste into the Logs blade or save as
  workspace functions.
- **Docs** — [`azure/README.md`](azure/README.md) explains the Log Analytics
  data model (the `_CL` / `_s` / `_d` suffixes, ASM array handling), how to
  import/deploy everything, and per-alert runbooks for the on-call team.

## Building locally

```bash
docker build -t logstash-azure-proxy:dev --build-arg LOGSTASH_VERSION=8.11.4 .
```

## Notes

- The plugin recommends disabling ECS on Logstash 8, so
  `pipeline.ecs_compatibility: disabled` is set in `logstash.yml`.
- For stronger security, prefer the Logstash keystore for
  `AZURE_WORKSPACE_KEY` instead of passing it as a plain environment variable.
- The Microsoft Azure output plugin appends the `_CL` suffix to custom log
  tables automatically; configure table names **without** the suffix.
