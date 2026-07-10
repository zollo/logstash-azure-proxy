# ---------------------------------------------------------------------------
# Outputs
#
# The first five map 1:1 onto the container's required environment variables:
#
#   AZURE_TENANT_ID         = tenant_id
#   AZURE_CLIENT_ID         = client_id
#   AZURE_CLIENT_SECRET     = client_secret        (sensitive)
#   AZURE_DCE_URI           = data_collection_endpoint_uri
#   AZURE_DCR_IMMUTABLE_ID  = dcr_immutable_id
#
# The stream names already match the container defaults, so you usually don't
# need to set AZURE_STREAM_* unless you changed table_prefix.
# ---------------------------------------------------------------------------

output "tenant_id" {
  description = "Entra ID tenant — set as AZURE_TENANT_ID."
  value       = data.azurerm_client_config.current.tenant_id
}

output "client_id" {
  description = "Service-principal application (client) id — set as AZURE_CLIENT_ID. Null when bringing your own identity."
  value       = var.create_app_registration ? azuread_application.this[0].client_id : null
}

output "client_secret" {
  description = "Service-principal client secret — set as AZURE_CLIENT_SECRET. Null when bringing your own identity."
  value       = var.create_app_registration ? azuread_application_password.this[0].value : null
  sensitive   = true
}

output "data_collection_endpoint_uri" {
  description = "DCE logs-ingestion URI — set as AZURE_DCE_URI."
  value       = azurerm_monitor_data_collection_endpoint.this.logs_ingestion_endpoint
}

output "dcr_immutable_id" {
  description = "DCR immutable id — set as AZURE_DCR_IMMUTABLE_ID."
  value       = azurerm_monitor_data_collection_rule.this.immutable_id
}

output "workspace_id" {
  description = "Resource ID of the Log Analytics workspace the tables live in."
  value       = local.workspace_id
}

output "stream_names" {
  description = "Category -> DCR stream name. Feed these into AZURE_STREAM_* only if you overrode table_prefix."
  value       = { for category, t in local.tables : category => t.stream_name }
}

output "table_names" {
  description = "Category -> Log Analytics custom table name."
  value       = { for category, t in local.tables : category => t.name }
}

# Convenience: paste-ready .env fragment for the container (secret excluded so
# this can be shown safely; fetch it with `terraform output -raw client_secret`).
output "container_env" {
  description = "Non-sensitive AZURE_* environment lines for the container's .env (client secret excluded)."
  value = join("\n", [
    "AZURE_TENANT_ID=${data.azurerm_client_config.current.tenant_id}",
    "AZURE_CLIENT_ID=${var.create_app_registration ? azuread_application.this[0].client_id : "<your-client-id>"}",
    "AZURE_CLIENT_SECRET=<terraform output -raw client_secret>",
    "AZURE_DCE_URI=${azurerm_monitor_data_collection_endpoint.this.logs_ingestion_endpoint}",
    "AZURE_DCR_IMMUTABLE_ID=${azurerm_monitor_data_collection_rule.this.immutable_id}",
  ])
}
