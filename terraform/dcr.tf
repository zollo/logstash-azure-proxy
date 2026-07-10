# ---------------------------------------------------------------------------
# Data Collection Endpoint (DCE) + Data Collection Rule (DCR)
#
# The Logstash plugin POSTs events to the DCE's logs-ingestion URI, addressed to
# a specific DCR (immutable id) + stream. The DCR routes each stream to its
# custom table with an identity transform (`source`) — the pipeline has already
# shaped and typed every field, so no ingestion-time transform is needed.
# ---------------------------------------------------------------------------

resource "azurerm_monitor_data_collection_endpoint" "this" {
  name                          = "${var.name_prefix}-dce"
  resource_group_name           = local.resource_group_name
  location                      = local.location
  public_network_access_enabled = var.dce_public_network_access_enabled
  description                   = "Logs-ingestion endpoint for F5 telemetry from logstash-azure-proxy."
  tags                          = var.tags
}

resource "azurerm_monitor_data_collection_rule" "this" {
  name                        = "${var.name_prefix}-dcr"
  resource_group_name         = local.resource_group_name
  location                    = local.location
  data_collection_endpoint_id = azurerm_monitor_data_collection_endpoint.this.id
  description                 = "Routes F5 telemetry streams to their per-category Log Analytics tables."
  tags                        = var.tags

  destinations {
    log_analytics {
      workspace_resource_id = local.workspace_id
      name                  = "laDestination"
    }
  }

  # One inbound stream declaration per table. The column set must match what the
  # plugin sends; the plugin's `dcr_stream_name` equals stream_name here.
  dynamic "stream_declaration" {
    for_each = local.tables
    content {
      stream_name = stream_declaration.value.stream_name
      dynamic "column" {
        for_each = stream_declaration.value.columns
        content {
          name = column.value.name
          type = column.value.type
        }
      }
    }
  }

  # Route each stream straight to its custom table. For a custom table the
  # output stream name is identical to the input stream (Custom-<Table>_CL).
  dynamic "data_flow" {
    for_each = local.tables
    content {
      streams       = [data_flow.value.stream_name]
      destinations  = ["laDestination"]
      transform_kql = "source"
      output_stream = data_flow.value.stream_name
    }
  }

  # The output streams reference the custom tables, so they must exist first.
  depends_on = [azapi_resource.table]
}
