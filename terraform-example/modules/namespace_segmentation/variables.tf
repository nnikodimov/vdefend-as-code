variable "region_name" {
  description = "Name of the NSX region the tenant's VPC belongs to"
  type        = string
}

variable "tenant_namespace" {
  description = "vSphere Namespace whose workloads are segmented"
  type        = string
}
