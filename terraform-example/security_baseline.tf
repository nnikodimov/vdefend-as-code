import {
  to = kubernetes_manifest.patch_profile_attachment
  id = "apiVersion=vpc.nsx.vmware.com/v1alpha1,kind=SecurityProfileAttachment,var.tenant_vpc_name"
}

resource "kubernetes_manifest" "patch_profile_attachment" {
  manifest = {
    apiVersion = "vpc.nsx.vmware.com/v1alpha1"
    kind       = "SecurityProfileAttachment"
    metadata = {
      name = var.tenant_vpc_name
    }
    spec = {
      regionName          = var.region_name
      securityProfileName = var.security_profile_name
      vpcName             = var.tenant_vpc_name
    }
  }

  field_manager {
    force_conflicts = true
  }
}