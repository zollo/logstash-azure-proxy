# ---------------------------------------------------------------------------
# Resource group + Log Analytics workspace
# ---------------------------------------------------------------------------

data "azurerm_client_config" "current" {}

# Fail fast on inconsistent "bring your own" combinations.
resource "terraform_data" "guardrails" {
  lifecycle {
    precondition {
      condition     = var.create_workspace || var.existing_workspace_id != null
      error_message = "Set create_workspace = true, or provide existing_workspace_id when create_workspace = false."
    }
    precondition {
      condition     = var.create_app_registration || var.existing_principal_object_id != null
      error_message = "Set create_app_registration = true, or provide existing_principal_object_id when create_app_registration = false."
    }
  }
}

resource "azurerm_resource_group" "this" {
  count    = var.create_resource_group ? 1 : 0
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

data "azurerm_resource_group" "existing" {
  count = var.create_resource_group ? 0 : 1
  name  = var.resource_group_name
}

resource "azurerm_log_analytics_workspace" "this" {
  count               = var.create_workspace ? 1 : 0
  name                = "${var.name_prefix}-law"
  location            = local.location
  resource_group_name = local.resource_group_name
  sku                 = var.workspace_sku
  retention_in_days   = var.workspace_retention_in_days
  tags                = var.tags
}
