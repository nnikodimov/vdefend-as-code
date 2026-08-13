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
