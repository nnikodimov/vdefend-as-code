# providers.tf
terraform {
  required_providers {
    vcfa = {
      source = "vmware/vcfa"
    }
    kubernetes = {
      source = "hashicorp/kubernetes"
    }
  }
}

provider "vcfa" {
  url                  = "https://${var.vcfa_url}"
  allow_unverified_ssl = var.vcfa_insecure
  org                  = var.tenant_org
  auth_type            = "api_token"
  api_token            = var.vcfa_refresh_token
}

data "vcfa_kubeconfig" "tenant" {}

provider "kubernetes" {
  host     = data.vcfa_kubeconfig.tenant.host
  token    = data.vcfa_kubeconfig.tenant.token
  insecure = data.vcfa_kubeconfig.tenant.insecure_skip_tls_verify
}
