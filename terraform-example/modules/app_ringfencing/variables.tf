variable "region_name" {
  description = "Name of the NSX region the tenant's VPC belongs to"
  type        = string
}

variable "tenant_namespace" {
  description = "vSphere Namespace the ringfenced application runs in"
  type        = string
}

variable "namespace_group_name" {
  description = "NetworkSecurityGroup of the application's own namespace, excluded from the HTTPS-inbound rule"
  type        = string
}
