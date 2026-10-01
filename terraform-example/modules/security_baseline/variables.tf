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
