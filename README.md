# Accelerating Secure App Deployments in VCF with vDefend

**Delivering Out-of-the-Box, Self-Service Security in Multi-Tenant Cloud Environments**

---

## Abstract

**VMware vDefend** is the security suite built directly into VMware Cloud Foundation (VCF) 9 — Distributed Firewall micro-segmentation, VPC Gateway Firewall, Transit Gateway Firewall, IDS/IPS, and Advanced Threat Prevention, enforced at every layer around a workload. The dilemma every private cloud eventually hits is the tension between rapid application delivery and a stringent, zero-trust security posture: DevOps wants self-service in minutes, security wants every rule reviewed and every tenant isolated. VCF integrated with vDefend resolves that tension by making security itself intrinsically part of the private cloud architecture rather than a bolted-on gate: VCF Automation's **Cloud Consumption Interface (CCI)** exposes vDefend's full security model as declarative, Kubernetes-style custom resources, scoped per **Organization (tenant)** through ordinary namespace and RBAC boundaries. The result is out-of-the-box, self-service security in a true multi-tenant model — eliminating the network security bottlenecks that traditionally slow application delivery to a crawl. This paper walks through that model end to end: the challenges it solves, the vDefend architecture underneath it, how multi-tenant isolation is engineered, how self-service and API-driven automation deliver it, what the experience looks like for the people involved, and the business outcomes it produces.

## 1. Executive Summary

**The Dilemma.** Every organization running a private cloud faces the same tension: application teams are measured on how fast they ship, and security teams are measured on how well they contain blast radius. Historically these goals fought each other — compute and network self-service moved at DevOps speed, while security configuration stayed centralized, manual, and ticket-driven. The team that could deploy a three-tier application in minutes still waited days for a security admin to open the ports it needed.

**The Solution.** VMware Cloud Foundation (VCF), integrated with VMware vDefend, closes that gap by design rather than by process. vDefend's Distributed Firewall, Gateway Firewall, and Transit Gateway Firewall are embedded natively in the hypervisor and exposed as ordinary Kubernetes custom resources through VCF Automation's CCI. Security stops being a system bolted onto the private cloud and becomes one of its intrinsic properties — enforced at the vNIC, configured through the same API surface as everything else, and scoped per tenant from day one.

**The Value Proposition.** Because vDefend's security model is exposed through VCF Automation and native APIs, every Organization gets its own self-service security surface — group membership, firewall policy, and posture — the moment its tenant Project is provisioned, with zero tickets to a central security team. A provider admin sets the guardrails once (quotas, regions, role bindings); every Organization afterward iterates on its own posture independently, isolated from every other tenant by construction. And because the objects are ordinary Kubernetes resources, every mainstream infrastructure-as-code and GitOps tool — Terraform, Ansible, Argo CD, any CI/CD pipeline — works against them without a bespoke integration.

The five resource kinds this paper returns to throughout map directly onto vDefend's three real enforcement points inside and around a tenant's VPC:

| Resource kind | Enforcement point | Analogous to |
|---|---|---|
| `NetworkSecurityGroup` | N/A — reusable, region-scoped membership object | A region-scoped Group, referenced by `FirewallPolicy` and `TGWFirewallPolicy` |
| `SecurityProfile` | N/A — cross-cutting policy-mode object | A per-VPC security posture (north-south firewall on/off, east-west isolation strategy), only live once bound to a VPC via `SecurityProfileAttachment` |
| `FirewallPolicy` | East-west, intra-VPC | The Distributed Firewall (micro-segmentation) |
| `VPCGatewayFirewallPolicy` | North-south, per-VPC perimeter | The VPC's Gateway Firewall |
| `TGWFirewallPolicy` | East-west, inter-VPC | Transit Gateway firewalling / VPC Connectivity Policies |

**Why it matters:**

- **Self-service security, out of the box.** A tenant Organization gets its own `NetworkSecurityGroup`/`FirewallPolicy` API surface the moment its Project is provisioned — no separate security-platform onboarding, no waiting on a shared team.
- **True multi-tenant isolation.** Every object is scoped to a Project's own Supervisor Namespace; one Organization can shape its own posture in detail and still can't see or touch another's, by construction — not by convention.
- **Ship faster.** Tenant security policy becomes a pull request, not a ticket queue — application teams stop waiting on a human to click through a console.
- **Prove compliance from Git alone.** Every rule change is reviewed, versioned, and attributable — `git log` becomes audit evidence for PCI-DSS, ISO 27001, and SOC 2 without extra tooling.
- **Reuse what already works.** No proprietary automation surface — the same Terraform, Ansible, and Argo CD skills a platform team already has apply directly, on day one.

The rest of this paper builds out that value proposition in order: §2 names the legacy problems this model solves, §3 explains vDefend's architecture, §4 covers how multi-tenant isolation is engineered, §5 and §6 cover self-service and API-driven delivery, §7 walks the experience for every persona involved, and §8 closes with the business outcomes.

---

## 2. Introduction: The Challenges of Legacy Security in a Cloud-Native World

### 2.1 The App Deployment Bottleneck

In a traditional private cloud, network security is the last mile of every deployment and the slowest one. An application team finishes provisioning compute and storage in minutes, then opens a ticket asking a security admin to create firewall Groups and Distributed Firewall or gateway firewall rules by hand. That ticket sits in a queue behind every other tenant's requests, gets actioned by someone with no context on the application beyond what fit in a form field, and — because it's manual — occasionally gets it wrong in ways nobody notices until an outage or an audit. The compute and network layers are self-service; security stays centralized and manual, which makes it the bottleneck by default, not by intent.

### 2.2 Tromboning and Choke Points

The manual bottleneck in §2.1 has an architectural twin: even once a rule exists, hardware-centric security forces traffic to detour to enforce it. Applying security by routing intra-data-center (east-west) traffic out to a centralized hardware firewall — commonly called "tromboning" or hair-pinning — means two VMs on the same rack, sometimes the same host, still leave the network to have their own traffic inspected and come back. That detour adds latency to every flow it touches, and it turns the firewall appliance itself into a throughput ceiling every tenant and every application shares, whether they know it or not.

### 2.3 The Multi-Tenant Complexity

The bottleneck compounds the moment the private cloud hosts more than one tenant. Multiple departments, business units, or external clients sharing the same physical infrastructure need security boundaries strict enough that one tenant's misconfiguration — or compromise — can never reach another's workloads, while still giving each tenant enough control to move at its own pace. Hardware-centric, perimeter-based architectures were never built for this: a single shared firewall appliance sitting at the network edge has no native concept of "tenant," and traditional isolation via VLANs and VRFs stops at the tenant boundary — it does nothing to contain lateral movement *within* a tenant's own compromised segment. Isolating tenants this way means hair-pinning traffic through ever more complex VLAN, routing, and rule-set gymnastics that get harder to reason about — and easier to get wrong — with every tenant added.

### 2.4 The Paradigm Shift

The way out is the same shift the rest of infrastructure already made: from perimeter-based, hardware-centric security to software-defined, distributed security — commonly called DevSecOps, or Security-as-Code. Instead of one chokepoint appliance enforcing rules for everyone, security logic moves to the workload itself and is expressed as data — declarative objects an API server can create, version, and reconcile continuously. That shift is what makes DevSecOps possible in practice rather than in name only: when security policy is an API object instead of a ticket, it can live in the same pull request as the application change it protects, reviewed by the same people, on the same timeline. §3 explains the vDefend architecture that makes this possible; §4 through §6 show how VCF Automation exposes it as a true self-service, API-driven model.

---

## 3. The Foundation: Understanding VMware vDefend in VCF

### 3.1 What Is vDefend?

**vDefend** is Broadcom's distributed security suite, natively built into VMware Cloud Foundation rather than deployed alongside it. Its portfolio spans Distributed Firewall micro-segmentation, VPC Gateway Firewall, Transit Gateway Firewall, IDS/IPS, Advanced Threat Prevention (ATP), and Identity Firewall (AD-integrated, user-based policy) — all embedded directly in the ESXi hypervisor, so traffic is inspected at the workload's virtual NIC without ever leaving the host to reach a separate security appliance. By moving enforcement into the hypervisor itself, vDefend decouples security from network topology entirely — a workload's protection travels with it, independent of subnet, VLAN, or physical rack. Inside a VCF VPC, three of those capabilities are the enforcement points this paper automates end to end:

- **Distributed Firewall (micro-segmentation)** — east-west enforcement at each workload's vNIC *within* a VPC, driven by `FirewallPolicy` objects whose rules reference `NetworkSecurityGroup`s as source/destination peers. This is the primary object tenants author to isolate application tiers (e.g., only the app tier may talk to the DB tier on 5432).
- **VPC Gateway Firewall** — stateful north-south perimeter enforcement at the VPC's own gateway, driven by `VPCGatewayFirewallPolicy`. VCF Networking creates a default allow-all north-south rule per VPC; tenants are expected to add explicit `VPCGatewayFirewallPolicy` rules to restrict what can enter or leave the VPC boundary.
- **Transit Gateway Firewall (inter-VPC)** — east-west enforcement *between* VPCs that share a Transit Gateway, driven by `TGWFirewallPolicy`, letting a platform team carve out precise exceptions (e.g., "a shared-services VPC may reach any tenant VPC on port 443 only") on top of the coarser connectivity posture set by `VPCConnectivityProfile` (§5.2.11). It has its own on/off master switch: a `TGWFirewallPolicy` enforces nothing until the referenced Transit Gateway's `TGWSecurityConfig` enables the `GatewayFirewall` feature (§5.2.10).
- **`SecurityProfile`** is not itself an enforcement point but the cross-cutting object that controls *how* the above behave for a given VPC — specifically, whether the VPC's north-south (gateway) firewall is enabled at all (`northSouthFirewall.enabled`) and which east-west micro-segmentation strategy applies (`eastWestFirewall.securityStrategies`, e.g. `vpc-isolation`). It only takes effect once bound to a VPC via a separate `SecurityProfileAttachment` object — see §5.2.2. TCP-strict handshake enforcement (`tcpStrict`) is actually a per-policy field on each `FirewallPolicy`/`VPCGatewayFirewallPolicy`/`TGWFirewallPolicy`, not on `SecurityProfile`.

IDS/IPS, ATP, and Identity Firewall are real, licensed vDefend capabilities that inspect the same east-west traffic these firewalls govern and feed threat intelligence back into the policy loop (§7.2, §6.4) — but as of the verified `vpc.nsx.vmware.com/v1alpha1` schema this paper is built against, their configuration and detection surface live outside this specific CCI API group. This paper is precise about that boundary throughout rather than overstating what's automatable today: §5.2 covers exactly the firewalling objects that are exposed and automatable via CCI right now.

### 3.2 Intrinsic vs. Bolted-On Security

The architectural reason vDefend outperforms a hardware-centric model isn't a feature checklist — it's where enforcement physically happens. A bolted-on firewall appliance sits somewhere in the network and every packet that needs a decision has to be routed to it: two VMs on the same ESXi host, talking to each other on the same subnet, still get hair-pinned out to a chokepoint box and back. That single appliance is a shared blast radius, a throughput ceiling every tenant competes for, and a single point where a misconfiguration or an outage affects everyone behind it.

vDefend's Distributed Firewall instead enforces at the vNIC, inside the ESXi hypervisor kernel, on the host the workload already runs on — inspection happens before traffic ever reaches the virtual switch, let alone leaves the host. Two VMs on the same host never leave it to have their traffic firewalled. Policy capacity scales linearly with the cluster rather than against one appliance's packet-per-second ceiling: every ESXi host added to VCF brings its own firewall enforcement with it, so firewall throughput grows with compute instead of competing against it. And because there's no shared enforcement point left in the path, a policy change to one workload's posture has no way to affect a neighbor's — there's nothing centralized left to be a blast radius. This is what "intrinsic" means in practice: security isn't a hop the traffic makes, it's a property the traffic already has.

### 3.3 Context-Aware Security

The other half of the shift is what a rule is allowed to reference. A hardware firewall's rules are built on IP addresses and subnets — static facts that go stale the moment a VM is redeployed, migrated, or replaced by autoscaling. vDefend's `NetworkSecurityGroup` objects are built on VM attributes instead: labels, tags, and namespace membership that stay true regardless of which IP a workload happens to hold today.

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
```

A group defined this way — "every VM labeled `tier: app`" — never needs to be edited as VMs are added, removed, or re-IP'd; the Distributed Firewall re-evaluates membership continuously. VCF Automation goes a step further and tags every VM's network interface automatically the moment it lands in a Supervisor Namespace (`nsx-op/vm_namespace: <namespace name>`), so "one namespace = one blast-radius" is available as a day-0 isolation boundary with zero manual tagging. §5.2.1 covers the full membership schema — static IPs, static VM lists, dynamic selectors, and nested group references — along with its confirmed limitations.

---

## 4. Architecting Multi-Tenant Security in VCF

### 4.1 Logical Isolation via VCF VPCs

A **Virtual Private Cloud (VPC)** inside VCF is what turns a shared physical private cloud into a set of self-contained environments, one per tenant. The full hierarchy, from provider admin down to a workload:

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

An **NSX Project** is the representation of an Organization (tenant) in NSX. Everything a tenant can self-service — including security policy — is scoped inside the namespaces their Project owns, bounded by quotas and RBAC the provider admin defined up front via `infrastructure.cci.vmware.com` and `authorization.cci.vmware.com`.

Side by side, two tenants on the same shared VCF instance look like fully separate environments, not shared space with a permissions layer painted on top:

```
+-----------------------------------------------------------------------------------+
|                    VCF Provider Admin Domain (Region / Cloud Admin)               |
|   infrastructure.cci.vmware.com quotas  |  authorization.cci.vmware.com RBAC      |
+-----------------------------------------------------------------------------------+
                                        |
     +----------------------------------+----------------------------------+
     |                                                                     |
+----v-----------------------------------+    +----------------------------v--------+
|  Project A (Tenant Alpha)              |    |  Project B (Tenant Beta)            |
|  Supervisor Namespace + VPC A          |    |  Supervisor Namespace + VPC B        |
|  +-----------------------------------+ |    |  +--------------------------------+ |
|  | FirewallPolicy — category:        | |    |  | FirewallPolicy — category:      | |
|  |   Application                     | |    |  |   Application                   | |
|  | - allow web-to-app (TCP 8443)     | |    |  | - allow app-to-db (TCP 5432)    | |
|  | - deny-all default                | |    |  | - deny-all default              | |
|  +-----------------------------------+ |    |  +--------------------------------+ |
|  ESXi Hypervisor Kernel — vNIC          |    |  ESXi Hypervisor Kernel — vNIC       |
|  vDefend Distributed Firewall filter    |    |  vDefend Distributed Firewall filter |
+-----------------------------------------+    +--------------------------------------+
```

Neither tenant's `FirewallPolicy`/`NetworkSecurityGroup` objects are reachable from the other's namespace, their IP address ranges and routing tables don't overlap, and each VPC's own Gateway Firewall governs its own perimeter independently — no shared appliance, no shared rule set, no cross-tenant visibility, even though both run on the same physical hosts.

**What actually stops Organization A from touching Organization B's security posture** is three ordinary Kubernetes mechanisms stacked together, not a convention anyone has to remember to follow:

1. **Namespace boundary.** Every `vpc.nsx.vmware.com/v1alpha1` object — `NetworkSecurityGroup`, `FirewallPolicy`, `SecurityProfile`, all of it — lives inside a specific Supervisor Namespace. There is no cluster-scoped variant of these kinds a tenant can reach.
2. **RBAC (`authorization.cci.vmware.com`).** A tenant's kubeconfig context is bound to role bindings scoped to their own namespace(s) only. The Kubernetes API server itself — not an application-layer check — rejects a request against a namespace the token isn't bound to.
3. **Quota (`infrastructure.cci.vmware.com`).** Even inside their own namespace, a tenant can't exceed the network/compute limits a provider admin set at Project creation, so one Organization's self-service activity can't starve another's.

Together these are what make "self-service" and "safe" the same sentence: an Organization gets full read/write control over its own vDefend posture, and zero visibility or reach into anyone else's — enforced by the API server, not by policy.

### 4.2 Tiered Security Modeling

Isolating tenants from each other is only half the model. Inside that boundary, VCF splits control into two tiers so that a platform-wide baseline can't be quietly overridden by a single tenant, while tenants still get real, immediate control of their own micro-segmentation:

- **Provider/Admin level.** Global, non-negotiable rules — the ones that must apply to every tenant regardless of what any individual app team wants — are delivered through `SecurityProfile`. Rather than tenants hand-authoring an east-west strategy from scratch, VCF Automation ships pre-created, **system-owned** `SecurityProfile` objects, one per named strategy (`vpc-isolation`, `vpc-secure-connection`, `vpc-isolation-with-essential-services`, `vpc-external-connectivity`, `none`); a tenant *selects* a posture by pointing their `SecurityProfileAttachment` at one of these, they don't author the underlying strategy. The same tiering shows up at the object level: a `FirewallPolicy`/`VPCGatewayFirewallPolicy` that a `SecurityProfile` generates cannot be edited or have rules appended to it by a tenant directly — the only supported customization path is a **separate**, higher-priority policy that runs *before* it (§5.2.2). Transit Gateway firewalling has the same shape: a `TGWFirewallPolicy` enforces nothing until a platform-owned `TGWSecurityConfig` turns `GatewayFirewall` on for that gateway (§5.2.10) — since a misconfigured `TGWFirewallPolicy` can affect traffic between *multiple* tenants' VPCs at once, that master switch and the policies that depend on it are best routed through the platform team's own `AppProject`/module rather than granted to individual tenants.
- **Tenant level.** Everything below that global baseline is delegated. Inside their own isolated boundary, an app owner creates their own `NetworkSecurityGroup`/`FirewallPolicy` objects to micro-segment their application tiers exactly how they want, with no platform-team involvement per change (§5.1, §5.2).

**Evaluation order backs the tiering, not just convention.** Every `FirewallPolicy` carries a `spec.category`, and the confirmed schema values — `Infrastructure`, `Environment`, `Application` — evaluate in that fixed order: fabric-level rules (DNS, NTP, AD access) in `Infrastructure`, macro-segmentation (e.g., blocking `Prod` from ever reaching `Dev`) in `Environment`, and tenant micro-segmentation in `Application`. Because categories evaluate top-down, an `Infrastructure`- or `Environment`-category rule authored by the Security Admin (§4.3) is checked before any `Application`-category rule a tenant writes, so a global rule always gets the chance to act first. As a governance convention — not a hard restriction this schema enforces on its own — most platforms scope tenant RBAC and `CODEOWNERS` review to `Application`-category policies only, reserving `Infrastructure`/`Environment` for provider- and Security-Admin-authored baselines; enforce that boundary through policy review (§6.3.1) rather than assuming the API blocks a tenant from setting a different category on their own.

The result is a model where "global policy tenants cannot override" and "tenant-authored micro-segmentation" coexist as two tiers of the same API surface, not as two disconnected systems.

### 4.3 Role-Based Access Control (RBAC): Separation of Duties

The tiering in §4.2 is enforced, not just documented, through `authorization.cci.vmware.com` RBAC scoped to three distinct roles:

- **Cloud Admin.** Owns `infrastructure.cci.vmware.com` (quotas, namespace classes, zone/region association) and `topology.cci.vmware.com` (region/zone/supervisor topology) — the guardrails that exist *before* any tenant gets self-service access at all. Guardrails always precede self-service: quotas and RBAC are set up front, which is what makes handing a tenant full autonomy over its own `NetworkSecurityGroup`/`FirewallPolicy` objects safe rather than reckless.
- **Security Admin.** Owns the platform-wide security guardrails from §4.2 — the system `SecurityProfile` catalog, `TGWSecurityConfig`, `VPCConnectivityProfile`, and compliance-baseline `SecurityStrategy` definitions (§5.2.9) — plus review authority over anything that can affect more than one tenant, like `TGWFirewallPolicy` changes on a shared Transit Gateway.
- **Tenant App Developer.** Scoped, via `authorization.cci.vmware.com` role bindings, to exactly their own Project's namespace(s) — full read/write on `NetworkSecurityGroup`, `FirewallPolicy`, and `VPCGatewayFirewallPolicy` inside that boundary, and nothing outside it.

The same least-privilege principle extends to automation identities, not just people: a Terraform CI runner's CCI token or an Argo CD cluster secret should each be scoped to only the tenant namespace(s) they manage — never a Project-wide or Region-wide credential, even though the pipeline itself may be platform-owned.

---

## 5. Delivering Self-Service Security via VCF Automation

### 5.1 The Self-Service Catalog

For a tenant, self-service starts as a catalog request — provision a new Supervisor Namespace or Project — and from that point on, every security change happens without a second request to anyone. Concretely, here's what "self-service" means for a newly onboarded Organization — no ticket, no provider-side engineer, at any step after the Project exists:

1. **Authenticate.** The tenant admin logs into VCF Automation (or a pipeline calls `vcfa_kubeconfig`/an equivalent token exchange) and receives a kubeconfig context scoped to their own Supervisor Namespace — nothing else is visible.
2. **Talk to the API directly.** With that kubeconfig, `kubectl get networksecuritygroups,firewallpolicies -n <their-namespace>` works immediately — it's a real Kubernetes API server, not a ticketing front-end to one.
3. **Change posture themselves.** `kubectl apply -f web-tier-nsg.yaml` (or a Terraform `apply`, an Ansible playbook run, or a merged GitOps PR — §6.2, §6.3 show all three) creates a `NetworkSecurityGroup`, and a follow-up `FirewallPolicy` referencing it, entirely inside their own namespace.
4. **See enforcement immediately.** VCF Networking reconciles the object and starts enforcing the rule at the Distributed Firewall — no provider-side apply step, no shared change window.

That loop — authenticate, read, write, see it enforced — is what "secure by default from a service portal" means in practice. It also starts before a developer ever writes a security rule: the moment VCF Automation provisions a new VM into a Supervisor Namespace, it auto-tags that VM's network interface (`nsx-op/vm_namespace`, §5.2.1) as part of the same provisioning workflow that creates the VM. Any `NetworkSecurityGroup` whose selector already matches that tag picks the new workload up immediately — there is no window where the VM is powered on but unprotected, and no separate step where a human has to remember to add it to a group. §5.2 is the full reference for the objects used in step 3; §6 shows how to run that loop at fleet scale instead of by hand.

### 5.2 Security as Code in VCF Blueprints

This is the API surface each Organization gets self-service control over the moment its Project exists, and the exact objects to embed into a VCF Automation blueprint to make an application "secure by default" the moment it deploys — every kind below lives inside a tenant's own Supervisor Namespace (§4.1) and needs nothing from a provider admin to create, update, or delete once the guardrails in §4 are in place.

#### 5.2.1 `NetworkSecurityGroup` / `VPCNetworkSecurityGroup` — the reusable "who"

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

#### 5.2.2 `SecurityProfile` + `SecurityProfileAttachment` — the VPC's security posture

`SecurityProfile` is a standalone, `regionName`-scoped object — it does nothing on its own. A separate **`SecurityProfileAttachment`** object (`regionName` + `securityProfileName` + `vpcName`, all required) is what actually binds it to a VPC. `SecurityProfileSpec` itself controls VPC-wide enforcement behavior rather than individual rules: whether the north-south (gateway) firewall is enabled at all, and which east-west micro-segmentation strategy the VPC runs. There is no `tcpStrict` field here (that lives on each firewall policy kind, §5.2.3–5.2.5) and no IDS/IPS or Malware Prevention profile reference field in this API group.

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

Day-2 changes are ordinary `kubectl patch` calls against these objects — useful as an imperative complement to the Terraform/Ansible/Argo CD patterns in §6.2–§6.3, e.g. for a break-glass change or a quick lab test:

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
- A `FirewallPolicy`/`VPCGatewayFirewallPolicy` generated by a `SecurityProfile` cannot be edited or have rules added to it directly. To customize behavior, author a **separate** policy with a higher-priority (lower `priority` number, or a `category` that evaluates earlier) that runs *before* the Security-Profile-generated one — never attempt to patch the generated policy in place. This is the Provider/Tenant tiering from §4.2 enforced at the object level; build the expectation into `CODEOWNERS`/linting so a reviewer doesn't approve a diff against the generated policy itself.
- Essential-services rules generated by a profile (DNS/NTP/DHCP/ICMP) always allow both directions; this is not configurable per profile.
- Because every `SecurityProfile`-generated rule terminates in `JumpToApplication` rather than an explicit `Allow`, the `vpc-secure-connection` and `vpc-external-connectivity` strategies **fail closed**: if the tenant hasn't authored an explicit `Application`-category `FirewallPolicy` permitting the traffic, it's dropped by the time evaluation reaches the default rule — don't assume "external connectivity enabled" means traffic actually flows without a matching application-category allow rule.

#### 5.2.3 `FirewallPolicy` — east-west (Distributed Firewall) rules

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

#### 5.2.4 `VPCGatewayFirewallPolicy` — north-south perimeter rules

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

#### 5.2.5 `TGWFirewallPolicy` — inter-VPC rules on a shared Transit Gateway

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

#### 5.2.6 How the kinds compose

```
NetworkSecurityGroup (regionName)     ──referenced by──▶  FirewallPolicy (east-west, intra-VPC)
                                                            TGWFirewallPolicy (east-west, inter-VPC)

VPCNetworkSecurityGroup (vpcName)     ──referenced by──▶  VPCGatewayFirewallPolicy (north-south)

NetworkService                        ──referenced by──▶  any rule's services[] (all three firewall kinds)

SecurityProfile  ──bound to a VPC via──▶  SecurityProfileAttachment  ──governs posture of──▶  that VPC

TGWSecurityConfig (GatewayFirewall: true)  ──gates enforcement of──▶  TGWFirewallPolicy

VPCConnectivityProfile  ──bound to a Project via──▶  VPCConnectivityProfileBinding  ──sets IP/NAT/TGW posture of──▶  that Project's VPCs
```

A group object is the only thing the three firewall-policy kinds *require* to express meaningful rules; `SecurityProfile` is orthogonal, and inert until attached. In practice, a tenant onboarding baseline creates one `SecurityProfile` plus its `SecurityProfileAttachment`, a handful of `NetworkSecurityGroup`/`VPCNetworkSecurityGroup` objects (one per application tier or trust zone, matching the policy kind that will reference them), a default-deny `FirewallPolicy` and `VPCGatewayFirewallPolicy`, and adds `TGWFirewallPolicy` (plus a `TGWSecurityConfig` enabling it) only if the tenant's architecture spans multiple VPCs. §5.2.7–§5.2.12 cover the remaining supporting kinds — reusable service definitions, realized-membership visibility, rule-template bundles, and connectivity/capability posture — and how each fits into an automation pipeline.

#### 5.2.7 `NetworkService` — reusable service/port definitions

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

#### 5.2.8 `NetworkSecurityGroupIPMembers` / `VPCNetworkSecurityGroupIPMembers` — realized membership (read-only)

Read-only subresources — no `spec`, just a top-level `ipAddresses[]` — that report the IPs a group's selectors *actually* resolved to right now. They exist because `vmSelectors`/`podSelectors` are dynamic: a typo'd `matchLabels` value silently resolves to zero members, leaving a rule that references the group with no effective peers and no error anywhere.

```bash
kubectl get networksecuritygroupipmembers acme-app-tier -n acme-prod-ns01 -o yaml
kubectl get vpcnetworksecuritygroupipmembers acme-web-tier-vpc -n acme-prod-ns01 -o yaml
```

**Automation use:** add a post-apply validation step to the CI/CD pipeline (§6.3) — after applying a `NetworkSecurityGroup`/`VPCNetworkSecurityGroup` change, read the matching `IPMembers` subresource and assert it's non-empty (or matches an expected count) *before* promoting the paired `FirewallPolicy`/`VPCGatewayFirewallPolicy` change that references it. This turns a silent "selector matched nothing" mistake into a failed pipeline step instead of a production outage discovered later.

#### 5.2.9 `SecurityStrategy` — reusable rule-template bundles

`SecurityStrategySpec` holds `description` plus `ruleTemplates[]` — an array in the **same shape** as a `FirewallPolicy` rule (`action`, `appliedTo`, `direction`, `from[]`, `to[]`, `services[]`, `isDefault`, `tag`, …). This looks purpose-built for defining a reusable, named bundle of firewall rules once and applying it consistently.

> **Field note:** don't design a Terraform module around custom `SecurityStrategy` objects yet. Nothing in `SecurityProfile`, `FirewallPolicy`, or any other kind binds one by name — `SecurityProfileSpec.eastWestFirewall.securityStrategies[]` (§5.2.2) takes fixed strings (`none`, `vpc-isolation`, `vpc-secure-connection`, `vpc-isolation-with-essential-services`, `vpc-external-connectivity`), and a live VCF 9.1 environment confirms why: it ships exactly five pre-created, **system-owned** `SecurityProfile` objects, one per named strategy, and a tenant picks a posture by pointing `SecurityProfileAttachment` at one of those (§5.2.2) rather than authoring a `SecurityStrategy` object. Treat `SecurityStrategy` as system-internal plumbing until a future API revision exposes a real binding point — a quick `kubectl get securitystrategy -A` in your own environment will tell you if that's changed.

**Automation use (once confirmed live):** one `SecurityStrategy` per compliance baseline (e.g. `pci-dfw-baseline`), owned and versioned by the Security Admin (§4.3), referenced by name from every tenant's `SecurityProfile` instead of copy-pasting the same baseline rules into each tenant's `FirewallPolicy`.

#### 5.2.10 `TGWSecurityConfig` — the Transit Gateway firewall on/off switch

A subresource of `TransitGateway`: `spec.features[]` is a list of `{ name, enabled }` pairs, where the only documented `name` value is `GatewayFirewall`. This is the master switch — a `TGWFirewallPolicy` (§5.2.5) enforces nothing on a given Transit Gateway until that gateway's `TGWSecurityConfig` has `GatewayFirewall: enabled: true`, the same way a `SecurityProfile` is inert until attached via `SecurityProfileAttachment` (§5.2.2).

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

#### 5.2.11 `VPCConnectivityProfile` / `VPCConnectivityProfileBinding` — VPC north-south connectivity posture

`VPCConnectivityProfileSpec` governs a VPC's outward connectivity: `externalIPBlockNames[]`, `privateTGWIPBlockNames[]`, `transitGatewayName`, `regionName` (required), `isDefault`, and `serviceGateway` (`enable` + `natConfig.{autoSNATIPBlockName, enableDefaultSNAT}`). `VPCConnectivityProfileBinding` is what makes a profile usable — it binds a named `VPCConnectivityProfile` to a Project/namespace via `spec.vpcConnectivityProfileName` (required), after which that Project's VPCs can use it.

**Field note:** despite being the object most associated with "VPC connectivity posture," this schema version has **no explicit isolation-mode field** here (no `Community`/`Isolated`/`Promiscuous`-style enum on `VPCConnectivityProfileSpec`). That default-connectivity toggle more likely lives on `FirewallPolicySpec.connectivityPreference`/`applicationConnectivityStrategy` instead (§5.2.3) — confirm placement with `kubectl explain` in your own build before an automation module hard-codes an assumption either way.

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

#### 5.2.12 `RegionNetworkingCapabilities` — capability discovery for automation gating

Read-only, one object per Region: a top-level `capabilities[]` array of `{ type, state, reason, message }`, e.g. an older region might report `{"type": "IPSecVPN", "state": false, "reason": "UnsupportedByNSXVersion"}`.

**Automation use:** a pre-flight check — in a Terraform data source lookup or a CI/CD pipeline step (§6.3) — before generating manifests that depend on a specific capability (a `TGWFirewallPolicy`, an `IPSecVPN`, etc.) in a given region. Reading `RegionNetworkingCapabilities` first and failing fast with a clear message beats letting the `apply` fail deep inside backend reconciliation because the target region doesn't support the feature yet.

**Known platform limitations to design around (current as of VCF 9.1), not bugs to work around silently:**
- `VPCGatewayFirewallPolicy`/`VPCNetworkSecurityGroup` objects are not visible or usable from inside a Project's Supervisor context the way `NetworkSecurityGroup` is — don't assume VPC-scoped groups are reachable from every automation surface a tenant touches.
- The namespace auto-tag grouping pattern (§5.2.1) does not work for VKS cluster nodes or for workloads on a *shared* VPC subnet — plan a separate grouping strategy (auto-generated tags, or explicit labels) for those workloads rather than assuming one `NetworkSecurityGroup` pattern covers a whole tenant.
- Custom `NetworkService` creation has been observed to reject at least some arbitrary TCP ports (e.g. the Kubernetes API's `6443`) in current builds — verify a custom `NetworkService` actually applies before depending on it in a pipeline, rather than assuming any port/protocol combination is definable.

### 5.3 Day 2 Operations

The self-service model doesn't stop at initial deployment. A tenant that needs to scale out an application tier, add a new microservice, or tighten a rule after a review does it the same way it did the original deployment: a direct `kubectl`/`kubectl patch` call for a break-glass or lab change (§5.2.2), a merged pull request against their GitOps repo for anything durable (§6.3.2), or a re-run of their onboarding Terraform for structural changes (§6.2.1) — never a new ticket to a central team.

**Zero-trust auto-scaling is a side effect, not extra work.** Because group membership in §5.2.1 is selector-based rather than a static list, an autoscaler adding a fourth `db`-tier VM at 2am doesn't need a firewall change at all — the new VM lands in its namespace, gets auto-tagged the same way every VM does, matches the existing `acme-db-tier` selector, and inherits every rule already written for that group before it answers its first connection. Day 2 scaling events are covered by day-0 policy; nobody has to remember to extend a rule set to match. §7.1 walks through exactly this happening for a real application.

---

## 6. API-Driven Security: Integrating with CI/CD and DevOps Toolchains

### 6.1 The API-First Approach

For modern platform engineering, security has to be fully programmable, not just documented as a set of console steps. Everything in §5 is possible because VCF Automation's **Cloud Consumption Interface (CCI)** is a real Kubernetes API server, not a proprietary REST API with a UI bolted in front of it. Tenants authenticate, receive a **kubeconfig context per Supervisor Namespace** their Project owns, and interact with it via `kubectl`, any Kubernetes client library, Terraform's `kubernetes`/`kubectl` providers, Ansible's Kubernetes collection, or a GitOps controller like Argo CD. Relevant API groups include:

| API group | Purpose |
|---|---|
| `project.cci.vmware.com/v1alpha2` | Tenant Project definition (the top-level multi-tenancy boundary) |
| `infrastructure.cci.vmware.com/v1alpha1-3` | Namespace classes, quotas, zone/region association — the guardrails a provider admin sets before a tenant gets self-service access |
| `authorization.cci.vmware.com/v1alpha1` | RBAC / role bindings scoped to a Project or namespace |
| `topology.cci.vmware.com/v1alpha1-2` | Region/zone/supervisor topology |
| `vpc.nsx.vmware.com/v1alpha1` | **VPC networking and security**: `VPC`, `Subnet`, `NetworkSecurityGroup`/`VPCNetworkSecurityGroup` (+ their `IPMembers` subresources), `NetworkService`, `SecurityProfile`, `SecurityProfileAttachment`, `SecurityStrategy`, `FirewallPolicy`, `VPCGatewayFirewallPolicy`, `TGWFirewallPolicy`, `TGWSecurityConfig`, `VPCConnectivityProfile`/`VPCConnectivityProfileBinding`, `RegionNetworkingCapabilities` |
| `vmoperator.vmware.com/v1alpha3` | VM lifecycle (the workloads the security policy protects) |

Because it's a standard API server behind the scenes, "programmable security" doesn't require a vDefend-specific SDK — it requires whatever Kubernetes tooling a platform team has already standardized on. The rest of this section covers three of those: declarative infrastructure-as-code, pipeline-driven delivery, and event-driven response.

### 6.2 Infrastructure as Code: Terraform and Ansible

The self-service loop in §5.1 works by hand for one Organization; this section shows how to drive that same per-Organization surface at fleet scale instead.

#### 6.2.1 Terraform

**Why Terraform here.** Terraform fits naturally where tenant security config is provisioned **as part of** environment stand-up — e.g., a "new tenant" pipeline that creates the Project, VPC, Subnets, quotas, and the baseline `SecurityProfile`/`NetworkSecurityGroup`/default-deny `FirewallPolicy`/`VPCGatewayFirewallPolicy` set in one atomic `apply`, with the safety of `plan` review and state-tracked drift detection. For platform teams that already run multi-cloud IaC on Terraform, this means zero new tooling to onboard a tenant securely on day one.

**Provider chain.** VCF Automation 9 exposes three complementary Terraform providers. For vDefend automation, two matter:

- **`vcfa`** — provider-admin-level operations (orgs, regions, quotas) and, critically, a `vcfa_kubeconfig` data source that mints CCI credentials.
- **`kubernetes`** (HashiCorp's standard provider) — applies raw manifests (`kubernetes_manifest`) against the CCI API server for anything CCI exposes as a CRD, including every `vpc.nsx.vmware.com/v1alpha1` object.

**A note for readers who already know the classic `vmware/nsxt` Terraform provider:** that provider talks to NSX Manager's Policy API directly (`nsxt_policy_security_policy`, `nsxt_policy_group`, and friends) and is the right tool for the older, non-VPC NSX-T Policy Manager model. VCF 9's VPC/CCI model is a different, Kubernetes-native surface — for it, the standard `kubernetes` provider against CCI, shown below, is the verified, correct path, not `vmware/nsxt`.

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

**Declaring a tenant's baseline security posture.**

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

**Module design and state strategy for multi-tenant scale.**

- **One Terraform workspace/state per tenant Project**, keyed by tenant ID — never a single monolithic state file spanning tenants. This bounds blast radius: a bad `apply` for one tenant can't corrupt another's state, and it lets you parallelize pipelines.
- Wrap the resources above in a `tenant-vdefend-baseline` module with variables for tier labels, allowed ports, and default-deny posture, versioned in a shared module registry so every tenant onboarding starts from the same vetted security baseline.
- Once Argo CD (§6.3.2) takes ownership of a resource's steady-state reconciliation, stop managing that same object from Terraform to avoid field-ownership fights — see §6.3.3.

#### 6.2.2 Ansible

Because CCI is a standard Kubernetes API server, it needs no vDefend-specific Ansible collection — the general-purpose `kubernetes.core.k8s` module applies any `vpc.nsx.vmware.com/v1alpha1` manifest the same way `kubectl apply` or Terraform's `kubernetes_manifest` do, against the same kubeconfig retrieved from `vcfa_kubeconfig` (or an equivalent token exchange):

```yaml
# apply_tenant_nsg.yml
- hosts: localhost
  gather_facts: false
  tasks:
    - name: Ensure the app-tier NetworkSecurityGroup exists
      kubernetes.core.k8s:
        kubeconfig: "{{ tenant_kubeconfig_path }}"
        state: present
        definition:
          apiVersion: vpc.nsx.vmware.com/v1alpha1
          kind: NetworkSecurityGroup
          metadata:
            name: "{{ tenant_name }}-app-tier"
            namespace: "{{ tenant_namespace }}"
          spec:
            regionName: "{{ region_name }}"
            vmSelectors:
              - labelSelector:
                  matchLabels:
                    tier: app
```

This is a reasonable choice for teams whose broader infrastructure automation is already Ansible-based — declare the same `NetworkSecurityGroup`/`FirewallPolicy`/`SecurityProfile` objects from §5.2 alongside VM provisioning tasks in the same playbook, rather than splitting security config into a separate Terraform run.

### 6.3 Pipeline Integration

#### 6.3.1 CI Pipelines (GitHub Actions, GitLab CI, Jenkins)

Whichever CI system a platform team already runs, the pattern is the same: a pipeline job authenticates against CCI (ideally via short-lived, OIDC-federated credentials rather than a long-lived static token), runs `terraform plan`/`apply` or `kubectl apply --dry-run=server` followed by `apply`, and is gated by the same pull-request review every other infrastructure change goes through. A minimal GitHub Actions example:

```yaml
# .github/workflows/tenant-security.yml
name: Apply tenant security policy
on:
  pull_request:
    paths: ["tenants/**/security-policy/**"]
jobs:
  plan-and-apply:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Fetch scoped tenant kubeconfig
        run: ./scripts/fetch-vcfa-kubeconfig.sh > kubeconfig.yaml
      - name: Validate manifests (dry run)
        run: kubectl --kubeconfig kubeconfig.yaml apply --dry-run=server -f tenants/${{ github.event.pull_request.head.ref }}/security-policy/
      - name: Apply on merge
        if: github.event_name == 'push'
        run: kubectl --kubeconfig kubeconfig.yaml apply -f tenants/${{ github.event.pull_request.head.ref }}/security-policy/
```

The same shape holds in GitLab CI (a `.gitlab-ci.yml` job with a `plan`/`apply` stage pair) or Jenkins (a declarative pipeline stage calling the same `terraform`/`kubectl` commands) — the CCI API doesn't care which orchestrator drives it. **Policy review is code review**: route `FirewallPolicy`/`VPCGatewayFirewallPolicy`/`TGWFirewallPolicy` PRs through the same gates as application code — `CODEOWNERS`, required approvals from the Security Admin (§4.3), and, where available, a policy-linting step that rejects rules without an explicit `direction`/`action`/port scope or that reference a `NetworkSecurityGroup` not defined anywhere in the repo. Where supported, validate with `kubectl apply --dry-run=server` or `terraform plan` against a non-production tenant namespace before promoting to production — this catches schema drift between API versions early, and a good pipeline also reads the target group's `IPMembers` subresource (§5.2.8) after apply, failing the job if it's unexpectedly empty before the paired firewall policy change is allowed to merge.

#### 6.3.2 GitOps with Argo CD

**Why GitOps here.** Security policy is not "set once at provisioning" — it changes continuously as tenant applications evolve (new microservice, new port, decommissioned tier). Treating it as a one-time Terraform apply leaves a gap for exactly the kind of manual, undocumented change that turns into an audit finding. Argo CD's continuous reconciliation loop closes that gap:

- **Drift correction**: if someone manually edits a `FirewallPolicy` or `NetworkSecurityGroup` via `kubectl` or the CCI UI, Argo CD reverts it (or flags `OutOfSync`) on the next sync — Git remains the enforceable source of truth for security posture, which auditors and compliance frameworks (PCI-DSS, ISO 27001, SOC 2) care about.
- **Self-service without a pipeline run**: tenant security engineers merge a PR against their tenant's policy repo; Argo CD picks it up within its poll/webhook interval — no separate CI job needs to hold cloud credentials.
- **Native multi-tenant fan-out** via `ApplicationSet`, generating one Argo CD `Application` per tenant from a single template.

**Registering the tenant's Supervisor Namespace as an Argo CD target.** Each tenant's CCI kubeconfig (obtained once, out-of-band or via the same `vcfa_kubeconfig` Terraform data source used for bootstrapping) is registered as an Argo CD cluster secret, scoped so Argo CD's service account only has RBAC (via `authorization.cci.vmware.com`) within that tenant's namespace(s) — never cluster-admin on the shared Supervisor.

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

**Per-tenant Application via ApplicationSet.**

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

`tenants/acme/security-policy/` in Git contains plain `NetworkSecurityGroup` / `FirewallPolicy` / `VPCGatewayFirewallPolicy` / `TGWFirewallPolicy` YAML — the shapes shown in §5.2 — reviewed via standard pull request workflow, ideally with a `CODEOWNERS` entry requiring the tenant's security lead to approve changes to their own policy.

**Ordering and safety.**

- Use `argocd.argoproj.io/sync-wave` annotations to guarantee `NetworkSecurityGroup` objects (wave 0) and the default-deny `FirewallPolicy`/`VPCGatewayFirewallPolicy` (wave 1) land before more permissive tier-specific allow rules (wave 2+) — groups must exist before a policy can reference them, and a default-deny baseline should never trail its allow rules into the cluster.
- Run Argo CD in **non-selfHeal, manual-sync mode for a probation period** on newly onboarded tenants, flipping to `automated.selfHeal: true` once the baseline policy has been validated in a lower environment — this gives a soft rollout path for a capability that can otherwise instantly enforce a mistake fleet-wide.

#### 6.3.3 Terraform vs. Argo CD: Choosing an Owner per Object

The two tools aren't competing for the same job — they excel at opposite ends of a tenant's lifecycle. The table below is the fast way to decide who owns what.

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

### 6.4 Automated Threat Response

The CCI API surface documented in §5.2 doesn't expose a direct "quarantine this workload" endpoint, and this paper doesn't overstate that it does. What it does expose is enough to build automated threat response on top of, using the same context-aware primitive from §3.3: dynamic `NetworkSecurityGroup` membership driven by VM tags. Because a group like "every VM labeled `tier: app`" re-evaluates membership continuously, an incident-response pipeline doesn't need a bespoke quarantine API to halt lateral movement — it needs to change one tag:

1. **Intrusion detection.** vDefend's IDS/IPS or ATP inspects east-west traffic and flags anomalous behavior — lateral movement, a ransomware signature, a known-bad pattern — and raises an event.
2. **Automated API call.** A SOAR tool or any event-driven pipeline (a webhook-triggered job using the same Terraform/Ansible/`kubectl` access already described in §6.2) receives that event and tags the affected VM — e.g. `security-state: quarantined` — without human intervention.
3. **Pre-authored isolation, not a new rule.** A `NetworkSecurityGroup` selector matching that tag (`matchLabels: { security-state: quarantined }`) picks the VM up immediately, and a `FirewallPolicy` referencing that group — authored and reviewed long before any incident, in the `Infrastructure` or `Environment` category from §4.2 so a compromised tenant can't remove its own quarantine rule — already denies it everything except the forensics/remediation path.
4. **Containment in one reconciliation cycle.** The workload is isolated without a firewall change ticket, without touching its IP address, and without taking the VM offline — halting further lateral movement in the time it takes the Distributed Firewall to re-evaluate group membership, not the time it takes a human to write a rule under pressure.

This is the same "policy as code, evaluated continuously" property from §2.4 applied to incident response instead of deployment: the fast path in a security incident is changing *data* (a tag), not authoring new *policy* under pressure.

### 6.5 Reference Architecture

Every path above — direct `kubectl` (§5.1), Terraform, Ansible (§6.2), and Argo CD (§6.3) — converges on the same per-Organization CCI surface:

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

## 7. The User Journey: Out-of-the-Box Security for Organizations

### 7.1 The Developer/Tenant Experience

From the developer's chair, this is deliberately unremarkable: log in to the self-service catalog, request a namespace or an application, and deploy — no separate stop to file a network security request, because there isn't one. This is the self-service model from §5.1 run for one real Organization, start to finish — provider-side Terraform for the shell, then the tenant's own team driving every security change afterward.

**Scenario**: Tenant `acme` needs a `web` / `app` / `db` three-tier application with default-deny micro-segmentation and a locked-down perimeter, permitting only public HTTPS to the web tier, `web → app:8443`, and `app → db:5432`.

**Step 1 (Terraform, onboarding pipeline)** — create the Project, VPC, Subnet, baseline `SecurityProfile`/`SecurityProfileAttachment`, tier `NetworkSecurityGroup`/`VPCNetworkSecurityGroup` objects, and default-deny `FirewallPolicy`/`VPCGatewayFirewallPolicy` (extends the Terraform baseline in §6.2.1):

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

**Step 2 (handoff)** — pipeline opens/merges a PR into `tenants/acme/security-policy/` in the tenant security repo containing the tier-specific groups and allow rules (§5.2 / §6.3.2), and registers `acme`'s namespace as an Argo CD `ApplicationSet` element (§6.3.2).

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

`acme-web-tier-vpc` is a separate `VPCNetworkSecurityGroup` mirroring `acme-web-tier` — `VPCGatewayFirewallPolicy` rules can't reference the region-scoped `NetworkSecurityGroup` kind (§5.2.1).

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

Once merged and approved by the `CODEOWNERS`-designated security lead, Argo CD syncs it — no Terraform run, no platform team ticket, and the default-deny `FirewallPolicy` and locked-down `VPCGatewayFirewallPolicy` still govern anything not explicitly matched. From the developer's perspective, a complex three-tier application went from empty namespace to fully isolated, micro-segmented, and internet-facing-only-where-intended in the time it took to merge a couple of pull requests — not the days or weeks a ticket-driven model would have taken.

**Optional Step 4 (multi-VPC tenants)** — if Acme later splits into a `prod` VPC and a `shared-services` VPC on a common Transit Gateway, a `TGWFirewallPolicy` (§5.2.5) is added to allow only the specific east-west paths needed between them, rather than relying on the coarser Community/Isolated/Promiscuous connectivity posture.

### 7.2 The Security/SecOps Experience

For the security team, this model replaces "gatekeeper for every change" with "continuous visibility plus policy-as-code review" — a role that doesn't block deployments but also never loses sight of them. SecOps stops spending its hours auditing individual static-IP rules one tenant at a time; instead it authors the `Infrastructure`/`Environment`-category global policies from §4.2 once, and relies on the Distributed Firewall's per-host enforcement (§3.2) to apply them across every tenant automatically, without re-checking each tenant's namespace by hand. Because every pattern in §6 terminates in a Git-reviewed change, `git log` on the tenant security repo (or Terraform module) becomes the compliance evidence trail for "who approved this firewall change and when" — a materially stronger artifact than point-and-click console audit logs alone, and one SecOps doesn't have to manually assemble after the fact. Policy review happens as ordinary code review — `CODEOWNERS`, required approvals, automated linting (§6.3.1) — rather than a manual gate that sits between a developer and production.

Visibility doesn't stop at what was *approved* — vDefend's IDS/IPS and Malware Prevention detections feed directly back into that same review loop: detected-but-not-yet-blocked lateral movement attempts become backlog items for the next `FirewallPolicy` tightening PR (§6.4), giving SecOps pervasive visibility into east-west traffic and threat intelligence without having to intercept every deployment to get it. The team most likely to feel this shift is the one that used to spend the most time on ticket triage — that time now goes to reviewing pull requests and watching telemetry instead.

### 7.3 The Cloud Admin Experience

For the Cloud Admin managing the shared infrastructure underneath every tenant, the isolation guarantees from §4.1 are what make multi-tenancy something to configure once rather than police continuously. Namespace boundaries, RBAC, and quota are enforced by the Kubernetes API server itself, not by a convention any individual admin has to remember or a dashboard they have to watch — a tenant cannot reach another tenant's `FirewallPolicy` objects, collide with another tenant's IP or routing space, or exceed its own quota, by construction. Disparate business units and even external customers can share the one VCF instance with no overlapping IPs, no routing collisions, and no cross-tenant visibility risk to reason about case by case. The one place a single tenant's action *could* affect others — a shared Transit Gateway — is deliberately kept out of tenant hands: `TGWFirewallPolicy` and its `TGWSecurityConfig` master switch (§4.2, §5.2.10) are routed through the platform team's own `AppProject`/module, so cross-tenant blast radius stays a design decision the Cloud Admin controls, not a risk every tenant self-service action reintroduces. The result is a shared platform the Cloud Admin can scale by onboarding more tenants, not one that requires proportionally more oversight per tenant added.

---

## 8. Business Outcomes and ROI

### 8.1 Accelerated Time-to-Market

The core economic effect of this model is collapsing the security step of a deployment from a ticket-queue wait measured in days or weeks to a pull-request merge measured in minutes. Every step in §7.1's worked example — from empty namespace to fully micro-segmented three-tier application — happens without a single request to a person outside the tenant's own team. Time that used to go to waiting goes to shipping instead.

### 8.2 Reduced Risk and Blast Radius

Default-deny micro-segmentation, applied per application tier and enforced at the vNIC (§3.2), means a compromised workload's lateral movement options are limited to exactly what an explicit `FirewallPolicy` rule allows — not "anything else on the subnet." That's the difference between an incident touching one workload and an incident touching the ransomware's entire path through the environment: pervasive, default micro-segmentation is what neutralizes lateral movement for both commodity ransomware and more patient Advanced Persistent Threats (APTs), because there's no open subnet left for either to move across. The same containment applies at the tenant level: namespace-scoped isolation (§5.2.1) makes "one namespace = one blast radius" a day-0 default, and the Provider-tier controls on shared Transit Gateway firewalling (§4.2, §7.3) keep a single tenant's incident from becoming a cross-tenant one. Combined with the tag-driven automated quarantine pattern in §6.4, the time between "threat detected" and "workload isolated" shrinks from an incident-response ticket to a single reconciliation cycle.

### 8.3 Operational Efficiency

Eliminating manual, per-change security provisioning removes a standing operational cost, not just a one-time inconvenience. Every ticket that no longer needs triaging, every change-approval meeting that no longer needs to happen for a routine micro-segmentation update, and every dollar no longer spent maintaining legacy hardware firewall clusters and the complex VLAN/routing schemes built to route traffic to them (§2.2–§2.3) is OpEx that doesn't recur next quarter — capacity and change management scale with software-defined, API-driven policy instead (§3.2). The hybrid Terraform/Argo CD model (§6.3.3) means day-0 provisioning and day-2 policy management both run through the same lightweight automation a platform team already operates, rather than a separate security-specific toolchain.

### 8.4 Simplified Compliance

Because every policy change in this model is a reviewed, versioned, attributable Git commit (§6.3.1, §7.2), continuous compliance evidence for frameworks like PCI-DSS and HIPAA is a byproduct of the normal workflow rather than a separate audit-prep exercise. Enforced, automated global policies — the Provider-tier `SecurityProfile` catalog and default-deny baselines from §4.2 — apply uniformly across every tenant without relying on each tenant remembering to configure them correctly, which is precisely the kind of consistent, demonstrable control multi-tenant compliance frameworks look for.

---

## 9. Conclusion

This paper's journey started with a dilemma — DevOps speed against zero-trust rigor — and the resolution isn't a compromise between the two, it's an architecture that stops treating them as opposites. VCF Automation's CCI gives every Organization its own self-service vDefend surface: `NetworkSecurityGroup`/`VPCNetworkSecurityGroup` for reusable workload membership, `SecurityProfile`/`SecurityProfileAttachment` for VPC-wide enforcement posture, `FirewallPolicy` / `VPCGatewayFirewallPolicy` / `TGWFirewallPolicy` for the three real enforcement points, plus the supporting kinds in §5.2.7–§5.2.12 — scoped, isolated, and safe per tenant by construction (§4.1), reachable directly by `kubectl` from the moment a Project exists (§5.1), and automatable at fleet scale with the Terraform, Ansible, and Argo CD skills a platform team already has (§6).

**The final thought is the one worth remembering:** by moving enforcement into the hypervisor and wrapping it in standard APIs and self-service automation, security stops being a checkpoint someone has to clear and becomes an invisible, ambient property of the platform itself — consumed seamlessly through the same multi-tenant, self-service surface as everything else. VCF with vDefend doesn't just secure applications — it transforms security from an operational friction point into a business enabler, measured the same way the rest of the business measures itself: faster time-to-market, lower operational cost, and demonstrable, continuous compliance, not just fewer incidents.

**Where to go next:** walk through the full worked example in §7.1 against a lab tenant, then use §5.2 as the field reference while embedding these objects into your own VCF Automation blueprints. For deeper technical detail on any object or automation pattern in this paper, see the References below — and if you're evaluating this hands-on, the VMware/Broadcom Hands-on Lab catalog for VCF and vDefend is the fastest way to try the model in a real environment before building the pipeline in §6 for production.

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
- Ansible Documentation — [`kubernetes.core.k8s` module](https://docs.ansible.com/ansible/latest/collections/kubernetes/core/k8s_module.html)
