resource "kubernetes_manifest" "prod01_namespace_group" {
  manifest = {
    apiVersion = "vpc.nsx.vmware.com/v1alpha1"
    kind       = "NetworkSecurityGroup"
    metadata = {
      name = "prod01-namespace"
    }
    spec = {
      regionName  = var.region_name
      vmSelectors = [{ labelSelector = { matchLabels = { "nsx-op/vm_namespace" = var.tenant_namespace } } }]
    }
  }
}

resource "kubernetes_manifest" "namespace_isolation_prod01" {
  manifest = {
    apiVersion = "vpc.nsx.vmware.com/v1alpha1"
    kind       = "FirewallPolicy"
    metadata = {
      name = "namespace-isolation-prod01"
    }
    spec = {
      appliedTo  = { groupNames = [kubernetes_manifest.prod01_namespace_group.manifest.metadata.name] }
      category   = "Environment"
      priority   = 10001
      regionName = var.region_name
      stateful   = true
      tcpStrict  = true
      rules = [
        {
          name      = "allow-intra-namespace"
          direction = "InOut"
          action    = "JumpToApplication"
          from      = [{ groupName = "prod01-namespace" }]
          to        = [{ groupName = "prod01-namespace" }]
          services  = [{ networkServiceName = "Any" }]
        },
        {
          name      = "allow-https-inbound"
          direction = "In"
          action    = "Allow"
          from      = [{ groupName = "Any" }]
          to        = [{ groupName = "Any" }]
          services  = [{ networkServiceName = ":HTTPS" }]
        },
        {
          name      = "block-any-inbound"
          direction = "In"
          action    = "Drop"
          from      = [{ groupName = "Any" }]
          to        = [{ groupName = "Any" }]
          services  = [{ networkServiceName = "Any" }]
        }
      ]
    }
  }

  depends_on = [kubernetes_manifest.prod01_namespace_group]
}