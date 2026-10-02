# modules/tgw_firewall
#
# One TGWFirewallPolicy per Transit Gateway external connection (§5.5).
# An external connection is realized as a TGWAttachment (TGW <-> GatewayConnection
# or Distributed VLAN/VXLAN connection); every rule here is scoped to that one
# attachment via appliedTo.gatewayAttachmentNames, so adding, tightening, or
# removing a connection is a one-entry change to var.tgw_external_connections
# and never touches another connection's rules.
#
# List the attachments to key on with: kubectl get tgwattachments

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
          appliedTo  = { gatewayAttachmentNames = [each.value.attachment_name] }
          from       = [{ groupName = kubernetes_manifest.tgw_connection_remote_group[each.key].manifest.metadata.name }]
          to         = [{ groupName = each.value.inbound_target_group }]
          services   = [for s in each.value.inbound_services : { networkServiceName = s }]
        }],
        length(each.value.outbound_services) == 0 ? [] : [{
          name       = "${each.key}-allow-outbound"
          direction  = "Out"
          action     = "Allow"
          ipProtocol = "IPV4"
          appliedTo  = { gatewayAttachmentNames = [each.value.attachment_name] }
          from       = [{ groupName = "Any" }]
          to         = [{ groupName = kubernetes_manifest.tgw_connection_remote_group[each.key].manifest.metadata.name }]
          services   = [for s in each.value.outbound_services : { networkServiceName = s }]
        }],
        [{
          name       = "${each.key}-deny-other"
          direction  = "InOut"
          action     = "Drop"
          ipProtocol = "IPV4"
          appliedTo  = { gatewayAttachmentNames = [each.value.attachment_name] }
          from       = [{ groupName = "Any" }]
          to         = [{ groupName = "Any" }]
          services   = [{ networkServiceName = "Any" }]
        }]
      )
    }
  }

  depends_on = [kubernetes_manifest.tgw_connection_remote_group]
}
