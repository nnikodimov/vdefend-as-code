variable "region_name" {
  description = "Name of the NSX region the Transit Gateway belongs to"
  type        = string
}

variable "tgw_name" {
  description = "Name of the Organization's Transit Gateway"
  type        = string
}

variable "tgw_external_connections" {
  description = "Per-external-connection TGW firewall settings, keyed by a short connection name"
  type = map(object({
    attachment_name      = string       # TGW attachment backing this external connection
    remote_cidrs         = list(string) # prefixes reachable over this connection
    inbound_target_group = string       # Region-scoped group inbound traffic may reach
    inbound_services     = list(string) # NetworkService names allowed in; [] = no inbound
    outbound_services    = list(string) # NetworkService names allowed out; [] = no outbound
  }))
  default = {}
}
