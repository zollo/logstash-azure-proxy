# F5 Telemetry — KQL cookbook

Reusable, standalone KQL for the data `logstash-azure-proxy` ships into Azure
Log Analytics. The workbooks embed their own queries; these files are the same
high-value logic in a form you can paste into the **Logs** blade, attach to a
custom alert, or save as a **workspace function** for everyone to reuse.

Read the [data model](../README.md#2-data-model-how-f5-fields-land-in-log-analytics)
first — column suffixes (`_s` / `_d`), the normalized `f5_*` columns, and the
ASM array handling all matter here.

## Catalog

| File | Table(s) | What it answers |
| ---- | -------- | --------------- |
| [`ingestion-freshness.kql`](ingestion-freshness.kql) | all | Last event time + event→index lag per table. Is data flowing and on time? |
| [`top-talkers.kql`](top-talkers.kql) | LTM | Busiest client IPs, virtual servers, and URIs. |
| [`ltm-error-budget.kql`](ltm-error-budget.kql) | LTM | Success rate vs. an SLO target over time (uses `response_code_class_s`). |
| [`ltm-latency-percentiles.kql`](ltm-latency-percentiles.kql) | LTM | p50/p95/p99 `response_ms` trend, by virtual server. |
| [`asm-attack-triage.kql`](asm-attack-triage.kql) | ASM | Top attackers / attack types / signatures, with array fields exploded. |
| [`pivot-by-client-ip.kql`](pivot-by-client-ip.kql) | LTM+ASM+AFM | Everything one source IP did, across modules (uses `f5_src_ip_s`). |
| [`device-saturation.kql`](device-saturation.kql) | System | Latest CPU/memory per BIG-IP (drives alert #10). |
| [`dlq-health.kql`](dlq-health.kql) | DLQ | Are events failing to process? Reasons + offending plugin. |

## Save one as a workspace function

```bash
# Portal: Logs → run the query → Save → Save as function → give it an alias
#   (e.g. F5_TopTalkers), then call it like any table:  F5_TopTalkers | take 10

# CLI (saved search / function):
az monitor log-analytics workspace saved-search create \
  --resource-group rg-observability \
  --workspace-name law-f5-telemetry \
  --name F5TopTalkers --category F5 --display-name "F5 Top Talkers" \
  --saved-query "$(cat top-talkers.kql)" --function-alias F5_TopTalkers
```

## Conventions

- Each file sets its own time range with `let lookback = ...;` at the top —
  adjust or delete when pasting into a workbook that supplies the range.
- Queries assume the default `F5Telemetry_*_CL` table names. If you overrode
  `AZURE_TABLE_*`, find-and-replace the table names.
- `union isfuzzy=true (...)` is used wherever a table might not exist yet, so a
  query never errors just because (say) AFM hasn't received its first record.
