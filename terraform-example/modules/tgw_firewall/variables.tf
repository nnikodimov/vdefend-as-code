variable "region_name" {
  description = "Name of the NSX region the Transit Gateways belong to"
  type        = string
}

variable "tgw_name" {
  description = "Transit Gateway whose external connections are firewalled, e.g. tgw-prod"
  type        = string
}

variable "tgw_external_connections" {
  description = "Per-external-connection TGW firewall settings on var.tgw_name, keyed by a short connection name"
  type = map(object({
    connection_name      = string       # GatewayConnection / Distributed VLAN|VXLAN connection attached to var.tgw_name
    remote_cidrs         = list(string) # prefixes reachable over this connection
    inbound_target_group = string       # Region-scoped group inbound traffic may reach
    inbound_services     = list(string) # NetworkService names allowed in; [] = no inbound
    outbound_services    = list(string) # NetworkService names allowed out; [] = no outbound
  }))
  default = {}

  # Each policy ends in a drop-all scoped to its attachment, so two entries on the
  # same connection would shadow each other's allow rules.
  validation {
    condition     = length(distinct([for c in values(var.tgw_external_connections) : c.connection_name])) == length(var.tgw_external_connections)
    error_message = "Each connection_name may appear in only one entry; put all rules for one external connection under a single key."
  }
}
