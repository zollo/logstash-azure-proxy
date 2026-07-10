# ---------------------------------------------------------------------------
# Complete example: provision everything and print the container settings.
#
#   cd terraform/examples/complete
#   terraform init
#   terraform apply -var 'location=eastus2' -var 'resource_group_name=rg-f5tel'
#
# Then wire the outputs into the container:
#   terraform output container_env            # non-sensitive lines
#   terraform output -raw client_secret       # the secret, on its own
# ---------------------------------------------------------------------------

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = ">= 3.80, < 5.0" }
    azapi   = { source = "azure/azapi", version = ">= 2.0" }
    azuread = { source = "hashicorp/azuread", version = ">= 3.0" }
  }
}

provider "azurerm" {
  features {}
  # subscription_id is read from ARM_SUBSCRIPTION_ID / az login context.
}

provider "azapi" {}
provider "azuread" {}

variable "location" { type = string }
variable "resource_group_name" { type = string }

module "f5_sentinel" {
  source = "../.."

  name_prefix         = "f5tel"
  location            = var.location
  resource_group_name = var.resource_group_name

  # Tier the high-volume LTM request log down to Basic; keep the rest on
  # Analytics. See azure/README.md section 8.
  table_plan = {
    LTM = "Basic"
  }

  tags = {
    project = "logstash-azure-proxy"
    owner   = "sre"
  }
}

output "container_env" {
  value = module.f5_sentinel.container_env
}

output "client_secret" {
  value     = module.f5_sentinel.client_secret
  sensitive = true
}
