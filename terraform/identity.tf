# ---------------------------------------------------------------------------
# Microsoft Entra ID identity + role assignment
#
# The Logstash plugin authenticates as a service principal (client id + secret +
# tenant) and needs the "Monitoring Metrics Publisher" role on the DCR to push
# data through the Logs Ingestion API. Set create_app_registration = false to
# bring your own identity (e.g. a user-assigned managed identity) — the role
# assignment below still wires it to the DCR via existing_principal_object_id.
# ---------------------------------------------------------------------------

resource "azuread_application" "this" {
  count        = var.create_app_registration ? 1 : 0
  display_name = local.app_display_name

  # This app is used purely for machine-to-machine log ingestion.
  sign_in_audience = "AzureADMyOrg"

  tags = [for k, v in var.tags : "${k}:${v}"]
}

resource "azuread_service_principal" "this" {
  count     = var.create_app_registration ? 1 : 0
  client_id = azuread_application.this[0].client_id

  description = "logstash-azure-proxy F5 telemetry ingestion"
}

resource "azuread_application_password" "this" {
  count             = var.create_app_registration ? 1 : 0
  application_id    = azuread_application.this[0].id
  display_name      = "logstash-azure-proxy"
  end_date_relative = "${var.client_secret_expiration_hours}h"
}

# "Monitoring Metrics Publisher" — the role that grants data push to a DCR.
resource "azurerm_role_assignment" "dcr_publisher" {
  scope                = azurerm_monitor_data_collection_rule.this.id
  role_definition_name = "Monitoring Metrics Publisher"
  principal_id         = local.principal_object_id

  # A just-created service principal may not have replicated across Entra ID by
  # the time the role assignment runs; skip the existence pre-check to avoid a
  # spurious PrincipalNotFound on first apply.
  skip_service_principal_aad_check = true
}
