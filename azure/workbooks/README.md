# F5 Telemetry Workbooks

SRE dashboards for the F5 data shipped by `logstash-azure-proxy`. Read the
[Azure observability overview](../README.md) first for the data model (table
`_CL` suffix, explicitly-typed suffix-free columns, ASM `dynamic` array handling)
that every panel below relies on.

| Workbook | File |
| -------- | ---- |
| LTM — Traffic & Performance | [`f5-ltm-sre.workbook`](f5-ltm-sre.workbook) |
| ASM — Security Operations | [`f5-asm-sre.workbook`](f5-asm-sre.workbook) |
| Ingestion & Pipeline Health | [`f5-ingestion-health.workbook`](f5-ingestion-health.workbook) |

---

## Importing a workbook

### Option A — Advanced Editor (fastest, no IaC)

1. Azure Portal → **Monitor** → **Workbooks** → **+ New**.
2. Toolbar → **</> Advanced Editor**.
3. Replace the sample JSON with the full contents of the `.workbook` file →
   **Apply**.
4. **Save** (disk icon): give it a name (e.g. *F5 LTM — Traffic & Performance*),
   choose subscription / resource group / location, and — when prompted — bind
   it to your **Log Analytics workspace**.

Because the workbooks are workspace-scoped, you do **not** need to hand-edit any
resource IDs; you select the workspace at save time and the parameters/queries
resolve against it.

### Option B — Deploy as ARM (repeatable)

Wrap the `.workbook` JSON in a `Microsoft.Insights/workbooks` resource. The
`serializedData` property takes the workbook JSON as a **string**, and
`sourceId` binds it to a workspace:

```json
{
  "type": "Microsoft.Insights/workbooks",
  "apiVersion": "2022-04-01",
  "name": "[guid('f5-ltm-sre')]",
  "location": "[parameters('location')]",
  "kind": "shared",
  "properties": {
    "displayName": "F5 LTM — Traffic & Performance",
    "category": "workbook",
    "sourceId": "[parameters('workspaceResourceId')]",
    "serializedData": "<the .workbook file contents, JSON-escaped as a string>"
  }
}
```

> Tip: `az deployment group create` with the above, where `serializedData` is
> the file content. In Bicep you can use `loadTextContent('f5-ltm-sre.workbook')`
> to inline the file without manual escaping.

---

## Shared conventions

Every workbook starts with a parameters bar:

- **Time range** — standard Azure time picker. Queries use `TimeGenerated
  {TimeRange}`.
- **Host / Policy / Virtual server** — multi-select dropdowns populated from the
  data, each with an **All** (`*`) option. Queries apply them defensively, e.g.
  `where (f5_device_hostname in ({Hostname})) or ('*' in ({Hostname}))`, so
  "All" never filters anything out.

KPI tiles are built with `evaluate narrow()` to unpivot a one-row summary into
labelled tiles.

---

## LTM — Traffic & Performance (`f5-ltm-sre.workbook`)

Golden-signals view of L7 traffic through the BIG-IP. Filters: time, BIG-IP
host, virtual server.

| Panel | Visual | What it shows / how to read it |
| ----- | ------ | ------------------------------ |
| **Service health — golden signals** | Tiles | Requests, error rate %, 5xx count, p95 latency, throughput (MB) for the current selection. Your at-a-glance SLO snapshot. |
| **Request rate by response class** | Time chart | Requests/5-min split into 2xx/3xx/4xx/5xx. A rising 5xx band or a sudden traffic cliff is the first thing to spot. |
| **Response latency percentiles** | Time chart | p50/p95/p99 of `response_ms`. A widening p99–p50 gap signals tail-latency / saturation. |
| **Error rate (4xx + 5xx, %)** | Time chart | Combined client+server error rate over time — the trend behind alert #6. |
| **Top 10 virtual servers by traffic** | Bar | Where the load is; pairs with the VS filter to drill in. |
| **Top failing URIs** | Table | URIs with the most ≥400 responses, with 5xx count and p95 — points you at the broken endpoint. |
| **Top clients by request volume** | Table | Heaviest client IPs with their error %, to spot a hot or misbehaving caller. |
| **Response code distribution** | Pie | Status-code mix for the window. |

## ASM — Security Operations (`f5-asm-sre.workbook`)

WAF posture and threat activity. Filters: time, BIG-IP host, WAF policy.
Handles the serialized-array fields described in the
[overview](../README.md#23-multi-value-asm-fields-are-serialized-arrays).

| Panel | Visual | What it shows / how to read it |
| ----- | ------ | ------------------------------ |
| **WAF posture — summary** | Tiles | Total events, blocked count, block rate %, Critical count, unique attacker IPs. |
| **Enforcement over time** | Time chart | blocked / alerted / passed per 5-min. A spike in *alerted* (not blocked) can mean a policy in transparent/staging mode under attack. |
| **Events by severity** | Pie | Critical/Error/Warning mix. |
| **Top attack types** | Bar | Most frequent `attack_type` values (array-exploded). |
| **Top violations** | Bar | Most frequent `violations` (array-exploded). |
| **Top attackers** | Table | Attacker IP + geo, event count, blocked count, max violation rating, last seen. Triage worst offenders here. |
| **Activity by WAF policy** | Table | Per-policy events, blocked, Critical, unique attackers, block rate % — which app is under pressure. |
| **Top triggered attack signatures** | Table | Signature names (array-exploded) with hit count, unique attackers, last seen. |

## Ingestion & Pipeline Health (`f5-ingestion-health.workbook`)

The triage companion for the ingestion alerts. Filters: time, **Stale threshold
(min)** (drives the freshness STALE/OK flag).

| Panel | Visual | What it shows / how to read it |
| ----- | ------ | ------------------------------ |
| **Pipeline freshness** | Table | Minutes since the last event in **each** F5 table, flagged ⛔ STALE / ✅ OK against your threshold. The first place to look when alert #1/#2/#3/#4 pages. |
| **Ingestion volume by table** | Time chart | Events/5-min per table — see which category dropped vs. an across-the-board cliff. |
| **Ingestion latency** | Time chart | p50/p95 lag between event time and Azure index time (`ingestion_time() - TimeGenerated`). High + rising = proxy queue backlog / Azure throttling (the signal behind alert #5). |
| **Throughput vs. 24h baseline** | Tiles | Last-hour event count vs. the previous-24h hourly average, as an absolute and a % — quantifies a partial drop the binary alerts might miss. |
| **BIG-IP fleet** | Table | Latest System Poller per device: version, failover (color-coded), sync, last poll, minutes since. Backs alert #9. |
| **Events per BIG-IP device** | Bar | Per-device contribution across LTM/ASM/System — spot a single device that went silent. |

---

## Maintenance notes

- **Custom table names:** if you changed `table_prefix` in the Terraform module,
  update the table names in each `.workbook` before importing.
- **Device saturation:** the proxy now promotes `f5_device_cpu`,
  `f5_device_memory`, `f5_device_tmm_cpu`, and `f5_device_tmm_memory` as
  numeric columns, so you can add a CPU/memory tile or trend to the **BIG-IP
  fleet** panel without parsing JSON. Use
  [`../queries/device-saturation.kql`](../queries/device-saturation.kql) as the
  panel query; it backs alert #10.
- **Other System metrics:** virtualServers/pools/profiles live in the `dynamic`
  columns `system`, `virtualServers`, and `pools`; reference them directly (e.g.
  `system.tmmTraffic`, `virtualServers`) — no `parse_json` needed — to extend the
  health workbook. Add more `dynamic` columns in
  [`../../terraform/locals.tf`](../../terraform/locals.tf) to surface deeper keys.
- **AFM/APM/AVR:** these tables are routed today but only lightly parsed
  ([`50-modules-future.conf`](../../pipeline/50-modules-future.conf)). The
  health workbook already includes them via `union isfuzzy=true`; build
  dedicated panels as you enrich those modules.
```
