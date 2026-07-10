# ---------------------------------------------------------------------------
# Input variables
# ---------------------------------------------------------------------------

variable "name_prefix" {
  description = <<-EOT
    Prefix applied to every resource name (workspace, DCE, DCR, app
    registration). Keep it short and lower-case; Azure resource-name rules
    apply. Example: "f5tel-prod".
  EOT
  type        = string
  default     = "f5tel"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,20}$", var.name_prefix))
    error_message = "name_prefix must be 2-21 chars, lower-case letters/digits/hyphens, and start alphanumeric."
  }
}

variable "location" {
  description = "Azure region for all regional resources (e.g. \"eastus2\")."
  type        = string
}

variable "resource_group_name" {
  description = "Name of the resource group to deploy into."
  type        = string
}

variable "create_resource_group" {
  description = "Create the resource group (true) or use an existing one (false)."
  type        = bool
  default     = true
}

# --- Log Analytics workspace ------------------------------------------------

variable "create_workspace" {
  description = <<-EOT
    Create a new Log Analytics workspace (true) or attach to an existing one
    (false). When false you must set `existing_workspace_id`.
  EOT
  type        = bool
  default     = true
}

variable "existing_workspace_id" {
  description = <<-EOT
    Resource ID of an existing Log Analytics workspace to use when
    `create_workspace = false`. Ignored when creating a workspace.
  EOT
  type        = string
  default     = null
}

variable "workspace_sku" {
  description = "Pricing SKU for a newly-created workspace."
  type        = string
  default     = "PerGB2018"
}

variable "workspace_retention_in_days" {
  description = "Default interactive-retention (days) for a newly-created workspace."
  type        = number
  default     = 30
}

# --- Custom tables ----------------------------------------------------------

variable "table_prefix" {
  description = <<-EOT
    Base name for the F5 custom tables. Each category becomes
    <table_prefix>_<Category>_CL (e.g. F5Telemetry_LTM_CL). The matching DCR
    stream is Custom-<table_prefix>_<Category>_CL. Change this only if you also
    update AZURE_STREAM_* in the container environment to match.
  EOT
  type        = string
  default     = "F5Telemetry"
}

variable "table_plan" {
  description = <<-EOT
    Per-table Log Analytics plan. Map keyed by the category suffix (LTM, ASM,
    System, AFM, APM, AVR, Event, DLQ). Valid values: "Analytics" or "Basic".
    Any category omitted defaults to "Analytics". The high-volume LTM request
    log is a common candidate for "Basic". See azure/README.md section 8.
  EOT
  type        = map(string)
  default     = {}
}

variable "table_retention_in_days" {
  description = <<-EOT
    Optional per-table interactive retention (days), keyed by category suffix.
    Omit a category to inherit the workspace default. `Basic`-plan tables have a
    fixed short interactive retention regardless of this value.
  EOT
  type        = map(number)
  default     = {}
}

variable "table_total_retention_in_days" {
  description = <<-EOT
    Optional per-table total retention (interactive + archive, in days), keyed
    by category suffix. Omit to inherit the workspace default.
  EOT
  type        = map(number)
  default     = {}
}

# --- Identity (service principal) ------------------------------------------

variable "create_app_registration" {
  description = <<-EOT
    Create the Microsoft Entra ID application, service principal and client
    secret the Logstash plugin uses (true). Set false to bring your own
    identity, in which case you provide `existing_principal_object_id` and wire
    its credentials into the container yourself.
  EOT
  type        = bool
  default     = true
}

variable "app_display_name" {
  description = "Display name for the created Entra ID application. Defaults to \"<name_prefix>-logstash-ingest\"."
  type        = string
  default     = null
}

variable "client_secret_expiration_hours" {
  description = "Lifetime of the generated client secret, in hours (default 1 year). Rotate before expiry."
  type        = number
  default     = 8760
}

variable "existing_principal_object_id" {
  description = <<-EOT
    Object (principal) ID of an existing service principal / managed identity to
    grant "Monitoring Metrics Publisher" on the DCR, used when
    `create_app_registration = false`.
  EOT
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags applied to all created resources."
  type        = map(string)
  default     = {}
}
