# variables.tf

variable "vcfa_url" {
  description = "Hostname of the VCF Automation instance (without scheme), e.g. vcfa.example.com"
  type        = string
}

variable "vcfa_insecure" {
  description = "Allow unverified SSL certificates when connecting to VCF Automation"
  type        = bool
  default     = false
}

variable "vcfa_refresh_token" {
  description = "API token used to authenticate to VCF Automation"
  type        = string
  sensitive   = true
}

variable "tenant_org" {
  description = "Name of the tenant organization in VCF Automation"
  type        = string
}

variable "tenant_namespace" {
  description = "Kubernetes namespace the tenant's resources are created in"
  type        = string
}

variable "region_name" {
  description = "Name of the NSX region the tenant's VPC belongs to"
  type        = string
}

variable "tenant_vpc_name" {
  description = "Name of the tenant's VPC"
  type        = string
}

variable "security_profile_name" {
  description = "Name of the pre-existing SecurityProfile to attach to the tenant's VPC"
  type        = string
}

variable "monitoring_namespace" {
  description = "Kubernetes namespace the monitoring scraper's resources are created in"
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
}
