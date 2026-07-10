# Terraform — Azure resources for the Microsoft Sentinel Logstash output

This module provisions **everything the container needs** to ship F5 telemetry
to Azure Monitor Logs through the
[`microsoft-sentinel-log-analytics-logstash-output-plugin`](https://github.com/Azure/Azure-Sentinel/tree/master/DataConnectors/microsoft-sentinel-log-analytics-logstash-output-plugin)
(the **Logs Ingestion API** with **Data Collection Rules**).

Its outputs map 1:1 onto the five required container environment variables, so a
single `terraform apply` gives you a working ingestion path end to end.

## What it creates

```
                    ┌──────────────────────────────────────────────┐
                    │            Resource group (optional)          │
                    │                                               │
   Logstash  ──POST──▶  Data Collection Endpoint (DCE)              │
  (SP auth) │         │        │ logs-ingestion URI                 │
            │         │        ▼                                    │
            │         │   Data Collection Rule (DCR)  ──▶ Log Analytics
            │         │   • one stream per category        workspace │
            │         │   • identity transform (source)   ┌────────┐ │
            │         │        │                          │ _CL     │ │
            │         │        └──────────────────────────▶ tables  │ │
            │         │                                    └────────┘ │
            │         │   Entra ID app + SP + secret                 │
            └─────────┤   └─ "Monitoring Metrics Publisher" on DCR   │
                      └──────────────────────────────────────────────┘
```

| Resource | Purpose |
| -------- | ------- |
| `azurerm_resource_group` *(optional)* | Container for everything (`create_resource_group`). |
| `azurerm_log_analytics_workspace` *(optional)* | Destination workspace (`create_workspace`, or bring your own). |
| `azapi_resource.table` (×8) | Explicitly-schema'd `F5Telemetry_*_CL` custom tables — one per F5 category + DLQ. |
| `azurerm_monitor_data_collection_endpoint` | The logs-ingestion endpoint the plugin POSTs to. |
| `azurerm_monitor_data_collection_rule` | One stream + data-flow per table, identity (`source`) transform. |
| `azuread_application` / `_service_principal` / `_application_password` *(optional)* | The identity the plugin authenticates as. |
| `azurerm_role_assignment` | Grants that identity **Monitoring Metrics Publisher** on the DCR. |

## Why these resources (how the new plugin differs)

The legacy `microsoft-logstash-output-azure-loganalytics` plugin used the
**HTTP Data Collector API**: a workspace id + shared key, and Azure *inferred*
each column's type and appended a `_s`/`_d` suffix. That API is on a retirement
path. The Sentinel plugin uses the **Logs Ingestion API**, which is why the
resource set looks different:

- **DCE + DCR** replace the workspace-key endpoint. The DCR holds an *explicit,
  typed schema* per table (no more suffix guessing) and can transform at ingest.
- **Custom tables must be pre-created with a schema** — the API will not
  auto-create columns. This module defines each table's columns to match the
  fields the pipeline emits (`locals.tf`). **Fields not declared are dropped at
  ingestion**, so extend the schema when you extend the pipeline.
- **Entra ID service principal** replaces the shared key; it needs
  *Monitoring Metrics Publisher* on the DCR to push data.

## Usage

```hcl
module "f5_sentinel" {
  source = "github.com/zollo/logstash-azure-proxy//terraform"

  name_prefix         = "f5tel"
  location            = "eastus2"
  resource_group_name = "rg-f5tel"

  # Optional: tier the high-volume LTM request log down to Basic logs.
  table_plan = { LTM = "Basic" }

  tags = { project = "logstash-azure-proxy" }
}
```

A ready-to-run version is in [`examples/complete`](examples/complete).

```bash
cd terraform/examples/complete
export ARM_SUBSCRIPTION_ID=<your-sub>    # or `az login` context
terraform init
terraform apply -var 'location=eastus2' -var 'resource_group_name=rg-f5tel'
```

### Wire the outputs into the container

```bash
terraform output container_env          # AZURE_TENANT_ID / CLIENT_ID / DCE_URI / DCR_IMMUTABLE_ID
terraform output -raw client_secret     # AZURE_CLIENT_SECRET (sensitive)
```

Drop those into the container's `.env` (see the repo root `.env.example`). The
`AZURE_STREAM_*` variables already default to the stream names this module
creates, so you only need to set them if you changed `table_prefix`.

> **Secret handling.** `client_secret` is a Terraform output and therefore lands
> in state — keep state in a secured remote backend. For production prefer a
> **user-assigned managed identity** (set `create_app_registration = false` and
> pass `existing_principal_object_id`) or load the secret into the **Logstash
> keystore** rather than a plaintext `.env`.

## Bring-your-own (BYO) options

| Want to reuse… | Set | And provide |
| -------------- | --- | ----------- |
| An existing resource group | `create_resource_group = false` | `resource_group_name` (must exist) |
| An existing workspace | `create_workspace = false` | `existing_workspace_id` |
| An existing identity (e.g. UAMI) | `create_app_registration = false` | `existing_principal_object_id` |

## Inputs

| Name | Type | Default | Description |
| ---- | ---- | ------- | ----------- |
| `name_prefix` | string | `f5tel` | Prefix for resource names. |
| `location` | string | — | Azure region (**required**). |
| `resource_group_name` | string | — | Resource group to deploy into (**required**). |
| `create_resource_group` | bool | `true` | Create the RG or use existing. |
| `create_workspace` | bool | `true` | Create a workspace or attach to `existing_workspace_id`. |
| `existing_workspace_id` | string | `null` | Workspace resource ID when `create_workspace = false`. |
| `workspace_sku` | string | `PerGB2018` | SKU for a new workspace. |
| `workspace_retention_in_days` | number | `30` | Default retention for a new workspace. |
| `table_prefix` | string | `F5Telemetry` | Base name → `<prefix>_<Category>_CL`. |
| `table_plan` | map(string) | `{}` | Per-category plan (`Analytics`/`Basic`). |
| `table_retention_in_days` | map(number) | `{}` | Per-category interactive retention. |
| `table_total_retention_in_days` | map(number) | `{}` | Per-category total (archive) retention. |
| `create_app_registration` | bool | `true` | Create the Entra ID app/SP/secret. |
| `app_display_name` | string | `null` | App display name (defaults to `<name_prefix>-logstash-ingest`). |
| `client_secret_expiration_hours` | number | `8760` | Client-secret lifetime. |
| `existing_principal_object_id` | string | `null` | SP/MI object id when BYO identity. |
| `tags` | map(string) | `{}` | Tags on all resources. |

## Outputs

| Name | Sensitive | Maps to container var |
| ---- | --------- | --------------------- |
| `tenant_id` | no | `AZURE_TENANT_ID` |
| `client_id` | no | `AZURE_CLIENT_ID` |
| `client_secret` | **yes** | `AZURE_CLIENT_SECRET` |
| `data_collection_endpoint_uri` | no | `AZURE_DCE_URI` |
| `dcr_immutable_id` | no | `AZURE_DCR_IMMUTABLE_ID` |
| `stream_names` | no | `AZURE_STREAM_*` (only if `table_prefix` changed) |
| `table_names` | no | — (informational) |
| `workspace_id` | no | — (informational) |
| `container_env` | no | paste-ready `.env` fragment (secret excluded) |

## Table schemas

Column definitions live in [`locals.tf`](locals.tf) and mirror the pipeline:

- **Every** table gets `TimeGenerated` + the normalized cross-module columns
  (`f5_telemetry_category`, `f5_device_hostname`, `f5_src_ip`, `f5_dest_ip`,
  `f5_http_method`, `f5_response_code`, `f5_src_country`, `f5_src_city`,
  `f5_collector`).
- Per-category columns add the module-native fields (LTM request attributes,
  ASM violation arrays as `dynamic`, System saturation metrics + nested `system`
  snapshot as `dynamic`, …).
- The **DLQ** table has its own shape (`f5_dlq_*`).

Adding a field to a module in the pipeline? Add it to the matching list in
`locals.tf` and `terraform apply` — the DCR stream and the table are updated
together. Column names are **clean** (no `_s`/`_d` suffixes); the `azure/`
workbooks, alerts and KQL query these names directly.

## Notes & caveats

- **`terraform validate` requires provider downloads** from the public registry.
- Custom-table + DCR changes propagate in seconds but occasionally take a minute
  before the first records are queryable in a brand-new table.
- Per-table **Basic/Auxiliary** plans are a first-class feature of DCR-based
  tables — use `table_plan` to cut cost on the high-volume LTM table (see
  [`../azure/README.md`](../azure/README.md) section 8).
- Deleting a table in Terraform deletes it in Azure (and its data). Review plans
  carefully.
