# modules/tgw_firewall
#
# One TGWFirewallPolicy per Transit Gateway external connection (§5.5).
# An external connection is realized as a TGWAttachment (TGW <-> GatewayConnection
# or Distributed VLAN/VXLAN connection); every rule here is scoped to that one
# attachment via appliedTo.gatewayAttachmentNames, so adding, tightening, or
# removing a connection is a one-entry change to var.tgw_external_connections
# and never touches another connection's rules.
#
# Attachment names carry a generated suffix (e.g. tgw-prod:jjl9), so they are
# looked up from the live TGWAttachment objects rather than hard-coded.

data "kubernetes_resources" "tgw_attachments" {
  api_version = "vpc.nsx.vmware.com/v1alpha1"
  kind        = "TGWAttachment"
}

locals {
  # Attachments matching each entry's Transit Gateway and, if set, its external
  # connection (whichever of the three connection fields the attachment uses).
  tgw_attachment_matches = {
    for k, c in var.tgw_external_connections : k => [
      for a in data.kubernetes_resources.tgw_attachments.objects : a.metadata.name
      if a.spec.transitGatewayName == c.transit_gateway_name && (
        c.external_connection_name == null || contains([
          try(a.spec.gatewayConnectionName, ""),
          try(a.spec.distributedVLANConnectionName, ""),
          try(a.spec.distributedVXLANConnectionName, ""),
        ], c.external_connection_name != null ? c.external_connection_name : "")
      )
    ]
  }

  tgw_attachment_name = {
    for k, m in local.tgw_attachment_matches : k => length(m) == 1 ? m[0] : ""
  }
}

# Region-scoped group holding the prefixes reachable over one external connection.
resource "kubernetes_manifest" "tgw_connection_remote_group" {
  for_each = var.tgw_external_connections

  manifest = {
    apiVersion = "vpc.nsx.vmware.com/v1alpha1"
    kind       = "NetworkSecurityGroup"
    metadata = {
      name = "${each.key}-remote"
    }
    spec = {
      regionName  = var.region_name
      ipAddresses = each.value.remote_cidrs
    }
  }

  # Objects created through CCI end up with fields owned by "before-first-apply",
  # so an in-place update conflicts unless Terraform forces ownership (as in
  # security_baseline).
  field_manager {
    force_conflicts = true
  }
}

resource "kubernetes_manifest" "tgw_connection_policy" {
  for_each = var.tgw_external_connections

  manifest = {
    apiVersion = "vpc.nsx.vmware.com/v1alpha1"
    kind       = "TGWFirewallPolicy"
    metadata = {
      name = "${each.key}-tgw-policy"
    }
    spec = {
      category   = "LocalGatewayRules"
      regionName = var.region_name
      stateful   = true
      tcpStrict  = true
      rules = concat(
        length(each.value.inbound_services) == 0 ? [] : [{
          name       = "${each.key}-allow-inbound"
          direction  = "In"
          action     = "Allow"
          ipProtocol = "IPV4"
          appliedTo  = { gatewayAttachmentNames = [local.tgw_attachment_name[each.key]] }
          from       = [{ groupName = kubernetes_manifest.tgw_connection_remote_group[each.key].manifest.metadata.name }]
          to         = [{ groupName = each.value.inbound_target_group }]
          services   = [for s in each.value.inbound_services : { networkServiceName = s }]
        }],
        length(each.value.outbound_services) == 0 ? [] : [{
          name       = "${each.key}-allow-outbound"
          direction  = "Out"
          action     = "Allow"
          ipProtocol = "IPV4"
          appliedTo  = { gatewayAttachmentNames = [local.tgw_attachment_name[each.key]] }
          from       = [{ groupName = "Any" }]
          to         = [{ groupName = kubernetes_manifest.tgw_connection_remote_group[each.key].manifest.metadata.name }]
          services   = [for s in each.value.outbound_services : { networkServiceName = s }]
        }],
        [{
          name       = "${each.key}-deny-other"
          direction  = "InOut"
          action     = "Drop"
          ipProtocol = "IPV4"
          appliedTo  = { gatewayAttachmentNames = [local.tgw_attachment_name[each.key]] }
          from       = [{ groupName = "Any" }]
          to         = [{ groupName = "Any" }]
          services   = [{ networkServiceName = "Any" }]
        }]
      )
    }
  }

  field_manager {
    force_conflicts = true
  }

  lifecycle {
    precondition {
      condition     = length(local.tgw_attachment_matches[each.key]) == 1
      error_message = "${each.key}: expected exactly one TGWAttachment on Transit Gateway \"${each.value.transit_gateway_name}\"${each.value.external_connection_name == null ? "" : " to \"${each.value.external_connection_name}\""}, found ${length(local.tgw_attachment_matches[each.key])}: [${join(", ", local.tgw_attachment_matches[each.key])}]. Set external_connection_name to pick one; list them with: kubectl get tgwattachments."
    }
    # Each policy ends in a drop-all scoped to its attachment, so two entries on the
    # same attachment would shadow each other's allow rules.
    precondition {
      condition     = local.tgw_attachment_name[each.key] == "" || length([for k, n in local.tgw_attachment_name : k if n == local.tgw_attachment_name[each.key]]) == 1
      error_message = "${each.key}: TGWAttachment \"${local.tgw_attachment_name[each.key]}\" is also used by another entry; put all rules for one external connection under a single key."
    }
  }

  depends_on = [kubernetes_manifest.tgw_connection_remote_group]
}
