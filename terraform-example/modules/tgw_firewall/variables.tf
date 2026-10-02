variable "region_name" {
  description = "Name of the NSX region the Transit Gateways belong to"
  type        = string
}

variable "tgw_external_connections" {
  description = "Per-external-connection TGW firewall settings, keyed by a short connection name"
  type = map(object({
    transit_gateway_name     = string           # TransitGateway the connection hangs off, e.g. "tgw-prod"
    external_connection_name = optional(string) # GatewayConnection / Distributed VLAN|VXLAN connection; needed only if the TGW has several
    remote_cidrs             = list(string)     # prefixes reachable over this connection
    inbound_target_group     = string           # Region-scoped group inbound traffic may reach
    inbound_services         = list(string)     # NetworkService names allowed in; [] = no inbound
    outbound_services        = list(string)     # NetworkService names allowed out; [] = no outbound
  }))
  default = {}
}
