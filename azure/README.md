# F5 Telemetry — Azure Workbooks & Monitor Alerts (SRE)

This directory contains the **observability layer** for the data that
`logstash-azure-proxy` ships into Azure Log Analytics: a set of SRE-focused
**Azure Workbooks** (dashboards) and **Azure Monitor alert rules** (scheduled
query / log alerts), plus the documentation an on-call team needs to operate
them.

It assumes the proxy is already running and populating the `F5Telemetry_*_CL`
tables described in the [project README](../README.md).

```
azure/
├── README.md                       ← you are here (schema, deploy, runbooks)
├── workbooks/
│   ├── README.md                   ← per-panel description + import steps
│   ├── f5-ltm-sre.workbook         ← LTM traffic & performance (golden signals)
│   ├── f5-asm-sre.workbook         ← ASM / WAF security operations
│   └── f5-ingestion-health.workbook← pipeline freshness, volume, ingestion lag
└── alerts/
    ├── README.md                   ← alert catalog, thresholds, tuning, runbooks
    ├── azuredeploy.json            ← ARM template: 9 scheduled query rules
    └── azuredeploy.parameters.example.json
```

---

## 1. Why this exists (the SRE framing)

The proxy is a **shock absorber**: it accepts unregulated F5 bursts, buffers
them on a persistent disk queue, and drains to Azure at a controlled pace. That
design hides backpressure well — which means a quiet failure (the proxy down,
Azure throttling, a BIG-IP that stopped logging) can go unnoticed because *no
errors are thrown at the source*. The job of this layer is to make the health
of that pipeline, and the services behind it, **observable and alertable**.

We organize everything around two questions an SRE asks:

1. **Is the telemetry pipeline healthy?** — Is data still flowing, on time, at a
   normal rate? → *Ingestion & Pipeline Health workbook* + the *low-ingestion /
   latency alerts*.
2. **Are the services behind F5 healthy?** — Traffic, latency, errors (LTM) and
   security posture (ASM)? → *LTM* and *ASM* workbooks + the *error-rate,
   latency, and attack-spike alerts*.

The workbooks and alerts deliberately query the **same fields with the same
semantics**, so a dashboard panel and the alert that pages you tell a
consistent story.

---

## 2. Data model: how F5 fields land in Log Analytics

The proxy uses the `microsoft-logstash-output-azure-loganalytics` plugin, which
sends to the **Azure Monitor HTTP Data Collector API**. Two behaviors of that
API drive every query in this directory:

### 2.1 Table names get a `_CL` suffix

The proxy writes per-category tables (overridable via `AZURE_TABLE_*`). Azure
appends `_CL` ("custom log"):

| F5 category | Proxy table name      | Log Analytics table        |
| ----------- | --------------------- | -------------------------- |
| LTM         | `F5Telemetry_LTM`     | `F5Telemetry_LTM_CL`       |
| ASM         | `F5Telemetry_ASM`     | `F5Telemetry_ASM_CL`       |
| systemInfo  | `F5Telemetry_System`  | `F5Telemetry_System_CL`    |
| AFM         | `F5Telemetry_AFM`     | `F5Telemetry_AFM_CL`       |
| APM         | `F5Telemetry_APM`     | `F5Telemetry_APM_CL`       |
| AVR         | `F5Telemetry_AVR`     | `F5Telemetry_AVR_CL`       |
| _fallback_  | `F5Telemetry_Event`   | `F5Telemetry_Event_CL`     |
| _dead-letter_ | `F5Telemetry_DLQ`   | `F5Telemetry_DLQ_CL`       |

> **If you overrode `AZURE_TABLE_*`** in the proxy, find-and-replace the table
> names in the `.workbook` files and `azuredeploy.json` before importing.

### 2.2 Columns get a type suffix

The Data Collector API infers each column's type from the JSON value and
appends a suffix. This is why every field in our queries ends in `_s`, `_d`,
etc.:

| Suffix | Type     | Example column        |
| ------ | -------- | --------------------- |
| `_s`   | string   | `client_ip_s`         |
| `_d`   | double / number | `response_ms_d` |
| `_b`   | boolean  | —                     |
| `_t`   | datetime | —                     |
| `_g`   | GUID     | `f5_device_machineId_g` (if detected) |

Every record also has the standard columns `TimeGenerated` (mapped from the F5
event's own timestamp via the proxy's `EventTime` field), `Type`, and
`TenantId`.

### 2.3 Multi-value ASM fields are serialized arrays

The pipeline splits comma-delimited ASM fields (`violations`, `sub_violations`,
`attack_type`, `sig_ids`, `sig_names`, `staged_sig_ids`) into **arrays**. The
Data Collector API stores an array as a **JSON-encoded string** in a single
`_s` column, e.g.:

```text
attack_type_s = ["Detection Evasion","Path Traversal"]
```

A field with a single value (no comma) stays a plain scalar string. The ASM
workbook and the docs therefore normalize **both shapes** before exploding:

```kql
| extend _arr = todynamic(attack_type_s)
| extend _arr = iif(gettype(_arr) == 'array', _arr, pack_array(attack_type_s))
| mv-expand AttackType = _arr to typeof(string)
```

### 2.4 Normalized cross-module columns (present on every table)

To correlate the *same* entity across tables without remembering each module's
native field name, the proxy ([`70-normalize.conf`](../pipeline/70-normalize.conf))
copies a small common set onto every event. Pivot on these when joining LTM,
ASM, and AFM:

| Column | Filled from (per module) | Meaning |
| ------ | ------------------------ | ------- |
| `f5_src_ip_s` | LTM `client_ip` · ASM `ip_client` · AFM `source_ip` | Client / attacker / source IP |
| `f5_dest_ip_s` | LTM `server_ip` · ASM/AFM `dest_ip` | Pool member / destination IP |
| `f5_http_method_s` | LTM `http_method` · ASM `method` | HTTP verb |
| `f5_response_code_d` | `response_code` | HTTP status (numeric) |
| `f5_src_country_s`, `f5_src_city_s` | GeoIP of `f5_src_ip` | Source geo (public IPs only) |
| `f5_telemetry_category_s` | classifier | LTM / ASM / systemInfo / … |
| `f5_device_hostname_s` | `hostname` / `system.hostname` | Originating BIG-IP |
| `f5_collector_s` | constant | `logstash-azure-proxy` (`-dlq` for DLQ rows) |

> **GeoIP** is applied only to public source IPs (RFC1918 / loopback / CGNAT
> ranges are skipped), so internal traffic simply has no `f5_src_country_s`.
> This is richer than ASM's F5-supplied `geo_location_s` (country code only)
> and is the only geo signal available for LTM. Example "what else did this
> attacker touch" pivot:
> ```kql
> let ip = "198.51.100.23";
> union isfuzzy=true (F5Telemetry_LTM_CL), (F5Telemetry_ASM_CL), (F5Telemetry_AFM_CL)
> | where f5_src_ip_s == ip
> | project TimeGenerated, f5_telemetry_category_s, f5_dest_ip_s, f5_http_method_s, f5_response_code_d
> | order by TimeGenerated desc
> ```

### 2.5 Placeholder cleanup

F5 emits literal `"N/A"` / `"-"` / empty strings for inapplicable attributes
(e.g. `username`, `x_forwarded_for_header_value`). The proxy
([`12-clean.conf`](../pipeline/12-clean.conf)) drops these top-level fields, so
those columns are simply **absent** on records they don't apply to — filter with
`isnotempty(username_s)` rather than `username_s != "N/A"`.

### 2.6 Field reference (the columns the dashboards/alerts rely on)

**`F5Telemetry_LTM_CL`** (parsed in [`20-ltm.conf`](../pipeline/20-ltm.conf))

| Column | Meaning |
| ------ | ------- |
| `f5_device_hostname_s` | BIG-IP hostname |
| `virtual_name_s` | Virtual server |
| `client_ip_s`, `client_port_d` | Client source |
| `server_ip_s`, `server_port_d` | Selected pool member |
| `http_method_s`, `http_uri_s`, `protocol_s` | Request |
| `response_code_d` | HTTP status (numeric) |
| `response_code_class_s` | Status bucket (`2xx`/`3xx`/`4xx`/`5xx`), derived once in the pipeline |
| `response_ms_d` | Server-side response time (ms) |
| `response_size_d`, `request_size_d` | Bytes |

**`F5Telemetry_ASM_CL`** (parsed in [`30-asm.conf`](../pipeline/30-asm.conf))

| Column | Meaning |
| ------ | ------- |
| `f5_device_hostname_s` | BIG-IP hostname |
| `policy_name_s`, `web_application_name_s` | WAF policy |
| `request_status_s` | `blocked` / `alerted` / `passed` |
| `severity_s` | `Critical` / `Error` / `Warning` / … |
| `violation_rating_d` | 1–5 (5 = most likely a real attack) |
| `attack_type_s`, `violations_s`, `sub_violations_s` | Arrays (see 2.3) |
| `sig_ids_s`, `sig_names_s` | Triggered signatures (arrays) |
| `ip_client_s`, `geo_location_s` | Attacker source + country |
| `src_port_d`, `dest_ip_s`, `dest_port_d` | Connection |
| `method_s`, `response_code_d`, `support_id_s` | Request + correlation id |

**`F5Telemetry_System_CL`** (parsed in [`40-system.conf`](../pipeline/40-system.conf))

| Column | Meaning |
| ------ | ------- |
| `f5_device_hostname_s` | BIG-IP hostname |
| `f5_device_version_s` | TMOS version |
| `f5_device_failoverStatus_s` | `ACTIVE` / `STANDBY` / `FORCED_OFFLINE` / … |
| `f5_device_syncStatus_s` | `In Sync` / `Standalone` / `Changes Pending` / … |
| `f5_device_cpu_d` | System CPU utilization (%) |
| `f5_device_memory_d` | System memory utilization (%) |
| `f5_device_tmm_cpu_d` | TMM (data-plane) CPU utilization (%) |
| `f5_device_tmm_memory_d` | TMM memory utilization (%) |

> The four `*_d` saturation metrics are promoted to **numeric** columns
> ([`40-system.conf`](../pipeline/40-system.conf)) so you can chart and alert on
> device load directly (alert #10) — no `parse_json` required. The rest of the
> nested snapshot (virtualServers, pools, profiles) is still preserved as
> JSON-string columns (e.g. `system_s`); parse with `parse_json(system_s)` for
> those deeper metrics.

**`F5Telemetry_DLQ_CL`** (drained by [`dlq/dlq.conf`](../dlq/dlq.conf))

| Column | Meaning |
| ------ | ------- |
| `f5_dlq_reason_s` | Why the event could not be processed |
| `f5_dlq_plugin_id_s` | The plugin that rejected it |
| `f5_dlq_entry_time_s` | When it entered the Dead Letter Queue |

> Events the main pipeline cannot process land here instead of being dropped.
> **This table should normally be empty** — a non-zero count is itself an alert
> condition (see the KQL cookbook). Inspect `f5_dlq_reason_s` to diagnose, fix
> the pipeline, and the original payload is preserved for replay.

---

## 3. Workbooks

Three workbooks, each scoped by a time-range picker and host/policy filters.
Full panel-by-panel descriptions are in
[`workbooks/README.md`](workbooks/README.md).

| Workbook | File | Audience / use |
| -------- | ---- | -------------- |
| **LTM — Traffic & Performance** | [`f5-ltm-sre.workbook`](workbooks/f5-ltm-sre.workbook) | Golden signals (traffic, latency, errors, throughput) for app/L7 traffic through the BIG-IP. |
| **ASM — Security Operations** | [`f5-asm-sre.workbook`](workbooks/f5-asm-sre.workbook) | WAF posture: blocked vs. alerted, top attack types / violations / signatures, top attackers, per-policy activity. |
| **Ingestion & Pipeline Health** | [`f5-ingestion-health.workbook`](workbooks/f5-ingestion-health.workbook) | Pipeline freshness, volume vs. baseline, ingestion lag, BIG-IP fleet state. The triage companion for ingestion alerts. |

### Import (Advanced Editor — fastest)

1. Azure Portal → **Monitor** → **Workbooks** → **+ New**.
2. Click **</> Advanced Editor** (the `</>` toolbar icon).
3. Paste the entire contents of a `.workbook` file, **Apply**.
4. **Save** → name it, pick the **subscription / resource group / location**,
   and set the workbook's resource to your **Log Analytics workspace**.

The workbooks are workspace-scoped (`resourceType:
microsoft.operationalinsights/workspaces`); on first save Azure prompts you to
bind them to a workspace. See [`workbooks/README.md`](workbooks/README.md) for
the ARM-deployment option.

---

## 4. Alerts

Ten scheduled-query (log) alert rules, deployable as one ARM template. Full
catalog, thresholds, and per-alert runbooks are in
[`alerts/README.md`](alerts/README.md).

| # | Rule | Sev | Window | Fires when |
| - | ---- | --- | ------ | ---------- |
| 1 | System Poller heartbeat lost | 1 | 10m | No periodic System Poller data — primary "proxy/F5 down" signal |
| 2 | All F5 ingestion stopped | 0 | 15m | No events of any category — full outage |
| 3 | LTM low ingestion | 2 | 15m | LTM volume below floor |
| 4 | ASM low ingestion | 3 | 60m | ASM volume below floor (sparse-tolerant) |
| 5 | Ingestion latency high | 2 | 15m | p95 event→index lag too high (queue backlog / throttling) |
| 6 | LTM 5xx error rate high | 1 | 15m | 5xx share over threshold (volume-guarded) |
| 7 | LTM p95 latency degraded | 2 | 15m | p95 `response_ms` over threshold |
| 8 | ASM critical attack spike | 2 | 5m | Blocked Critical events per policy over threshold |
| 9 | BIG-IP device health degraded | 1 | 15m | Failover/sync state abnormal (per device) |
| 10 | BIG-IP device CPU/memory saturated | 2 | 15m | Latest snapshot CPU/mem over threshold (per device) |

### Deploy

```bash
# 1. Copy the example params and fill in your workspace + action group IDs
cp azure/alerts/azuredeploy.parameters.example.json azure/alerts/azuredeploy.parameters.json
#    edit workspaceResourceId, location, actionGroupResourceId

# 2. Deploy into the resource group that holds (or will hold) the rules
az deployment group create \
  --resource-group rg-observability \
  --template-file  azure/alerts/azuredeploy.json \
  --parameters     @azure/alerts/azuredeploy.parameters.json
```

`actionGroupResourceId` is optional — leave it blank to create the rules
without notifications and wire an [Action
Group](https://learn.microsoft.com/azure/azure-monitor/alerts/action-groups)
later. Create the action group first if you want paging on day one.

---

## 5. The "low ingestion" pattern (why it actually fires on *no* data)

A naive `count() | where count == 0` alert never fires on missing data, because
a log-alert query over an empty result set normally returns **no rows**, which
Azure treats as *healthy*. We avoid that trap:

```kql
union isfuzzy=true (F5Telemetry_System_CL)
| summarize Count = count()
```

`summarize` **without a `by` clause always returns exactly one row** — even
when the input is empty, you get a single row with `Count = 0`. The alert rule
then uses that row's `Count` as its metric measure (`metricMeasureColumn:
"Count"`, `operator: LessThan`), so *zero ingestion produces a concrete `0` that
trips the threshold*. This is the key to a reliable no-data alarm.

The single table is wrapped in `union isfuzzy=true (...)` so the rule still
evaluates to `Count = 0` (rather than entering an error state) **before the
`_CL` table has been physically created** by its first write — `isfuzzy`
tolerates a not-yet-existing table. The same pattern is used for every no-data
rule.

Two more best practices baked into the rules:

- **Anchor "is the pipeline alive?" on the periodic signal.** System Poller
  fires ~every 60s, so its absence is unambiguous. Event-driven LTM/ASM volume
  legitimately ebbs, so their low-ingestion rules use wider windows / lower
  severity and a tunable floor.
- **`skipQueryValidation: true`** so deployment succeeds even before a given
  table (e.g. ASM) has received its first record and physically exists.

---

## 6. Operating model (severities → response)

| Severity | Meaning | Expected response |
| -------- | ------- | ----------------- |
| **Sev 0** | Full telemetry outage (#2) | Page immediately; the proxy or its Azure path is down. |
| **Sev 1** | Pipeline heartbeat lost / 5xx storm / device failover (#1, #6, #9) | Page; user impact or blind spot likely. |
| **Sev 2** | Degradation — latency, ingestion lag, LTM low-ingestion, attack spike, device saturation (#3, #5, #7, #8, #10) | Investigate within the hour. |
| **Sev 3** | Informational — ASM low-ingestion (#4) | Review during business hours; often expected. |

When an ingestion alert pages, the triage order is: open the **Ingestion &
Pipeline Health** workbook → check **freshness** (data stopped?) vs. **ingestion
lag** (data late?) → follow the matching runbook in
[`alerts/README.md`](alerts/README.md).

---

## 7. Reusable KQL ([`queries/`](queries/))

The dashboards embed their queries, but the same logic is useful from the Logs
blade, custom alerts, and ad-hoc investigation. [`queries/`](queries/) collects
the high-value SRE queries as standalone, parameterized `.kql` files (top
talkers, LTM error budget, attack triage, cross-table pivot by client IP, DLQ
health, device saturation). See [`queries/README.md`](queries/README.md) for the
catalog and how to save them as workspace functions.

---

## 8. Cost & retention (per-table tiering)

Log Analytics bills on ingestion volume and retention, and the F5 tables have
very different value/volume profiles — so tier them per table rather than
accepting the workspace default:

| Table | Volume | Suggested plan | Rationale |
| ----- | ------ | -------------- | --------- |
| `F5Telemetry_LTM_CL` | **High** (per-request) | **Basic / Auxiliary Logs** + short interactive retention, archive the rest | High-cardinality request logs; mostly queried recently or in bulk for forensics. |
| `F5Telemetry_ASM_CL` | Medium, bursty | **Analytics** (full) | Security data — needs full KQL, joins, and longer interactive retention. |
| `F5Telemetry_System_CL` | Low (~1/min/device) | **Analytics** (full) | Cheap, and the heartbeat/health/saturation signal everything else triages against. |
| `F5Telemetry_DLQ_CL` | ~0 (should be empty) | **Analytics** (full) | Tiny; you want it instantly queryable when it's non-empty. |

Practical levers:

- Set **per-table retention** (`az monitor log-analytics workspace table update
  --retention-time / --total-retention-time`) instead of one workspace-wide
  value; archive beyond the interactive window.
- Consider the **Basic/Auxiliary Logs** plan for `F5Telemetry_LTM_CL` if you
  rarely run interactive analytics over old request logs — it markedly cuts
  ingestion cost (with query-time and feature trade-offs; alerts #6/#7 run over
  recent data and are unaffected).
- Trim noise **before** ingestion (cheapest GB is the one you don't send): drop
  fields you never query in the pipeline. Placeholder cleanup (§2.5) already
  removes empty/`N/A` columns.

> **Note on Basic/Auxiliary tiers:** these are a property of **DCR-based** tables
> (Logs Ingestion API). Tables created by the legacy HTTP Data Collector API
> (how this proxy writes today) are classic custom-log tables and may not expose
> every tier option — another reason to plan the migration in §9.

---

## 9. Roadmap: migrate off the HTTP Data Collector API → DCR

The `microsoft-logstash-output-azure-loganalytics` plugin writes through the
**Azure Monitor HTTP Data Collector API** (workspace ID + shared key). Microsoft
has placed that API on a **deprecation / retirement path** in favor of the
**Logs Ingestion API with Data Collection Rules (DCR)**. Beyond lifecycle
hygiene, DCRs materially improve the *consumer* experience:

- **Explicit, typed schemas** — you define columns and types in the DCR, so the
  `_s` / `_d` suffix guessing and the array-as-JSON-string handling (§2.3)
  largely go away; `attack_type` can be a real `dynamic` array column.
- **Ingestion-time transforms** (KQL) — drop/rename/redact at ingest, server
  side, complementing the pipeline.
- **Entra ID auth** instead of a shared workspace key (addresses the project
  README's "prefer the keystore" security note).
- **Per-table tiering** (§8) is a first-class DCR feature.

**Migration sketch (no action required today):** create a DCR + Data Collection
Endpoint with a stream/transform per F5 table, then point the output at it — via
a community Logs-Ingestion Logstash output, an HTTP output to the DCE
`/dataCollectionRules/.../streams/...:ingest` endpoint, or by fronting with the
Azure Monitor Agent. The pipeline (input → classify → parse → normalize) is
unchanged; **only `90-output.conf` is rewritten**, and the workbooks/alerts only
need column-name tweaks where suffixes change. Track this before the Data
Collector API's retirement date for your cloud.

---

## 10. Observe the proxy itself (before Azure sees a problem)

The alerts here detect trouble *after* it shows up in Log Analytics. The
earliest signal of the shock-absorber filling up lives on the proxy's own
Logstash monitoring API (`:9600`, `API_PORT`):

```bash
curl -s http://<proxy>:9600/_node/stats/pipelines/f5-telemetry \
  | jq '{events: .pipelines["f5-telemetry"].events,
         queue: .pipelines["f5-telemetry"].queue}'
```

Key fields: `events.in` vs `events.out` (drain keeping up?), `queue.events` /
`queue.queue_size_in_bytes` vs `LS_QUEUE_MAX_BYTES` (backlog growing toward the
cap → imminent backpressure), and JVM/process stats under `/_node/stats/jvm`.
Scrape this into Azure Monitor (Telegraf/AMA) or Prometheus so a **growing
persistent queue** pages you *before* the downstream ingestion-lag alert (#5)
fires. Also watch the container `HEALTHCHECK` and `F5Telemetry_DLQ_CL` being
non-empty.

---

## 11. Tuning checklist (first week of operation)

1. Let the tables fill for a few days, then set realistic floors:
   `ltmMinEvents` / `asmMinEvents` / `systemMinEvents` from your observed
   per-window minimums (the baseline tile in the health workbook helps).
2. Adjust `ltm5xxThresholdPct`, `ltmLatencyP95Ms`, `asmCriticalThreshold`, and
   the `deviceCpuThresholdPct` / `deviceMemThresholdPct` saturation thresholds
   to your SLOs and platform headroom.
3. If WAF traffic is genuinely sparse, **disable** rule #4 or widen its window.
4. Wire the Action Group, then test with a controlled stop of the proxy
   (`docker compose stop`) and confirm #1/#2 fire and auto-resolve on restart.
5. Set per-table retention/tiers (§8) once you've observed real volumes.
```
