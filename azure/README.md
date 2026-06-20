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

### 2.4 Field reference (the columns the dashboards/alerts rely on)

**`F5Telemetry_LTM_CL`** (parsed in [`20-ltm.conf`](../pipeline/20-ltm.conf))

| Column | Meaning |
| ------ | ------- |
| `f5_device_hostname_s` | BIG-IP hostname |
| `virtual_name_s` | Virtual server |
| `client_ip_s`, `client_port_d` | Client source |
| `server_ip_s`, `server_port_d` | Selected pool member |
| `http_method_s`, `http_uri_s`, `protocol_s` | Request |
| `response_code_d` | HTTP status (numeric) |
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

> The full nested System Poller snapshot (cpu, memory, virtualServers, pools)
> is preserved but lands as JSON-string columns (e.g. `system_s`). Parse with
> `parse_json(system_s)` if you need those deeper metrics. The four promoted
> flat columns above are the reliable, top-level ones.

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

Nine scheduled-query (log) alert rules, deployable as one ARM template. Full
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
F5Telemetry_System_CL
| summarize Count = count()
```

`summarize` **without a `by` clause always returns exactly one row** — even
when the input is empty, you get a single row with `Count = 0`. The alert rule
then uses that row's `Count` as its metric measure (`metricMeasureColumn:
"Count"`, `operator: LessThan`), so *zero ingestion produces a concrete `0` that
trips the threshold*. This is the key to a reliable no-data alarm.

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
| **Sev 2** | Degradation — latency, ingestion lag, LTM low-ingestion, attack spike (#3, #5, #7, #8) | Investigate within the hour. |
| **Sev 3** | Informational — ASM low-ingestion (#4) | Review during business hours; often expected. |

When an ingestion alert pages, the triage order is: open the **Ingestion &
Pipeline Health** workbook → check **freshness** (data stopped?) vs. **ingestion
lag** (data late?) → follow the matching runbook in
[`alerts/README.md`](alerts/README.md).

---

## 7. Tuning checklist (first week of operation)

1. Let the tables fill for a few days, then set realistic floors:
   `ltmMinEvents` / `asmMinEvents` / `systemMinEvents` from your observed
   per-window minimums (the baseline tile in the health workbook helps).
2. Adjust `ltm5xxThresholdPct`, `ltmLatencyP95Ms`, and `asmCriticalThreshold`
   to your SLOs.
3. If WAF traffic is genuinely sparse, **disable** rule #4 or widen its window.
4. Wire the Action Group, then test with a controlled stop of the proxy
   (`docker compose stop`) and confirm #1/#2 fire and auto-resolve on restart.
```
