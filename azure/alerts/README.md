# F5 Telemetry — Azure Monitor Alerts

Nine SRE-focused **scheduled query (log) alert rules** for the F5 telemetry
pipeline, deployable as one ARM template. Read the
[Azure observability overview](../README.md) first — especially the
[low-ingestion pattern](../README.md#5-the-low-ingestion-pattern-why-it-actually-fires-on-no-data)
and the [data model](../README.md#2-data-model-how-f5-fields-land-in-log-analytics).

- [`azuredeploy.json`](azuredeploy.json) — the template (9 rules).
- [`azuredeploy.parameters.example.json`](azuredeploy.parameters.example.json) —
  copy to `azuredeploy.parameters.json` and fill in.

---

## Deploy

```bash
cp azuredeploy.parameters.example.json azuredeploy.parameters.json
# edit: workspaceResourceId, location, actionGroupResourceId (optional)

az deployment group create \
  --resource-group rg-observability \
  --template-file  azuredeploy.json \
  --parameters     @azuredeploy.parameters.json
```

Validate without deploying:

```bash
az deployment group what-if \
  --resource-group rg-observability \
  --template-file  azuredeploy.json \
  --parameters     @azuredeploy.parameters.json
```

### Parameters

| Parameter | Default | Purpose |
| --------- | ------- | ------- |
| `workspaceResourceId` | — (required) | Log Analytics workspace receiving F5 telemetry. |
| `location` | resource group location | Region for the rule resources (match the workspace). |
| `actionGroupResourceId` | `""` | Action Group to notify. Blank = create rules with no notifications. |
| `namePrefix` | `F5` | Prefix for every rule's name. |
| `systemMinEvents` | `1` | Min System Poller events / 10-min window (#1). |
| `ltmMinEvents` | `1` | Min LTM events / 15-min window (#3). |
| `asmMinEvents` | `1` | Min ASM events / 60-min window (#4). |
| `ingestionLagP95Seconds` | `300` | p95 event→index lag threshold, seconds (#5). |
| `ltm5xxThresholdPct` | `5` | LTM 5xx error-rate threshold, percent (#6). |
| `ltmLatencyP95Ms` | `1000` | LTM p95 latency threshold, ms (#7). |
| `asmCriticalThreshold` | `25` | Blocked-Critical events per policy / 5-min (#8). |

---

## Alert catalog

> Severity scale: **0** Critical · **1** Error · **2** Warning · **3**
> Informational. All rules use `autoMitigate: true`, so they auto-resolve when
> the condition clears.

### 1. System Poller heartbeat lost — Sev 1 · 10m window / 5m eval
**Fires:** fewer than `systemMinEvents` System Poller snapshots in 10 minutes.
**Why it's the primary no-data alarm:** the System Poller is periodic (~60s), so
its silence is unambiguous — unlike event-driven LTM/ASM, which can legitimately
go quiet.
```kql
F5Telemetry_System_CL
| summarize Count = count()
```
*(measure `Count` `LessThan` `systemMinEvents`; the always-one-row `summarize`
makes `0` fire — see overview §5.)*

**Runbook:** proxy down or blind?
1. Health workbook → **Pipeline freshness**: is *only* System stale, or all
   tables?
2. `docker compose ps` / `docker compose logs -f` on the proxy host — is the
   container up, is the Azure output erroring on auth?
3. Confirm the BIG-IP System Poller is enabled and pointed at the proxy
   ([`ts.json.example`](../../ts.json.example)).
4. If the proxy is up but Azure is rejecting writes, check
   `AZURE_WORKSPACE_ID` / `AZURE_WORKSPACE_KEY`.

### 2. All F5 ingestion stopped — Sev 0 · 15m / 5m
**Fires:** zero events across **all** F5 tables in 15 minutes. Full data-path
outage.
```kql
union isfuzzy=true (F5Telemetry_LTM_CL),(F5Telemetry_ASM_CL),(F5Telemetry_System_CL),
                   (F5Telemetry_AFM_CL),(F5Telemetry_APM_CL),(F5Telemetry_AVR_CL),(F5Telemetry_Event_CL)
| summarize Count = count()
```
**Runbook:** treat as an outage. Proxy container, host, and network path to
Azure (`*.ods.opinsights.azure.com`). Check the proxy persistent queue isn't
full (`LS_QUEUE_MAX_BYTES`); a full queue applies backpressure and stops the
HTTP input. This and #1 should fire together — if only #2, suspect the whole
host/network rather than the F5 poller.

### 3. LTM low ingestion — Sev 2 · 15m / 5m
**Fires:** LTM events below `ltmMinEvents` in 15 minutes (2 consecutive periods).
**Runbook:** if System is still flowing (so the proxy is up), the BIG-IP
request-logging / HSL profile likely stopped, was detached from the virtual
servers, or real traffic genuinely dropped. Confirm against the LTM workbook
traffic chart and the application's own metrics.

### 4. ASM low ingestion — Sev 3 · 60m / 15m
**Fires:** ASM events below `asmMinEvents` in 60 minutes. Longer window + lower
severity because WAF events are bursty/sparse.
**Runbook:** often benign (quiet period). Confirm the ASM logging profile is
attached and the policy is in blocking/transparent mode. **In low-WAF-traffic
environments, disable this rule or widen the window** rather than tuning the
floor to 0.

### 5. Ingestion latency high — Sev 2 · 15m / 5m
**Fires:** p95 of `ingestion_time() - TimeGenerated` over `ingestionLagP95Seconds`.
Data is arriving but **stale** — the proxy's persistent queue (shock absorber)
is draining slowly.
```kql
union isfuzzy=true (F5Telemetry_LTM_CL),(F5Telemetry_ASM_CL),(F5Telemetry_System_CL)
| extend LagSeconds = (ingestion_time() - TimeGenerated) / 1s
| summarize P95LagSeconds = percentile(LagSeconds, 95)
```
**Runbook:** Health workbook → **Ingestion latency** trend. Causes: Azure
throttling (the plugin backs off), or proxy CPU/network limits. Check proxy
container CPU vs. `LS_CPU_LIMIT`, the Logstash monitoring API (`:9600`) for
queue depth, and whether the queue on disk is growing — that confirms backlog
rather than a clock issue.

### 6. LTM 5xx error rate high — Sev 1 · 15m / 5m
**Fires:** 5xx share of LTM responses over `ltm5xxThresholdPct`, with a built-in
`Total >= 50` volume guard so trickle traffic can't trip it.
```kql
F5Telemetry_LTM_CL
| summarize Total = count(), Errors = countif(response_code_d >= 500)
| where Total >= 50
| extend ErrorRatePct = round(100.0 * Errors / Total, 2)
```
**Runbook:** backend/pool failure surfaced by the BIG-IP. LTM workbook → **Top
failing URIs** and **by virtual server** to localize. Correlate with pool-member
health and app logs. Adjust the `>= 50` guard in the query for your traffic
floor.

### 7. LTM p95 latency degraded — Sev 2 · 15m / 5m
**Fires:** p95 `response_ms_d` over `ltmLatencyP95Ms` (volume-guarded).
**Runbook:** LTM workbook → **latency percentiles**; a widening p99–p50 gap
points to tail latency / saturation. Check backend pool member load and BIG-IP
CPU via the System workbook/snapshot.

### 8. ASM critical attack spike — Sev 2 · 5m / 5m · split by **ASMPolicy**
**Fires:** blocked, Critical-severity ASM events for a single policy over
`asmCriticalThreshold` in 5 minutes. `muteActionsDuration: PT30M` damps a storm.
```kql
F5Telemetry_ASM_CL
| where severity_s == 'Critical' and request_status_s == 'blocked'
| summarize Count = count() by ASMPolicy = policy_name_s
```
**Runbook:** active campaign against the named app. ASM workbook → **Top
attackers / attack types / signatures**, scoped to that policy. Decide on
blocking the source(s), tightening the policy, or escalating to security.

### 9. BIG-IP device health degraded — Sev 1 · 15m / 5m · split by **Host**
**Fires:** latest System Poller snapshot shows failover not in `ACTIVE/STANDBY`
**or** sync not in `In Sync/Standalone`.
```kql
F5Telemetry_System_CL
| summarize arg_max(TimeGenerated, f5_device_failoverStatus_s, f5_device_syncStatus_s) by Host = f5_device_hostname_s
| where f5_device_failoverStatus_s !in~ ('ACTIVE','STANDBY') or f5_device_syncStatus_s !in~ ('In Sync','Standalone')
| summarize Count = count() by Host
```
**Runbook:** catches failovers, `FORCED_OFFLINE` nodes, and `Changes
Pending`/`Disconnected` sync. Health workbook → **BIG-IP fleet** for the
device's state and last poll time. Investigate the HA pair / config-sync;
expected during planned maintenance (acknowledge to mute).

---

## Design choices & best practices

- **Reliable no-data detection.** Low-ingestion rules use a bare `summarize
  count()` (always one row, even on empty input) with `metricMeasureColumn` +
  `LessThan`, so genuine *zero* data trips the threshold. A plain "results
  count" alert would silently never fire when the table is empty. See
  [overview §5](../README.md#5-the-low-ingestion-pattern-why-it-actually-fires-on-no-data).
- **Heartbeat anchored on periodic data.** "Is the pipeline alive?" keys off
  System Poller (#1), not bursty LTM/ASM.
- **Noise control.** `failingPeriods` requires consecutive breaches on
  degradation rules (#3, #5, #6, #7); volume guards on rate/latency rules; a
  mute window on the attack-spike rule; lower severity + longer window for
  sparse ASM ingestion.
- **Per-resource splitting.** Dimensions (`ASMPolicy`, `Host`) raise one
  actionable alert *per* policy/device instead of one blurred aggregate.
- **`skipQueryValidation: true`.** Lets deployment succeed before a table (e.g.
  ASM/AFM/APM/AVR) physically exists from its first write.
- **`autoMitigate: true`.** Conditions self-resolve, so the on-call queue
  reflects current state.

## Tuning

1. Collect a few days of data; read realistic per-window floors from the
   **Throughput vs. baseline** tile in the health workbook and set
   `systemMinEvents` / `ltmMinEvents` / `asmMinEvents`.
2. Align `ltm5xxThresholdPct`, `ltmLatencyP95Ms`, `asmCriticalThreshold` to your
   SLOs/threat model.
3. Edit the `>= 50` volume guards in #6/#7 to your traffic floor.
4. Disable/relax #4 where WAF traffic is sparse.
5. After wiring the Action Group, test end-to-end: `docker compose stop` the
   proxy, confirm #1 (then #2) fire, restart, confirm auto-resolve.

## Cleanup

```bash
az resource delete --resource-group rg-observability \
  --resource-type Microsoft.Insights/scheduledQueryRules \
  --name F5-System-Heartbeat-Lost
# ...repeat per rule, or delete the resource group / use a dedicated one.
```
The template's `alertRuleNames` output lists every rule name created.
```
