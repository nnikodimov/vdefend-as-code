# main.tf

import {
  to = module.security_baseline.kubernetes_manifest.patch_profile_attachment
  id = "apiVersion=vpc.nsx.vmware.com/v1alpha1,kind=SecurityProfileAttachment,var.tenant_vpc_name"
}

module "security_baseline" {
  source = "./modules/security_baseline"

  region_name           = var.region_name
  tenant_vpc_name       = var.tenant_vpc_name
  security_profile_name = var.security_profile_name
}

module "namespace_segmentation" {
  source = "./modules/namespace_segmentation"

  region_name      = var.region_name
  tenant_namespace = var.tenant_namespace
}

module "app_ringfencing" {
  source = "./modules/app_ringfencing"

  region_name          = var.region_name
  tenant_namespace     = var.tenant_namespace
  namespace_group_name = module.namespace_segmentation.namespace_group_name
}

module "tgw_firewall" {
  source = "./modules/tgw_firewall"

  region_name              = var.region_name
  tgw_name                 = var.tgw_name
  tgw_external_connections = var.tgw_external_connections
}
