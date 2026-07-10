# ---------------------------------------------------------------------------
# Provider requirements
#
# - azurerm : Log Analytics workspace, Data Collection Endpoint / Rule, role
#             assignment.
# - azapi   : custom `_CL` tables. The azurerm provider cannot yet create a
#             custom-log table *with an explicit schema*, so we use the generic
#             Azure API provider for those (Microsoft.OperationalInsights
#             /workspaces/tables). Everything else stays on azurerm.
# - azuread : the Microsoft Entra ID application + service principal + client
#             secret the Logstash plugin authenticates with.
# ---------------------------------------------------------------------------
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 3.80, < 5.0"
    }
    azapi = {
      source  = "azure/azapi"
      version = ">= 2.0"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = ">= 3.0"
    }
  }
}
