resource "kubernetes_manifest" "app01_group" {
  manifest = {
    apiVersion = "vpc.nsx.vmware.com/v1alpha1"
    kind       = "NetworkSecurityGroup"
    metadata = {
      name = "app01"
    }
    spec = {
      regionName  = var.region_name
      systemOwned = false
      vmSelectors = [{
        labelSelector = {
          matchExpressions = [{ key = "protected/app01", operator = "Exists" }]
        }
        namespaceSelector = {
          matchLabels = { "kubernetes.io/metadata.name" = var.tenant_namespace }
        }
      }]
    }
  }
}

resource "kubernetes_manifest" "app01_ringfencing" {
  manifest = {
    apiVersion = "vpc.nsx.vmware.com/v1alpha1"
    kind       = "FirewallPolicy"
    metadata = {
      name = "app01-ringfencing"
    }
    spec = {
      appliedTo  = { groupNames = [kubernetes_manifest.app01_group.manifest.metadata.name] }
      category   = "Application"
      priority   = 10002
      regionName = var.region_name
      stateful   = true
      tcpStrict  = true
      rules = [
        {
          name      = "allow-app01-intra"
          direction = "InOut"
          action    = "Allow"
          from      = [{ groupName = "app01" }]
          to        = [{ groupName = "app01" }]
          services  = [{ networkServiceName = "Any" }]
        },
        {
          name            = "allow-https-inbound"
          direction       = "In"
          action          = "Allow"
          from            = [{ groupName = kubernetes_manifest.dev01_namespace_group.manifest.metadata.name }]
          sourcesExcluded = true
          to              = [{ groupName = "app01" }]
          services        = [{ networkServiceName = ":HTTPS" }]
        },
        {
          name      = "app01-lockdown"
          direction = "InOut"
          action    = "Drop"
          from      = [{ groupName = "Any" }]
          to        = [{ groupName = "Any" }]
          services  = [{ networkServiceName = "Any" }]
        }
      ]
    }
  }

  depends_on = [kubernetes_manifest.app01_group, kubernetes_manifest.dev01_namespace_group]
}