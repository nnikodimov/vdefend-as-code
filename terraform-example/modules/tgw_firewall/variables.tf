variable "region_name" {
  description = "Name of the NSX region the Transit Gateways belong to"
  type        = string
}

variable "tgw_external_connections" {
  description = "Per-external-connection TGW firewall settings, keyed by a short connection name"
  type = map(object({
    attachment_name      = string       # TGWAttachment name, e.g. "tgw-prod:jjl9"
    remote_cidrs         = list(string) # prefixes reachable over this connection
    inbound_target_group = string       # Region-scoped group inbound traffic may reach
    inbound_services     = list(string) # NetworkService names allowed in; [] = no inbound
    outbound_services    = list(string) # NetworkService names allowed out; [] = no outbound
  }))
  default = {}
}
