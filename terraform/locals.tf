# ---------------------------------------------------------------------------
# Table & column schema definitions
#
# These schemas mirror exactly what the Logstash pipeline emits (see
# ../pipeline/*.conf). With the Logs Ingestion API the table schema is
# *explicit*: any field the pipeline sends that is NOT declared here is dropped
# at ingestion. When you extend a module in the pipeline (e.g. add AFM parsing),
# add the new columns to the relevant list below and re-apply.
#
# Column `type` uses the Data Collection Rule vocabulary (all lower-case):
#   string | int | long | real | boolean | datetime | dynamic
# The custom-table API wants "dateTime" (camel-case); local.table_type_map
# handles that single rename when the table body is built.
# ---------------------------------------------------------------------------

locals {
  # TimeGenerated is mandatory on every Log Analytics table and is the field the
  # pipeline sets in 80-finalize.conf. It must be first / present in the stream.
  time_generated_column = [
    { name = "TimeGenerated", type = "datetime", description = "Event time (ISO8601) chosen by the pipeline: device timestamp when present, else ingest time." },
  ]

  # Normalized cross-module columns added to every F5 event by 10-classify.conf
  # and 70-normalize.conf. Present (though sometimes null) on every category
  # table so a union query can pivot on one consistent name.
  common_columns = [
    { name = "f5_telemetry_category", type = "string", description = "Resolved F5 TS category (LTM/ASM/systemInfo/AFM/APM/AVR/event)." },
    { name = "f5_collector", type = "string", description = "Constant collector id: logstash-azure-proxy (-dlq for DLQ rows)." },
    { name = "f5_device_hostname", type = "string", description = "Originating BIG-IP hostname (hostname / system.hostname)." },
    { name = "f5_src_ip", type = "string", description = "Normalized source IP (LTM client_ip / ASM ip_client / AFM source_ip)." },
    { name = "f5_dest_ip", type = "string", description = "Normalized destination IP (LTM server_ip / ASM|AFM dest_ip)." },
    { name = "f5_http_method", type = "string", description = "Normalized HTTP verb (LTM http_method / ASM method)." },
    { name = "f5_response_code", type = "int", description = "Normalized HTTP status code." },
    { name = "f5_src_country", type = "string", description = "GeoIP country of f5_src_ip (public IPs only)." },
    { name = "f5_src_city", type = "string", description = "GeoIP city of f5_src_ip (public IPs only)." },
  ]

  # Per-category columns (in addition to time_generated + common). Keyed by the
  # category suffix that also forms the table name and DCR stream name.
  module_columns = {
    LTM = [
      { name = "event_source", type = "string" },
      { name = "virtual_name", type = "string" },
      { name = "client_ip", type = "string" },
      { name = "client_port", type = "int" },
      { name = "server_ip", type = "string" },
      { name = "server_port", type = "int" },
      { name = "http_method", type = "string" },
      { name = "http_uri", type = "string" },
      { name = "protocol", type = "string" },
      { name = "protocol_id", type = "int" },
      { name = "response_code", type = "int" },
      { name = "response_code_class", type = "string", description = "Status bucket 2xx/3xx/4xx/5xx, derived in 20-ltm.conf." },
      { name = "response_ms", type = "int" },
      { name = "response_size", type = "int" },
      { name = "request_size", type = "int" },
    ]

    ASM = [
      { name = "policy_name", type = "string" },
      { name = "web_application_name", type = "string" },
      { name = "request_status", type = "string" },
      { name = "severity", type = "string" },
      { name = "violation_rating", type = "int" },
      # 30-asm.conf splits these comma-delimited fields into arrays -> dynamic.
      { name = "attack_type", type = "dynamic" },
      { name = "violations", type = "dynamic" },
      { name = "sub_violations", type = "dynamic" },
      { name = "sig_ids", type = "dynamic" },
      { name = "sig_names", type = "dynamic" },
      { name = "staged_sig_ids", type = "dynamic" },
      { name = "ip_client", type = "string" },
      { name = "geo_location", type = "string" },
      { name = "src_port", type = "int" },
      { name = "dest_ip", type = "string" },
      { name = "dest_port", type = "int" },
      { name = "route_domain", type = "int" },
      { name = "method", type = "string" },
      { name = "response_code", type = "int" },
      { name = "support_id", type = "string" },
      { name = "date_time", type = "string" },
    ]

    System = [
      { name = "f5_device_version", type = "string" },
      { name = "f5_device_machineId", type = "string" },
      { name = "f5_device_failoverStatus", type = "string" },
      { name = "f5_device_syncStatus", type = "string" },
      { name = "f5_device_cpu", type = "int" },
      { name = "f5_device_memory", type = "int" },
      { name = "f5_device_tmm_cpu", type = "int" },
      { name = "f5_device_tmm_memory", type = "int" },
      # Deep snapshot objects preserved as dynamic so parse-free drill-down works.
      { name = "system", type = "dynamic" },
      { name = "virtualServers", type = "dynamic" },
      { name = "pools", type = "dynamic" },
    ]

    # AFM/APM/AVR are routed + baseline-parsed today (50-modules-future.conf);
    # extend these lists as you enable deeper parsing.
    AFM = [
      { name = "acl_policy_name", type = "string" },
      { name = "acl_rule_name", type = "string" },
      { name = "action", type = "string" },
      { name = "source_ip", type = "string" },
      { name = "source_port", type = "int" },
      { name = "dest_ip", type = "string" },
      { name = "dest_port", type = "int" },
      { name = "protocol", type = "string" },
      { name = "vlan", type = "int" },
      { name = "date_time", type = "string" },
    ]

    APM = [
      { name = "Access_Profile", type = "string" },
      { name = "Access_Policy_Result", type = "string" },
    ]

    AVR = [
      { name = "Entity", type = "string" },
      { name = "AvgCpu", type = "int" },
      { name = "HitCount", type = "int" },
      { name = "SlotId", type = "int" },
      { name = "EOCTimestamp", type = "string" },
    ]

    # Fallback for events that can't be classified. Kept minimal; the common
    # normalized columns still apply.
    Event = [
      { name = "message", type = "string" },
    ]
  }

  # The Dead Letter Queue table has its own shape (see ../dlq/dlq.conf); it does
  # not share the common F5 columns.
  dlq_columns = concat(local.time_generated_column, [
    { name = "f5_collector", type = "string" },
    { name = "f5_dlq_reason", type = "string", description = "Why the event could not be processed." },
    { name = "f5_dlq_plugin_id", type = "string", description = "The plugin that rejected it." },
    { name = "f5_dlq_entry_time", type = "string", description = "When it entered the Dead Letter Queue." },
  ])

  # Assemble the full column list per category table.
  f5_table_columns = {
    for category, cols in local.module_columns :
    category => concat(local.time_generated_column, local.common_columns, cols)
  }

  # Complete set of tables to create: F5 category tables + the DLQ table.
  all_table_columns = merge(local.f5_table_columns, { DLQ = local.dlq_columns })

  # Derive names for each table. tables["LTM"] = {
  #   name        = "F5Telemetry_LTM_CL"   (Log Analytics custom table)
  #   stream_name = "Custom-F5Telemetry_LTM_CL"  (DCR stream + plugin dcr_stream_name)
  #   columns     = [ { name, type, description? }, ... ]
  #   plan/retention...
  # }
  tables = {
    for category, cols in local.all_table_columns :
    category => {
      name                    = "${var.table_prefix}_${category}_CL"
      stream_name             = "Custom-${var.table_prefix}_${category}_CL"
      columns                 = cols
      plan                    = lookup(var.table_plan, category, "Analytics")
      retention_in_days       = lookup(var.table_retention_in_days, category, null)
      total_retention_in_days = lookup(var.table_total_retention_in_days, category, null)
    }
  }

  # DCR stream column types are lower-case; the tables REST API expects the
  # camel-case "dateTime". Only that one value differs.
  table_type_map = {
    string   = "string"
    int      = "int"
    long     = "long"
    real     = "real"
    boolean  = "boolean"
    datetime = "dateTime"
    dynamic  = "dynamic"
  }

  # Resolved workspace / resource-group / location plumbing.
  resource_group_name = var.create_resource_group ? azurerm_resource_group.this[0].name : data.azurerm_resource_group.existing[0].name
  location            = var.create_resource_group ? azurerm_resource_group.this[0].location : data.azurerm_resource_group.existing[0].location
  workspace_id        = var.create_workspace ? azurerm_log_analytics_workspace.this[0].id : var.existing_workspace_id

  principal_object_id = var.create_app_registration ? azuread_service_principal.this[0].object_id : var.existing_principal_object_id

  app_display_name = coalesce(var.app_display_name, "${var.name_prefix}-logstash-ingest")
}
