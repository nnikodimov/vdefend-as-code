# Accelerating Secure App Deployments in VCF with vDefend

---

## Abstract

---

VMware Cloud Foundation (VCF) 9's VPC (Virtual Private Cloud) model exposes Networking and Security, — as declarative Kubernetes-style custom resources through VCF Automation's **Cloud Consumption Interface (CCI)**. This turns Organizations (tenants) security configuration from a series of point-and-click console workflows into version-controlled, reviewable, and automatable code. This paper focuses on the API resource kinds that carry that security model and explores two production-grade automation patterns against them: **Terraform** (apply-time infrastructure-as-code) and **Argo CD** (continuous GitOps reconciliation), including a worked multi-tier tenant onboarding example with runnable code.
---

## 1. Executive Summary

Traditionally, configuring per-tenant network security in a VCF private cloud meant a security admin logging into a management console, building Groups and DFW/gateway firewall rules by hand, and hoping change control caught drift. VCF Automation's CCI changes this by projecting a vDefend entire security model — group membership, firewall policies, and firewall rules at three distinct enforcement points — as Kubernetes custom resources scoped to a **Supervisor Namespace** inside a tenant **Project**. Because these are ordinary Kubernetes objects behind a standard API server, every mainstream infrastructure-as-code and GitOps tool works against them without a bespoke integration.

The five resource kinds this paper focuses on map directly onto the VPC's three real enforcement points inside and around it:

| Resource kind | Enforcement point | Analogous to |
|---|---|---|
| `NetworkSecurityGroup` | N/A — reusable, region-scoped membership object | A region-scoped Group, referenced by `FirewallPolicy` and `TGWFirewallPolicy` |
| `SecurityProfile` | N/A — cross-cutting policy-mode object | A per-VPC security posture (north-south firewall on/off, east-west isolation strategy), only live once bound to a VPC via `SecurityProfileAttachment` |
| `FirewallPolicy` | East-west, intra-VPC | The Distributed Firewall (micro-segmentation) |
| `VPCGatewayFirewallPolicy` | North-south, per-VPC perimeter | The VPC's Gateway Firewall |
| `TGWFirewallPolicy` | East-west, inter-VPC | Transit Gateway firewalling / VPC Connectivity Policies |

This gives platform teams two complementary automation levers:

1. **Terraform**, using the `kubernetes` provider (fed a kubeconfig retrieved from the `vcfa` provider) to declare these objects as part of a tenant's provisioning pipeline — good for day-0 environment stand-up and for teams already standardized on Terraform for multi-cloud IaC.
2. **Argo CD**, registering the tenant's Supervisor Namespace as a target and continuously reconciling `NetworkSecurityGroup`/`FirewallPolicy`/`VPCGatewayFirewallPolicy`/`TGWFirewallPolicy` manifests from Git — good for day-2 drift correction, self-healing enforcement, and a pure GitOps self-service loop.

The recommended pattern for most enterprises is **hybrid**: Terraform provisions the tenant "shell" (Project, VPC, Subnets, quotas, RBAC, and a baseline `SecurityProfile`/default-deny `FirewallPolicy`) as part of the onboarding pipeline, and Argo CD owns the day-2 lifecycle of `NetworkSecurityGroup`, `FirewallPolicy`, `VPCGatewayFirewallPolicy`, and `TGWFirewallPolicy` objects as long-lived, continuously reconciled state that tenants and security teams iterate on independently of infrastructure changes.

---

## 2. Background: VCF Automation, CCI, and the vDefend Security Model

### 2.1 Cloud Consumption Interface (CCI)

CCI is the Kubernetes-style consumption layer of VCF Automation. Instead of a proprietary REST API, CCI exposes a real Kubernetes API server: tenants authenticate, receive a **kubeconfig context per Supervisor Namespace** their Project owns, and interact with it via `kubectl`, any Kubernetes client library, Terraform's `kubernetes`/`kubectl` providers, or a GitOps controller like Argo CD. Relevant API groups include:

| API group | Purpose |
|---|---|
| `project.cci.vmware.com/v1alpha2` | Tenant Project definition (the top-level multi-tenancy boundary) |
| `infrastructure.cci.vmware.com/v1alpha1-3` | Namespace classes, quotas, zone/region association — the guardrails a provider admin sets before a tenant gets self-service access |
| `authorization.cci.vmware.com/v1alpha1` | RBAC / role bindings scoped to a Project or namespace |
| `topology.cci.vmware.com/v1alpha1-2` | Region/zone/supervisor topology |
| `vpc.nsx.vmware.com/v1alpha1` | **VPC networking and security**: `VPC`, `Subnet`, `NetworkSecurityGroup`/`VPCNetworkSecurityGroup` (+ their `IPMembers` subresources), `NetworkService`, `SecurityProfile`, `SecurityProfileAttachment`, `SecurityStrategy`, `FirewallPolicy`, `VPCGatewayFirewallPolicy`, `TGWFirewallPolicy`, `TGWSecurityConfig`, `VPCConnectivityProfile`/`VPCConnectivityProfileBinding`, `RegionNetworkingCapabilities` |
| `vmoperator.vmware.com/v1alpha3` | VM lifecycle (the workloads the security policy protects) |

### 2.2 Multi-tenancy hierarchy

```
Provider Admin
   └─ Region (group of Supervisors)
        └─ Project  (tenant boundary)
             └─ Supervisor Namespace  (== a VPC-backed namespace)
                  ├─ VPC                       (vpc.nsx.vmware.com/v1alpha1)
                  │    ├─ Subnet(s)
                  │    ├─ SecurityProfile            <-- posture toggles (N-S FW on/off, TCP-strict)
                  │    ├─ NetworkSecurityGroup(s)     <-- reusable "who" (web-tier, app-tier, db-tier...)
                  │    ├─ FirewallPolicy(ies)         <-- east-west DFW rules (intra-VPC)
                  │    ├─ VPCGatewayFirewallPolicy    <-- north-south perimeter rules (per-VPC)
                  │    └─ TGWFirewallPolicy           <-- east-west rules between VPCs on a shared TGW
                  └─ Workloads: VirtualMachines, VKS clusters, vSphere Pods
```

A **NSX Project** is the Organization represenation in NSX. Everything a tenant can self-service — including security policy — is scoped inside the namespaces their Project owns, bounded by quotas and RBAC the provider admin defined up front via `infrastructure.cci.vmware.com` and `authorization.cci.vmware.com`. This is the enforcement point that makes tenant self-service safe: tenants can create/update `FirewallPolicy` and related objects freely inside their own namespace, but cannot touch another tenant's VPC or exceed their allotted network/compute quota.

### 2.3 vDefend security constructs surfaced through the VPC

vDefend is Broadcom's security suite natevly built into VCF. Inside a VPC, its three enforcement points are:

- **Distributed Firewall (micro-segmentation)** — east-west enforcement at each workload's vNIC *within* a VPC, driven by `FirewallPolicy` objects whose rules reference `NetworkSecurityGroup`s as source/destination peers. This is the primary object tenants author to isolate application tiers (e.g., only the app tier may talk to the DB tier on 5432).
- **VPC Gateway Firewall** — stateful north-south perimeter enforcement at the VPC's own gateway, driven by `VPCGatewayFirewallPolicy`. VCF Networking creates a default allow-all north-south rule per VPC; tenants are expected to add explicit `VPCGatewayFirewallPolicy` rules to restrict what can enter or leave the VPC boundary.
- **Transit Gateway Firewall (inter-VPC)** — east-west enforcement *between* VPCs that share a Transit Gateway, driven by `TGWFirewallPolicy`, letting a platform team carve out precise exceptions (e.g., "a shared-services VPC may reach any tenant VPC on port 443 only") on top of the coarser connectivity posture set by `VPCConnectivityProfile` (§3.11). It has its own on/off master switch: a `TGWFirewallPolicy` enforces nothing until the referenced Transit Gateway's `TGWSecurityConfig` enables the `GatewayFirewall` feature (§3.10).
- **`SecurityProfile`** is not itself an enforcement point but the cross-cutting object that controls *how* the above behave for a given VPC — specifically, whether the VPC's north-south (gateway) firewall is enabled at all (`northSouthFirewall.enabled`) and which east-west micro-segmentation strategy applies (`eastWestFirewall.securityStrategies`, e.g. `vpc-isolation`). It only takes effect once bound to a VPC via a separate `SecurityProfileAttachment` object — see §3.2. TCP-strict handshake enforcement (`tcpStrict`) is actually a per-policy field on each `FirewallPolicy`/`VPCGatewayFirewallPolicy`/`TGWFirewallPolicy`, not on `SecurityProfile`.

Automating "tenant vDefend security" in practice means automating these five resource kinds — declaratively, reviewably, in Git.

---

## 3. The vDefend Security Resources in `vpc.nsx.vmware.com/v1alpha1`

### 3.1 `NetworkSecurityGroup` / `VPCNetworkSecurityGroup` — the reusable "who"

The Kubernetes-native mirror of a Group: a named, reusable set of workloads or addresses, defined by membership criteria rather than static IPs. The verified schema splits this into **two** kinds, scoped differently, and each firewall kind reaches for the one that matches its own scope:

- **`NetworkSecurityGroup`** is scoped by a required `spec.regionName` (not a VPC). `FirewallPolicy` (east-west/DFW) and `TGWFirewallPolicy` (inter-VPC) rules reference these by name.
- **`VPCNetworkSecurityGroup`** is scoped by a required `spec.vpcName` instead. `VPCGatewayFirewallPolicy` (north-south perimeter) rules reference these instead of the region-scoped kind.

Both kinds share the same membership shape: static `ipAddresses[]` (single IPs, ranges, or CIDRs), static `vms[]` (by `instanceUUID`), dynamic `vmSelectors[]` / `podSelectors[]` (each a `labelSelector` and/or `namespaceSelector`, plus a VM-only `propertySelector` matching on `Name`/`OSName`/`ComputerName`), and nested group references (`networkSecurityGroupNames[]` or `vpcNetworkSecurityGroupNames[]`, respectively). There is no `memberSelector` wrapper object — these are all top-level `spec` fields.

```yaml
apiVersion: vpc.nsx.vmware.com/v1alpha1
kind: NetworkSecurityGroup
metadata:
  name: acme-app-tier
  namespace: acme-prod-ns01
spec:
  regionName: region-a
  vmSelectors:
    - labelSelector:
        matchLabels:
          tier: app
---
apiVersion: vpc.nsx.vmware.com/v1alpha1
kind: NetworkSecurityGroup
metadata:
  name: acme-corp-admin-cidrs
  namespace: acme-prod-ns01
spec:
  regionName: region-a
  ipAddresses:
    - "10.100.0.0/24"
---
apiVersion: vpc.nsx.vmware.com/v1alpha1
kind: VPCNetworkSecurityGroup
metadata:
  name: acme-web-tier-vpc
  namespace: acme-prod-ns01
spec:
  vpcName: acme-prod-vpc01
  vmSelectors:
    - labelSelector:
        matchLabels:
          tier: web
```

**Free namespace-scoped grouping via auto-tags.** VCF Automation automatically tags every VM's network interface with `kubernetes.io/metadata.name: <namespace name>` and `nsx-op/vm_namespace: <namespace name>` the moment it's deployed into a Supervisor Namespace — no manual labeling required. A `NetworkSecurityGroup` built on that tag captures the whole namespace, present and future, for free:

```yaml
apiVersion: vpc.nsx.vmware.com/v1alpha1
kind: NetworkSecurityGroup
metadata:
  name: prod01-namespace
spec:
  regionName: region-a
  vmSelectors:
    - labelSelector:
        matchLabels:
          nsx-op/vm_namespace: prod01-8sg7f
```

This is the cheapest possible day-0 isolation boundary: pair it with a two-rule `FirewallPolicy` (allow intra-namespace, `JumpToApplication`; deny everything else) to get "one namespace = one blast-radius" without hand-maintaining tier labels per VM. Confirmed limitations: this pattern does **not** work for VKS cluster nodes (they're grouped via separate, auto-generated tags instead) or for workloads attached to a *shared* VPC subnet rather than a dedicated one — check both before assuming a namespace-tag group covers 100% of a tenant's workloads.
### 3.2 `SecurityProfile` + `SecurityProfileAttachment` — the VPC's security posture

`SecurityProfile` is a standalone, `regionName`-scoped object — it does nothing on its own. A separate **`SecurityProfileAttachment`** object (`regionName` + `securityProfileName` + `vpcName`, all required) is what actually binds it to a VPC. `SecurityProfileSpec` itself controls VPC-wide enforcement behavior rather than individual rules: whether the north-south (gateway) firewall is enabled at all, and which east-west micro-segmentation strategy the VPC runs. There is no `tcpStrict` field here (that lives on each firewall policy kind, §3.3–3.5) and no IDS/IPS or Malware Prevention profile reference field in this API group.

```yaml
apiVersion: vpc.nsx.vmware.com/v1alpha1
kind: SecurityProfile
metadata:
  name: acme-security-profile
  namespace: acme-prod-ns01
spec:
  regionName: region-a
  isDefault: false                # required
  northSouthFirewall:
    enabled: true
  eastWestFirewall:
    securityStrategies:
      - vpc-isolation              # one of: none, vpc-isolation, vpc-secure-connection,
                                   # vpc-isolation-with-essential-services, vpc-external-connectivity
---
apiVersion: vpc.nsx.vmware.com/v1alpha1
kind: SecurityProfileAttachment
metadata:
  name: acme-security-profile-attachment
  namespace: acme-prod-ns01
spec:
  regionName: region-a
  securityProfileName: acme-security-profile
  vpcName: acme-prod-vpc01
```

**Confirmed from a running VCF 9.1 environment:** rather than hand-authoring `eastWestFirewall.securityStrategies` from scratch, VCF Automation ships one pre-created, system-owned `SecurityProfile` per named strategy — a tenant picks a posture by pointing their `SecurityProfileAttachment.spec.securityProfileName` at one of these, not by writing custom strategy values. `kubectl get securityprofiles` on a real region returns:

```
NAME                                    SECURITY STRATEGIES                    NORTHSOUTHFIREWALL ENABLED   AGE
default--m01-reg01                      none                                    false                        40d
system-security-profile-2--m01-reg01    vpc-isolation                           false                        40d
system-security-profile-3--m01-reg01    vpc-isolation-with-essential-services   false                        40d
system-security-profile-4--m01-reg01    vpc-external-connectivity               false                        40d
system-security-profile-5--m01-reg01    vpc-secure-connection                   false                        40d
```

and `kubectl get securityprofileattachments` shows which VPC is bound to which profile (a VPC that has never been re-pointed stays on the `default` profile — `vpc-isolation`, `vpc-isolation-with-essential-services`, etc. all start at zero VPCs applied):

```
NAME                REGION      VPC                       SECURITY PROFILE            AGE
default-m01-reg01   m01-reg01   default-m01-reg01         default--m01-reg01          40d
vpc-dev             m01-reg01   vpc-dev                    default--m01-reg01          12d
vpc-prod            m01-reg01   vpc-prod                   default--m01-reg01          12d
```

Day-2 changes are ordinary `kubectl patch` calls against these objects — useful as an imperative complement to the Terraform/Argo CD patterns in §4–§5, e.g. for a break-glass change or a quick lab test:

```bash
# Switch vpc-dev onto the "VPC Isolation" strategy
kubectl patch SecurityProfileAttachment vpc-dev -p \
  '{"spec":{"securityProfileName": "system-security-profile-2--m01-reg01"}}'

# Promote a different profile to be the region's default (isDefault: true)
kubectl patch SecurityProfile system-security-profile-4--m01-reg01 -p \
  '{"spec":{"isDefault": true}}'

# Turn on the VPC Gateway Firewall for whatever profile a VPC is bound to
kubectl patch SecurityProfile system-security-profile-4--m01-reg01 -p \
  '{"spec":{"northSouthFirewall": {"enabled": true}}}'
```

**Confirmed limitations worth building into any automation around this:**
- A `FirewallPolicy`/`VPCGatewayFirewallPolicy` generated by a `SecurityProfile` cannot be edited or have rules added to it directly. To customize behavior, author a **separate** policy with a higher-priority (lower `priority` number, or a `category` that evaluates earlier) that runs *before* the Security-Profile-generated one — never attempt to patch the generated policy in place.
- Essential-services rules generated by a profile (DNS/NTP/DHCP/ICMP) always allow both directions; this is not configurable per profile.
- Because every `SecurityProfile`-generated rule terminates in `JumpToApplication` rather than an explicit `Allow`, the `vpc-secure-connection` and `vpc-external-connectivity` strategies **fail closed**: if the tenant hasn't authored an explicit `Application`-category `FirewallPolicy` permitting the traffic, it's dropped by the time evaluation reaches the default rule — don't assume "external connectivity enabled" means traffic actually flows without a matching application-category allow rule.

### 3.3 `FirewallPolicy` — east-west (Distributed Firewall) rules

The general-purpose, intra-VPC micro-segmentation policy. Holds an ordered `rules[]` list; each rule's `from`/`to` are arrays of **single-peer objects** (`{ groupName: <NetworkSecurityGroup name> }` or `{ ipAddress: <CIDR/IP> }`), not flat string lists, and port/protocol matching nests under `services[].l4PortSet` (or a `networkServiceName` reference to a reusable `NetworkService` object) rather than sitting flat on the rule.

```yaml
apiVersion: vpc.nsx.vmware.com/v1alpha1
kind: FirewallPolicy
metadata:
  name: acme-tier-isolation
  namespace: acme-prod-ns01
spec:
  regionName: region-a           # required
  category: Application          # Infrastructure | Environment | Application
  stateful: true
  tcpStrict: true
  rules:
    - name: allow-web-to-app
      direction: In
      action: Allow
      from:
        - groupName: acme-web-tier
      to:
        - groupName: acme-app-tier
      services:
        - l4PortSet:
            l4Protocol: TCP
            destinationPorts: ["8443"]
    - name: deny-all-app-inbound
      direction: In
      action: Drop
      to:
        - groupName: acme-app-tier
```

### 3.4 `VPCGatewayFirewallPolicy` — north-south perimeter rules

Same rule shape as `FirewallPolicy` (`from`/`to`/`services` all identical), but scoped to the VPC's own gateway rather than to workload vNICs, and it references **`VPCNetworkSecurityGroup`** (not `NetworkSecurityGroup`) in its `groupName` peers. Both `spec.regionName` and `spec.vpcName` are required — easy to miss since they carry no default.

```yaml
apiVersion: vpc.nsx.vmware.com/v1alpha1
kind: VPCGatewayFirewallPolicy
metadata:
  name: acme-perimeter
  namespace: acme-prod-ns01
spec:
  regionName: region-a            # required
  vpcName: acme-prod-vpc01        # required
  category: LocalGatewayRules     # LocalGatewayRules | Default
  rules:
    - name: allow-inbound-https
      direction: In
      action: Allow
      to:
        - groupName: acme-web-tier-vpc   # a VPCNetworkSecurityGroup
      services:
        - l4PortSet:
            l4Protocol: TCP
            destinationPorts: ["443"]
    - name: deny-all-other-inbound
      direction: In
      action: Drop
```

### 3.5 `TGWFirewallPolicy` — inter-VPC rules on a shared Transit Gateway

Applies where a tenant's (or the platform's) VPCs are attached to a common Transit Gateway and need finer control than the blunt Community/Isolated/Promiscuous connectivity posture. **There is no `spec.transitGateway` field** — the verified schema has no such reference on `TGWFirewallPolicySpec`. Instead, a rule scopes itself to a specific Transit Gateway attachment through its own `appliedTo.gatewayAttachmentNames[]` / `gatewayNames[]` (fields that only apply to this policy kind; `appliedTo.groupNames[]` is the Distributed-Firewall-only equivalent). Groups referenced in `from`/`to` here are the region-scoped `NetworkSecurityGroup`, same as `FirewallPolicy`. Note this capability requires the appropriate vDefend/Advanced Cyber Compliance licensing tier.

```yaml
apiVersion: vpc.nsx.vmware.com/v1alpha1
kind: TGWFirewallPolicy
metadata:
  name: acme-shared-services-access
  namespace: acme-prod-ns01
spec:
  regionName: region-a            # required
  category: Default                # LocalGatewayRules | Default
  rules:
    - name: allow-shared-services-to-acme
      direction: In
      action: Allow
      appliedTo:
        gatewayAttachmentNames: [acme-prod-tgw-attachment]
      from:
        - groupName: shared-services-vpc-egress
      to:
        - groupName: acme-app-tier
      services:
        - l4PortSet:
            l4Protocol: TCP
            destinationPorts: ["443"]
    - name: deny-other-vpcs
      direction: In
      action: Drop
```

### 3.6 How the kinds compose

```
NetworkSecurityGroup (regionName)     ──referenced by──▶  FirewallPolicy (east-west, intra-VPC)
                                                            TGWFirewallPolicy (east-west, inter-VPC)

VPCNetworkSecurityGroup (vpcName)     ──referenced by──▶  VPCGatewayFirewallPolicy (north-south)

NetworkService                        ──referenced by──▶  any rule's services[] (all three firewall kinds)

SecurityProfile  ──bound to a VPC via──▶  SecurityProfileAttachment  ──governs posture of──▶  that VPC

TGWSecurityConfig (GatewayFirewall: true)  ──gates enforcement of──▶  TGWFirewallPolicy

VPCConnectivityProfile  ──bound to a Project via──▶  VPCConnectivityProfileBinding  ──sets IP/NAT/TGW posture of──▶  that Project's VPCs
```

A group object is the only thing the three firewall-policy kinds *require* to express meaningful rules; `SecurityProfile` is orthogonal, and inert until attached. In practice, a tenant onboarding baseline creates one `SecurityProfile` plus its `SecurityProfileAttachment`, a handful of `NetworkSecurityGroup`/`VPCNetworkSecurityGroup` objects (one per application tier or trust zone, matching the policy kind that will reference them), a default-deny `FirewallPolicy` and `VPCGatewayFirewallPolicy`, and adds `TGWFirewallPolicy` (plus a `TGWSecurityConfig` enabling it) only if the tenant's architecture spans multiple VPCs. §3.7–§3.12 cover the remaining supporting kinds — reusable service definitions, realized-membership visibility, rule-template bundles, and connectivity/capability posture — and how each fits into an automation pipeline.

### 3.7 `NetworkService` — reusable service/port definitions

A named, reusable match for protocol/port combinations, referenced from any rule's `services[]` via `networkServiceName` instead of inlining an `l4PortSet` every time. `NetworkServiceSpec.serviceEntries[]` accepts exactly one of five shapes per entry: `l4PortSet` (TCP/UDP + ports), `icmp` (`icmpType`/`icmpCode`/`protocol`), `ipProtocol` (`protocolNumber`, for matching raw IP protocols beyond TCP/UDP/ICMP), `alg` (Application Layer Gateway protocols), or `igmp` (no extra properties).

```yaml
apiVersion: vpc.nsx.vmware.com/v1alpha1
kind: NetworkService
metadata:
  name: platform-https
  namespace: acme-prod-ns01
spec:
  description: "Standard HTTPS"
  serviceEntries:
    - l4PortSet:
        l4Protocol: TCP
        destinationPorts: ["443"]
```

```yaml
      services:
        - networkServiceName: platform-https
```

**Automation use:** define a small, platform-owned library of `NetworkService` objects (`platform-https`, `platform-mysql`, `internal-dns`, …) once in a shared Git path, and have every tenant `FirewallPolicy`/`VPCGatewayFirewallPolicy`/`TGWFirewallPolicy` rule reference them by name. A port change becomes a one-line PR against the shared library instead of a grep-and-replace across every tenant's rule set.

### 3.8 `NetworkSecurityGroupIPMembers` / `VPCNetworkSecurityGroupIPMembers` — realized membership (read-only)

Read-only subresources — no `spec`, just a top-level `ipAddresses[]` — that report the IPs a group's selectors *actually* resolved to right now. They exist because `vmSelectors`/`podSelectors` are dynamic: a typo'd `matchLabels` value silently resolves to zero members, leaving a rule that references the group with no effective peers and no error anywhere.

```bash
kubectl get networksecuritygroupipmembers acme-app-tier -n acme-prod-ns01 -o yaml
kubectl get vpcnetworksecuritygroupipmembers acme-web-tier-vpc -n acme-prod-ns01 -o yaml
```

**Automation use:** add a post-apply validation step to the CI/CD pipeline — after applying a `NetworkSecurityGroup`/`VPCNetworkSecurityGroup` change, read the matching `IPMembers` subresource and assert it's non-empty (or matches an expected count) *before* promoting the paired `FirewallPolicy`/`VPCGatewayFirewallPolicy` change that references it. This turns a silent "selector matched nothing" mistake into a failed pipeline step instead of a production outage discovered later.

### 3.9 `SecurityStrategy` — reusable rule-template bundles

`SecurityStrategySpec` holds `description` plus `ruleTemplates[]` — an array in the **same shape** as a `FirewallPolicy` rule (`action`, `appliedTo`, `direction`, `from[]`, `to[]`, `services[]`, `isDefault`, `tag`, …). This looks purpose-built for defining a reusable, named bundle of firewall rules once and applying it consistently.

> **Open question, verify before automating around it:** the reference doesn't document a field on `SecurityProfile`, `FirewallPolicy`, or any other kind that binds a `SecurityStrategy` object by name. `SecurityProfileSpec.eastWestFirewall.securityStrategies[]` (§3.2) instead takes fixed strings (`none`, `vpc-isolation`, `vpc-secure-connection`, `vpc-isolation-with-essential-services`, `vpc-external-connectivity`) that read like built-in system identifiers, not references to user-authored `SecurityStrategy` objects. A real VCF 9.1 environment strengthens this suspicion: it ships exactly five pre-created, **system-owned** `SecurityProfile` objects (`system-security-profile-2` through `-5`, plus `default`), one per named strategy — a tenant consumes a strategy by pointing `SecurityProfileAttachment` at the matching system profile (§3.2), not by authoring a `SecurityStrategy` object. Before designing a Terraform module around custom `SecurityStrategy` objects, confirm in your own environment (`kubectl get securitystrategy -A`, and whether creating a new one actually changes anything) whether this kind is currently consumer-facing or purely system-internal plumbing behind those five fixed strategies.

**Automation use (once confirmed live):** one `SecurityStrategy` per compliance baseline (e.g. `pci-dfw-baseline`), owned and versioned by the security team, referenced by name from every tenant's `SecurityProfile` instead of copy-pasting the same baseline rules into each tenant's `FirewallPolicy`.

### 3.10 `TGWSecurityConfig` — the Transit Gateway firewall on/off switch

A subresource of `TransitGateway`: `spec.features[]` is a list of `{ name, enabled }` pairs, where the only documented `name` value is `GatewayFirewall`. This is the master switch — a `TGWFirewallPolicy` (§3.5) enforces nothing on a given Transit Gateway until that gateway's `TGWSecurityConfig` has `GatewayFirewall: enabled: true`, the same way a `SecurityProfile` is inert until attached via `SecurityProfileAttachment` (§3.2).

```yaml
apiVersion: vpc.nsx.vmware.com/v1alpha1
kind: TGWSecurityConfig
metadata:
  name: corp-shared-tgw-security-config
  namespace: acme-prod-ns01
spec:
  features:
    - name: GatewayFirewall
      enabled: true
```

**Automation use:** this is a day-0, platform-Terraform-owned object — provisioned once alongside the shared `TransitGateway`/`TGWAttachment`, not per-tenant. Add a pre-merge check to the tenant GitOps pipeline that rejects a `TGWFirewallPolicy` PR if the target gateway's `TGWSecurityConfig.spec.features[name=GatewayFirewall].enabled` isn't already `true` — otherwise the rules merge cleanly and silently do nothing.

### 3.11 `VPCConnectivityProfile` / `VPCConnectivityProfileBinding` — VPC north-south connectivity posture

`VPCConnectivityProfileSpec` governs a VPC's outward connectivity: `externalIPBlockNames[]`, `privateTGWIPBlockNames[]`, `transitGatewayName`, `regionName` (required), `isDefault`, and `serviceGateway` (`enable` + `natConfig.{autoSNATIPBlockName, enableDefaultSNAT}`). `VPCConnectivityProfileBinding` is what makes a profile usable — it binds a named `VPCConnectivityProfile` to a Project/namespace via `spec.vpcConnectivityProfileName` (required), after which that Project's VPCs can use it.

**Correction vs. earlier drafts of this paper:** despite being the object most associated with "VPC connectivity posture," this schema version has **no explicit isolation-mode field** here (no `Community`/`Isolated`/`Promiscuous`-style enum on `VPCConnectivityProfileSpec`). That kind of default-connectivity toggle more likely lives on `FirewallPolicySpec.connectivityPreference`/`applicationConnectivityStrategy` instead (§3.3) — but those enum values aren't documented either, so verify directly rather than assuming either placement.

```yaml
apiVersion: vpc.nsx.vmware.com/v1alpha1
kind: VPCConnectivityProfile
metadata:
  name: acme-external-connectivity
  namespace: acme-prod-ns01
spec:
  regionName: region-a
  transitGatewayName: corp-shared-tgw
  externalIPBlockNames: [corp-external-ipblock]
  serviceGateway:
    enable: true
    natConfig:
      enableDefaultSNAT: true
---
apiVersion: vpc.nsx.vmware.com/v1alpha1
kind: VPCConnectivityProfileBinding
metadata:
  name: acme-connectivity-binding
  namespace: acme-prod-ns01
spec:
  vpcConnectivityProfileName: acme-external-connectivity
```

**Automation use:** platform-owned, Terraform, day-0. Maintain a small, fixed set of standard connectivity profiles (`internet-facing`, `internal-only`, `shared-services-attached`) centrally, and let each tenant Project simply bind to one via `VPCConnectivityProfileBinding` rather than hand-rolling IP-block/NAT/Transit-Gateway settings per tenant.

### 3.12 `RegionNetworkingCapabilities` — capability discovery for automation gating

Read-only, one object per Region: a top-level `capabilities[]` array of `{ type, state, reason, message }`, e.g. an older region might report `{"type": "IPSecVPN", "state": false, "reason": "UnsupportedByNSXVersion"}`.

**Automation use:** a pre-flight check — in a Terraform data source lookup or a CI/CD pipeline step — before generating manifests that depend on a specific capability (a `TGWFirewallPolicy`, an `IPSecVPN`, etc.) in a given region. Reading `RegionNetworkingCapabilities` first and failing fast with a clear message beats letting the `apply` fail deep inside backend reconciliation because the target region doesn't support the feature yet.

---

## 4. Automation Pattern A — Terraform

### 4.1 Why Terraform here

Terraform fits naturally where tenant security config is provisioned **as part of** environment stand-up — e.g., a "new tenant" pipeline that creates the Project, VPC, Subnets, quotas, and the baseline `SecurityProfile`/`NetworkSecurityGroup`/default-deny `FirewallPolicy`/`VPCGatewayFirewallPolicy` set in one atomic `apply`, with the safety of `plan` review and state-tracked drift detection.

### 4.2 Provider chain

VCF Automation 9 exposes three complementary Terraform providers. For vDefend automation, two matter:

- **`vcfa`** — provider-admin-level operations (orgs, regions, quotas) and, critically, a `vcfa_kubeconfig` data source that mints CCI credentials.
- **`kubernetes`** (HashiCorp's standard provider) — applies raw manifests (`kubernetes_manifest`) against the CCI API server for anything CCI exposes as a CRD, including every `vpc.nsx.vmware.com/v1alpha1` object.

```hcl
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
```

### 4.3 Declaring a tenant's baseline security posture

```hcl
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
```

### 4.4 Module design and state strategy for multi-tenant scale

- **One Terraform workspace/state per tenant Project**, keyed by tenant ID — never a single monolithic state file spanning tenants. This bounds blast radius: a bad `apply` for one tenant can't corrupt another's state, and it lets you parallelize pipelines.
- Wrap the resources above in a `tenant-vdefend-baseline` module with variables for tier labels, allowed ports, and default-deny posture, versioned in a shared module registry so every tenant onboarding starts from the same vetted security baseline.
- Once Argo CD (§5) takes ownership of a resource's steady-state reconciliation, stop managing that same object from Terraform to avoid field-ownership fights — see §6.

---

## 5. Automation Pattern B — Argo CD (GitOps)

### 5.1 Why GitOps here

Security policy is not "set once at provisioning" — it changes continuously as tenant applications evolve (new microservice, new port, decommissioned tier). Argo CD's continuous reconciliation loop means:

- **Drift correction**: if someone manually edits a `FirewallPolicy` or `NetworkSecurityGroup` via `kubectl` or the CCI UI, Argo CD reverts it (or flags `OutOfSync`) on the next sync — Git remains the enforceable source of truth for security posture, which auditors and compliance frameworks (PCI-DSS, ISO 27001, SOC 2) care about.
- **Self-service without a pipeline run**: tenant security engineers merge a PR against their tenant's policy repo; Argo CD picks it up within its poll/webhook interval — no separate CI job needs to hold cloud credentials.
- **Native multi-tenant fan-out** via `ApplicationSet`, generating one Argo CD `Application` per tenant from a single template.

### 5.2 Registering the tenant's Supervisor Namespace as an Argo CD target

Each tenant's CCI kubeconfig (obtained once, out-of-band or via the same `vcfa_kubeconfig` Terraform data source used for bootstrapping) is registered as an Argo CD cluster secret, scoped so Argo CD's service account only has RBAC (via `authorization.cci.vmware.com`) within that tenant's namespace(s) — never cluster-admin on the shared Supervisor.

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: acme-prod-cci-cluster
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
type: Opaque
stringData:
  name: acme-prod-supervisor-ns
  server: https://cci.vcfa.example.com
  config: |
    {
      "bearerToken": "<scoped-service-account-token>",
      "tlsClientConfig": { "insecure": false, "caData": "<base64-ca>" }
    }
```

### 5.3 Per-tenant Application via ApplicationSet

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: tenant-vdefend-policies
  namespace: argocd
spec:
  generators:
    - list:
        elements:
          - tenant: acme
            namespace: acme-prod-ns01
            cluster: acme-prod-supervisor-ns
          - tenant: globex
            namespace: globex-prod-ns01
            cluster: globex-prod-supervisor-ns
  template:
    metadata:
      name: "{{tenant}}-vdefend-policy"
    spec:
      project: tenant-security
      source:
        repoURL: https://git.example.com/platform/tenant-security-policies.git
        targetRevision: main
        path: "tenants/{{tenant}}/security-policy"
      destination:
        name: "{{cluster}}"
        namespace: "{{namespace}}"
      syncPolicy:
        automated:
          prune: true      # remove groups/policies deleted from Git
          selfHeal: true    # revert manual/out-of-band drift
        syncOptions:
          - CreateNamespace=false   # namespace lifecycle stays with Terraform, not GitOps
```

`tenants/acme/security-policy/` in Git contains plain `NetworkSecurityGroup` / `FirewallPolicy` / `VPCGatewayFirewallPolicy` / `TGWFirewallPolicy` YAML — the shapes shown in §3 — reviewed via standard pull request workflow, ideally with a `CODEOWNERS` entry requiring the tenant's security lead to approve changes to their own policy.

### 5.4 Ordering and safety

- Use `argocd.argoproj.io/sync-wave` annotations to guarantee `NetworkSecurityGroup` objects (wave 0) and the default-deny `FirewallPolicy`/`VPCGatewayFirewallPolicy` (wave 1) land before more permissive tier-specific allow rules (wave 2+) — groups must exist before a policy can reference them, and a default-deny baseline should never trail its allow rules into the cluster.
- Run Argo CD in **non-selfHeal, manual-sync mode for a probation period** on newly onboarded tenants, flipping to `automated.selfHeal: true` once the baseline policy has been validated in a lower environment — this gives a soft rollout path for a capability that can otherwise instantly enforce a mistake fleet-wide.

---

## 6. Terraform vs. Argo CD: Decision Framework

| Dimension | Terraform | Argo CD (GitOps) |
|---|---|---|
| Best for | Day-0 tenant/VPC provisioning, one-shot baseline | Day-2 continuous security policy management |
| Reconciliation | On-demand (`apply`) | Continuous (default poll ~3 min, or webhook-driven) |
| Drift handling | Detected at next `plan`; requires a pipeline run to fix | Auto-corrected (`selfHeal`) or flagged in near-real-time |
| Ownership model | Terraform state file per tenant | Git repo path per tenant; K8s is desired-state store |
| Credential exposure | CI runner needs tenant CCI token during `apply` | Argo CD holds long-lived scoped token; no per-change CI credential minting |
| Tenant self-service UX | PR → pipeline run → apply (slower, gated) | PR → merge → auto-sync (faster, still gated by review) |
| Blast-radius control | Per-tenant state + `plan` review | Per-tenant `Application`/`AppProject` RBAC + `syncPolicy` |
| Fits multi-cloud IaC standard | Yes, if org is already Terraform-first | GitOps-first orgs / platform teams running Kubernetes elsewhere too |

**Recommended hybrid**: Terraform owns the tenant *shell* (Project, VPC, Subnet, quotas, RBAC bindings, initial `SecurityProfile`, and a default-deny `FirewallPolicy`/`VPCGatewayFirewallPolicy`) as part of the onboarding pipeline. Once the tenant exists, hand off ongoing `NetworkSecurityGroup`, `FirewallPolicy`, `VPCGatewayFirewallPolicy`, and `TGWFirewallPolicy` lifecycle to Argo CD, pointed at a tenant-owned Git path. Never let both tools manage the *same* object — pick one owner per resource to avoid field-ownership flapping (Terraform reverting an Argo-applied change on next `apply`, or vice versa).

---

## 7. Reference Architecture

```
┌─────────────────────────────┐        ┌──────────────────────────────┐
│  Platform Team Git Repo      │        │  Tenant Security Git Repo     │
│  (tenant onboarding module)  │        │  (per-tenant NSG/FirewallPolicy│
│                               │        │   /VPCGatewayFW/TGWFW)        │
└──────────────┬───────────────┘        └───────────────┬────────────────┘
               │ terraform apply                          │ merge → auto-sync
               ▼                                          ▼
   ┌───────────────────────┐                  ┌───────────────────────┐
   │   CI Pipeline (TF)     │                  │      Argo CD          │
   │  vcfa + kubernetes     │                  │  ApplicationSet /     │
   │  providers             │                  │  per-tenant App       │
   └───────────┬────────────┘                  └───────────┬────────────┘
               │                                            │
               └───────────────────┬────────────────────────┘
                                    ▼
                     ┌─────────────────────────────────┐
                     │   VCF Automation — CCI API       │
                     │  project.cci.vmware.com          │
                     │  infrastructure.cci.vmware.com   │
                     │  vpc.nsx.vmware.com/v1alpha1:     │
                     │   NetworkSecurityGroup            │
                     │   SecurityProfile                 │
                     │   FirewallPolicy                  │
                     │   VPCGatewayFirewallPolicy         │
                     │   TGWFirewallPolicy                │
                     └───────────────┬───────────────────┘
                                    ▼
                     ┌───────────────────────────────┐
                     │   VCF Networking control plane │
                     │   → vDefend enforcement:       │
                     │     Distributed FW (E-W/intra) │
                     │     VPC Gateway FW (N-S)       │
                     │     Transit GW FW (E-W/inter)  │
                     └───────────────┬─────────────────┘
                                    ▼
                     ┌───────────────────────────────┐
                     │  Tenant Workloads               │
                     │  (VMs / vSphere Pods / VKS)      │
                     └───────────────────────────────┘
```

---

## 8. Worked Example: Onboarding a 3-Tier Tenant Application

**Scenario**: Tenant `acme` needs a `web` / `app` / `db` three-tier application with default-deny micro-segmentation and a locked-down perimeter, permitting only public HTTPS to the web tier, `web → app:8443`, and `app → db:5432`.

**Step 1 (Terraform, onboarding pipeline)** — create the Project, VPC, Subnet, baseline `SecurityProfile`/`SecurityProfileAttachment`, tier `NetworkSecurityGroup`/`VPCNetworkSecurityGroup` objects, and default-deny `FirewallPolicy`/`VPCGatewayFirewallPolicy` (extends §4.3):

```hcl
resource "kubernetes_manifest" "default_deny_east_west" {
  manifest = {
    apiVersion = "vpc.nsx.vmware.com/v1alpha1"
    kind       = "FirewallPolicy"
    metadata = {
      name      = "acme-default-deny"
      namespace = "acme-prod-ns01"
    }
    spec = {
      regionName = var.region_name
      category   = "Application"
      stateful   = true
      rules = [
        { name = "deny-all-in", direction = "In", action = "Drop" },
        { name = "deny-all-out", direction = "Out", action = "Drop" }
      ]
    }
  }
}
```

**Step 2 (handoff)** — pipeline opens/merges a PR into `tenants/acme/security-policy/` in the tenant security repo containing the tier-specific groups and allow rules (§3 / §5.3), and registers `acme`'s namespace as an Argo CD `ApplicationSet` element (§5.3).

`tenants/acme/security-policy/groups.yaml`:

```yaml
apiVersion: vpc.nsx.vmware.com/v1alpha1
kind: NetworkSecurityGroup
metadata:
  name: acme-web-tier
  namespace: acme-prod-ns01
spec:
  regionName: region-a
  vmSelectors:
    - labelSelector:
        matchLabels: { tier: web }
---
apiVersion: vpc.nsx.vmware.com/v1alpha1
kind: NetworkSecurityGroup
metadata:
  name: acme-app-tier
  namespace: acme-prod-ns01
spec:
  regionName: region-a
  vmSelectors:
    - labelSelector:
        matchLabels: { tier: app }
---
apiVersion: vpc.nsx.vmware.com/v1alpha1
kind: NetworkSecurityGroup
metadata:
  name: acme-db-tier
  namespace: acme-prod-ns01
spec:
  regionName: region-a
  vmSelectors:
    - labelSelector:
        matchLabels: { tier: db }
---
apiVersion: vpc.nsx.vmware.com/v1alpha1
kind: VPCNetworkSecurityGroup
metadata:
  name: acme-web-tier-vpc
  namespace: acme-prod-ns01
spec:
  vpcName: acme-prod-vpc01
  vmSelectors:
    - labelSelector:
        matchLabels: { tier: web }
```

`acme-web-tier-vpc` is a separate `VPCNetworkSecurityGroup` mirroring `acme-web-tier` — `VPCGatewayFirewallPolicy` rules can't reference the region-scoped `NetworkSecurityGroup` kind (§3.1).

`tenants/acme/security-policy/perimeter.yaml`:

```yaml
apiVersion: vpc.nsx.vmware.com/v1alpha1
kind: VPCGatewayFirewallPolicy
metadata:
  name: acme-perimeter
  namespace: acme-prod-ns01
spec:
  regionName: region-a
  vpcName: acme-prod-vpc01
  category: LocalGatewayRules
  rules:
    - name: allow-inbound-https
      direction: In
      action: Allow
      to:
        - groupName: acme-web-tier-vpc
      services:
        - l4PortSet:
            l4Protocol: TCP
            destinationPorts: ["443"]
    - name: deny-all-other-inbound
      direction: In
      action: Drop
```

`tenants/acme/security-policy/tier-isolation.yaml`:

```yaml
apiVersion: vpc.nsx.vmware.com/v1alpha1
kind: FirewallPolicy
metadata:
  name: acme-tier-isolation
  namespace: acme-prod-ns01
spec:
  regionName: region-a
  category: Application
  rules:
    - name: allow-web-to-app
      direction: In
      action: Allow
      from:
        - groupName: acme-web-tier
      to:
        - groupName: acme-app-tier
      services:
        - l4PortSet:
            l4Protocol: TCP
            destinationPorts: ["8443"]
    - name: allow-app-to-db
      direction: In
      action: Allow
      from:
        - groupName: acme-app-tier
      to:
        - groupName: acme-db-tier
      services:
        - l4PortSet:
            l4Protocol: TCP
            destinationPorts: ["5432"]
```

**Step 3 (day-2, tenant-driven)** — Acme's app team adds a `cache` tier. Their security engineer opens a PR adding a new `NetworkSecurityGroup` (`acme-cache-tier`) and a rule to `tier-isolation.yaml`:

```yaml
    - name: allow-app-to-cache
      direction: In
      action: Allow
      from:
        - groupName: acme-app-tier
      to:
        - groupName: acme-cache-tier
      services:
        - l4PortSet:
            l4Protocol: TCP
            destinationPorts: ["6379"]
```

Once merged and approved by the `CODEOWNERS`-designated security lead, Argo CD syncs it — no Terraform run, no platform team ticket, and the default-deny `FirewallPolicy` and locked-down `VPCGatewayFirewallPolicy` still govern anything not explicitly matched.

**Optional Step 4 (multi-VPC tenants)** — if Acme later splits into a `prod` VPC and a `shared-services` VPC on a common Transit Gateway, a `TGWFirewallPolicy` (§3.5) is added to allow only the specific east-west paths needed between them, rather than relying on the coarser Community/Isolated/Promiscuous connectivity posture.

---

## 9. Governance, Guardrails, and Operational Guidance

- **Guardrails precede self-service.** Provider admins set `infrastructure.cci.vmware.com` quotas (network CIDR ranges, VPC/subnet counts) and `authorization.cci.vmware.com` RBAC *before* handing a tenant Project autonomy over `NetworkSecurityGroup`/`FirewallPolicy` objects — this is what makes "tenant self-service security" safe rather than reckless.
- **Least privilege for automation identities.** The Terraform CI runner's CCI token and Argo CD's cluster secret should each be scoped (via `authorization.cci.vmware.com` `RoleBinding`s) to only the tenant namespace(s) they manage — never a Project-wide or Region-wide credential.
- **Policy review is code review.** Route `FirewallPolicy`/`VPCGatewayFirewallPolicy`/`TGWFirewallPolicy` PRs through the same review gates as application code — `CODEOWNERS`, required approvals from a security lead, and (where available) a policy-linting CI step that rejects rules without an explicit `direction`/`action`/port scope, or that reference a `NetworkSecurityGroup` not defined anywhere in the repo.
- **Dry-run before merge.** Where supported, validate manifests with `kubectl apply --dry-run=server` or `terraform plan` against a non-production tenant namespace before promoting to production tenants — catches schema drift between API versions early.
- **Audit trail = Git history.** Because both patterns terminate in Git-reviewed changes, `git log` on the tenant security repo (or Terraform module) becomes your compliance evidence trail for "who approved this firewall change and when" — a materially stronger artifact than point-and-click console audit logs alone.
- **Feed enforcement telemetry back into the loop.** vDefend's IDS/IPS and Malware Prevention detections should inform future `FirewallPolicy` tightening — treat detected-but-not-yet-blocked lateral movement attempts as backlog items for the next policy PR.
- **Watch the TGW blast radius.** `TGWFirewallPolicy` changes can affect traffic between multiple tenants' VPCs if they share a Transit Gateway — route these through the platform team's `AppProject`/module rather than granting individual tenants write access to this kind, and confirm the gateway's `TGWSecurityConfig` (§3.10) already has `GatewayFirewall` enabled before merging.
- **Validate realized membership before trusting a rule.** A `NetworkSecurityGroup`/`VPCNetworkSecurityGroup` selector that matches nothing fails silently — no error, just a rule with no effective peers. Add a CI step that reads the group's `IPMembers` subresource (§3.8) after apply and fails the pipeline if it's unexpectedly empty, before the paired firewall policy change is allowed to merge.
- **Never edit a `SecurityProfile`-generated policy in place.** Its rules aren't meant to be patched or appended to; per §3.2, the supported customization path is a *separate*, higher-priority policy that runs before it — build that expectation into `CODEOWNERS`/linting so a reviewer doesn't approve a diff against the generated policy itself.

**Known platform limitations to design around (current as of VCF 9.1), not bugs to work around silently:**
- `VPCGatewayFirewallPolicy`/`VPCNetworkSecurityGroup` objects are not visible or usable from inside a Project's Supervisor context the way `NetworkSecurityGroup` is — don't assume VPC-scoped groups are reachable from every automation surface a tenant touches.
- The namespace auto-tag grouping pattern (§3.1) does not work for VKS cluster nodes or for workloads on a *shared* VPC subnet — plan a separate grouping strategy (auto-generated tags, or explicit labels) for those workloads rather than assuming one `NetworkSecurityGroup` pattern covers a whole tenant.
- Custom `NetworkService` creation has been observed to reject at least some arbitrary TCP ports (e.g. the Kubernetes API's `6443`) in current builds — verify a custom `NetworkService` actually applies before depending on it in a pipeline, rather than assuming any port/protocol combination is definable.

---

## 10. Conclusion

VCF Automation's CCI turns vDefend tenant security from a point-and-click, console-driven process into ordinary Kubernetes custom resources under `vpc.nsx.vmware.com/v1alpha1` — `NetworkSecurityGroup`/`VPCNetworkSecurityGroup` for reusable workload membership, `SecurityProfile`/`SecurityProfileAttachment` for VPC-wide enforcement posture, `FirewallPolicy` / `VPCGatewayFirewallPolicy` / `TGWFirewallPolicy` for the three real enforcement points (intra-VPC east-west, per-VPC north-south, and inter-VPC east-west, respectively), and a set of supporting kinds — `NetworkService`, the `IPMembers` subresources, `SecurityStrategy`, `TGWSecurityConfig`, and `VPCConnectivityProfile`/`VPCConnectivityProfileBinding` — that round out reuse, validation, and connectivity posture around them (§3.7–§3.12). That single fact is what unlocks both Terraform and Argo CD as first-class automation paths without any custom tooling. Use Terraform for atomic, reviewed, day-0 tenant and baseline-policy provisioning; use Argo CD for continuous, self-healing, Git-driven day-2 policy management; and draw a hard ownership line between the two so they never fight over the same object. Combined with quota- and RBAC-based guardrails set by the provider team, this gives tenants real self-service over their own micro-segmentation posture — without giving up centralized governance, auditability, or the ability to prove compliance from Git history alone.

---

## References

- Broadcom Developer Portal — [CCI API Reference (`xapis/cci-api`, `vpc.nsx.vmware.com/v1alpha1`)](https://developer.broadcom.com/xapis/cci-api/latest/api-docs.html#k8s-api-vpc-nsx-vmware-com-v1alpha1)
- Broadcom TechDocs — [Firewall Policies in an NSX VPC](https://techdocs.broadcom.com/us/en/vmware-cis/nsx/vmware-nsx/9-0/administration-guide/nsx-multi-tenancy/nsx-virtual-private-clouds/firewall-policies-in-an-nsx-vpc.html)
- Broadcom TechDocs — [Groups in an NSX VPC](https://techdocs.broadcom.com/us/en/vmware-cis/nsx/vmware-nsx/4-2/administration-guide/nsx-multi-tenancy/nsx-virtual-private-clouds/groups-in-an-nsx-vpc.html)
- Broadcom TechDocs — [View VPC Security Profile Status](https://techdocs.broadcom.com/us/en/vmware-security-load-balancing/vdefend/vdefend-firewall/9-0/secure-vpc-projects/vpc-security-key-concepts/view-vpc-security-profile-status.html)
- Broadcom TechDocs — [Virtual Private Cloud in NSX (VCF 9.0/9.1)](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-9-0-and-later/9-0/advanced-network-management/administration-guide/virtual-private-cloud-in-nsx.html)
- VMware Cloud Foundation Blog — [VMware Virtual Private Cloud in VCF 9.0](https://blogs.vmware.com/cloud-foundation/2025/07/02/vmware-virtual-private-cloud/)
- VMware Cloud Foundation Blog — [VCF Automation IaC: Cloud Consumption Interface (CCI)](https://blogs.vmware.com/cloud-foundation/2024/11/05/vmware-cloud-foundation-vcf-automation-infrastructure-as-code-iac-cloud-consumption-interface-cci/)
- VMware Cloud Foundation Blog — [VCF 9.1 Networking: Simpler VPC Connectivity Control](https://blogs.vmware.com/cloud-foundation/2026/05/15/vcf-networking-9-1-simpler-vpc-connectivity-control/)
- sdn-warrior.org — [VCF 9 – NSX VPC Part 3: Security](https://sdn-warrior.org/posts/vcf9-nsx-vpc-part3/)
- sdn-warrior.org — [VCF 9.1 – VPCs Connectivity Policies](https://sdn-warrior.org/posts/vcf9.1-vpcs-connectivity-policy/)
- Broadcom TechDocs — [Kubernetes API Reference for the Cloud Consumption Interface](https://techdocs.broadcom.com/us/en/vmware-cis/aria/aria-automation/8-18/consumption-on-prem-using-master-map-8-18/working-with-the-cloud-consumption-interface/other-cci-command-line-interface-options/supervisor-namespaces-cloud-consumption-interface-kubernetes-api-reference.html)
- Broadcom TechDocs — [Overview of IDS/IPS and Malware Prevention for vDefend](https://techdocs.broadcom.com/us/en/vmware-security-load-balancing/vdefend/vdefend-atp/4-2/nsx-ids-ips-and-nsx-malware-prevention/nsx-ids-ips-and-nsx-malware-prevention/getting-started-with-nsx-ids-ips-and-nsx-malware-prevention/overview-of-nsx-ids-ips-and-nsx-malware-prevention.html)
- vrealize.it — [VCF Automation 9: New Terraform Providers for All-Apps-Org](https://vrealize.it/2025/08/07/vcf-automation-9-new-terraform-providers-for-all-apps-org/)
- William Lam — [Automating VCFA Configuration using the VCFA Terraform Provider](https://williamlam.com/2025/10/automating-vcf-automation-vcfa-configuration-using-vcfa-terraform-provider.html)
- HashiCorp / VMware — [Terraform Provider for VMware Aria Automation / VCF Automation (`vra`)](https://github.com/vmware/terraform-provider-vra)
