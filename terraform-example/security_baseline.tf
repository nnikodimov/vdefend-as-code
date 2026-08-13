# security_baseline.tf
resource "kubernetes_manifest" "security_profile" {
  manifest = {
    apiVersion = "vpc.nsx.vmware.com/v1alpha1"
    kind       = "SecurityProfile"
    metadata = {
      name      = "${var.tenant_name}-security-profile"
      namespace = var.tenant_namespace
    }
    spec = {
      regionName         = var.region_name
      isDefault          = false
      northSouthFirewall = { enabled = true }
      eastWestFirewall   = { securityStrategies = ["vpc-isolation"] }
    }
  }
}

resource "kubernetes_manifest" "security_profile_attachment" {
  manifest = {
    apiVersion = "vpc.nsx.vmware.com/v1alpha1"
    kind       = "SecurityProfileAttachment"
    metadata = {
      name      = "${var.tenant_name}-security-profile-attachment"
      namespace = var.tenant_namespace
    }
    spec = {
      regionName          = var.region_name
      securityProfileName = "${var.tenant_name}-security-profile"
      vpcName             = var.tenant_vpc_name
    }
  }
}

resource "kubernetes_manifest" "app_tier_group" {
  manifest = {
    apiVersion = "vpc.nsx.vmware.com/v1alpha1"
    kind       = "NetworkSecurityGroup"
    metadata = {
      name      = "${var.tenant_name}-app-tier"
      namespace = var.tenant_namespace
    }
    spec = {
      regionName  = var.region_name
      vmSelectors = [{ labelSelector = { matchLabels = { tier = "app" } } }]
    }
  }
}

resource "kubernetes_manifest" "default_deny_gateway" {
  manifest = {
    apiVersion = "vpc.nsx.vmware.com/v1alpha1"
    kind       = "VPCGatewayFirewallPolicy"
    metadata = {
      name      = "${var.tenant_name}-perimeter-default-deny"
      namespace = var.tenant_namespace
    }
    spec = {
      regionName = var.region_name
      vpcName    = var.tenant_vpc_name
      category   = "LocalGatewayRules"
      rules = [
        { name = "deny-all-inbound", direction = "In", action = "Drop" }
      ]
    }
  }
}
