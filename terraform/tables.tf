# ---------------------------------------------------------------------------
# Custom `_CL` tables (Logs Ingestion API destinations)
#
# One explicitly-schema'd custom table per F5 category plus the DLQ table.
# Created with the generic Azure API provider because azurerm cannot yet create
# a custom-log table with a caller-defined schema.
#
# `TimeGenerated` is included in every schema (see locals.tf). Columns not
# listed are dropped at ingestion, so keep these in sync with the pipeline.
# ---------------------------------------------------------------------------

resource "azapi_resource" "table" {
  for_each = local.tables

  type      = "Microsoft.OperationalInsights/workspaces/tables@2022-10-01"
  name      = each.value.name
  parent_id = local.workspace_id

  body = {
    properties = merge(
      {
        plan = each.value.plan
        schema = {
          name = each.value.name
          columns = [
            for c in each.value.columns : merge(
              {
                name = c.name
                type = lookup(local.table_type_map, c.type, c.type)
              },
              try(c.description, null) != null ? { description = c.description } : {}
            )
          ]
        }
      },
      # retentionInDays is only valid on Analytics-plan tables.
      each.value.plan == "Analytics" && each.value.retention_in_days != null ? { retentionInDays = each.value.retention_in_days } : {},
      each.value.total_retention_in_days != null ? { totalRetentionInDays = each.value.total_retention_in_days } : {},
    )
  }

  # The workspace must exist before its tables.
  depends_on = [azurerm_log_analytics_workspace.this]
}
