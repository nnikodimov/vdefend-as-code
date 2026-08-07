# Architecting Multi-Tenant Security with VCF Automation & vDefend
### API-Driven Self-Service Protection for Organizations and Applications

---

## 1. Executive Summary

Private cloud is being re-platformed around a simple expectation: application teams should be able to request infrastructure — and the security that protects it — the same way they consume any other cloud service. In VMware Cloud Foundation (VCF) 9.1, that expectation is met by pairing VCF Automation (VCFA), the platform's Kubernetes-native consumption layer, with **vDefend**, VCF's built-in network and workload security stack. Together they let a platform team define a small set of vetted security postures once, and let tenants attach, switch, and scope those postures to their own Projects, VPCs, namespaces, and applications — without filing a ticket to a network security team.

This paper is written for cloud and platform architects who already know their way around VCFA and vDefend and want a concrete design pattern for wiring the two together to embed zero-trust security directly into self-service cloud templates, Kubernetes manifests, and Infrastructure-as-Code pipelines. It is a blueprint for:

- **Declarative APIs:** Exposing vDefend security features available for VCFA tenants through the Cloud Consumption Interface (CCI) and standard Kubernetes Custom Resource Definitions (CRDs).
- **Layered Multi-Tenancy:** Layering VCFA constructs, like namespaces and applications with Virtual Private Cloud (VPC) and vDefend security posture, so that Providers can properly plan and impose the required infrastructure guardrails, while preserving the tenants' flexibility to define their individual applications' protection without interfering with the infra-wide security baseline.
- **Day-0 Security Baseline:** Enforcing security policies at resource creation time so that workloads are protected immediately upon deployment.
- **Automated Lifecycle Operations:** Delivering end-to-end policy management using Terraform for Day-0 and Day-1 deployment, and Argo CD for Day-2 continuous GitOps reconciliation.

The result is a model where security is not a gate that slows down self-service infrastructure — it is one of the things being self-served, inside guardrails the platform team controls centrally and exposes through the same API surface as compute, network, and storage.

---

## 2. Introduction

VCFA turns a VCF private cloud into something application teams can consume the way they consume a public cloud: Projects for tenant boundaries, VPCs and Namespaces for network and workload scoping, and catalog items for repeatable deployment patterns. The pressure this creates for platform teams is familiar from every public-cloud adoption curve — velocity expectations rise faster than the platform team's ability to hand-hold every request. 
Security is usually where that pressure breaks something. If every new tenant, VPC, or application requires a security engineer to author the workload protection by hand, self-service infrastructure just relocates the bottleneck instead of removing it—provisioning is instant, but the workload sits unprotected (or blocked) until security work catches up.

### 2.1 Problem statement

To build a scalable multi-tenant VCF environment, platform and security teams must address four critical operational areas:

- **Deployment Velocity:** While compute, storage, and networking are provisioned automatically, security policy creation often remains manual, making security the primary operational delay.
- **Scalability:** Manual firewall rule authoring does not scale with the rate of infrastructure creation that self-service platforms are designed to enable.
- **Consistency:** Hand-authored firewall rules vary in structure and quality across tenants, creating configuration drift and potential security gaps.
- **Tenant Autonomy:** Application teams lack direct visibility into their security posture, requiring support tickets for routine changes such as opening an application port.

### 2.2 Design Goals

The purpose of this document is to address the challenges mentioned above by focusing on the following design objectives.

- **Baseline Protection:** To eliminate post-deployment security gaps and reduce potential blast radius, workloads should be provisioned with a defined security posture, not provisioned open and protected later.
- **Guardrailed Self-Service:** Tenants select and adjust security settings from pre-vetted platform profiles rather than authoring low-level firewall rules from scratch.
- **API-First Consumption:** Deliver security posture via constructs exposed as declarative resources through the Cloud Consumption Interface (CCI), making them accessible using standard tools like kubectl, Terraform, or GitOps controllers.
- **Delivery Speed:** Transition Security updates from manual ticket queues to automated Git pull request workflows, reducing policy approval timelines from days to minutes.
- **Compliance by Design:** Security policy changes are version-controlled, automatically generating auditable records for regulatory frameworks such as PCI-DSS and SOC 2.

### 2.3 Scope and assumed reader knowledge

This paper assumes the reader is already familiar with VCFA and its multi-tenancy model (Organizations, Projects, Namespaces, VPCs) and with vDefend fundamentals (the Distributed Firewall, Gateway Firewall, and the general concept of Security Profiles). It does not re-introduce those concepts from first principles.

---

## 3. Anatomy of a Multi-Tenant VCF Private Cloud

Before any security design can be expressed as code, it needs a precise map of what is being secured. This section establishes that map in three steps: the VCFA constructs a tenant actually consumes and what each one becomes in vSphere and NSX (§3.1), the vDefend security constructs layered on top of them (§3.2), and the RBAC model that decides who may change which of those constructs (§3.3).

### 3.1 From VCFA Abstractions to vSphere and NSX

VCFA maps tenant management abstractions directly into native vSphere and NSX constructs to deliver isolated, multi-tenant cloud environments. The vSphere Supervisor acts as the primary control plane and translation engine, converting raw ESXi, vSAN, and NSX infrastructure into a declarative, Kubernetes-native cloud fabric. A tenant never provisions an NSX segment or a vSphere resource pool by hand — they declare an intent against VCFA, and the Supervisor renders it into the fabric objects underneath.

```
Organization                    the tenant — an identity, governance and quota domain
 │
 ├─ Region                      one or more Supervisors and the vSphere/NSX fabric behind them
 │
 └─ Project                     the consumption boundary a tenant's users work inside
      │
      ├─ VPC                    the tenant's own routed network domain
      │    └─ Subnet(s)         the address space workloads actually land on
      │
      └─ Supervisor Namespace(s)   bound to exactly one VPC: dedicated (1:1) or shared (N:1)
           ├─ VirtualMachines   VM Service VMs
           ├─ VKS cluster(s)    conformant Kubernetes; nodes are VMs on the same VPC subnets
           │    └─ Pods         scheduled by the cluster itself, behind its own CNI
           └─ vSphere Pods      containers running natively on ESXi
```

**Organization.** The Organization is the tenant. It is the outermost administrative and identity boundary: users, groups, identity-provider federation, and the total resource allocation a provider is willing to give that tenant all hang off it. On the fabric side, creating a VCFA Organization automatically provisions a corresponding **NSX Project** — the network domain that keeps one tenant's addressing, routing, and policy from colliding with another's. Unlike the constructs below it, the Organization is not itself something a tenant creates or manipulates through the consumption API; it is the container everything else is created *inside*.

**Region.** A Region groups one or more vSphere Supervisors — and the vSphere clusters, storage, and NSX fabric behind them — into a single placement target. It is the answer to "where does this run," and it matters to security design because most vDefend constructs are region-scoped: a security group or a security posture is meaningful within the fabric of one Region, and a tenant spanning two Regions maintains a security definition in each.

**Project.** The Project is where a tenant's users actually work. It carries the quota (CPU, memory, storage, network objects) and the entitlements — which Regions, which namespace classes, which VM and storage classes — that a provider admin grants. Everything a tenant can self-service, including security policy, is scoped inside the Project they own and bounded by those quotas. An Organization may hold several Projects; a common split is one per environment or per business unit.

**Virtual Private Cloud (VPC).** The VPC is what turns a shared physical private cloud into a set of self-contained environments. Realized as an NSX VPC inside the tenant's NSX Project, it owns its own private address space, its own subnets, its own gateway, and optionally its own NAT and load-balancer endpoints — plus an optional attachment to a shared Transit Gateway when the tenant needs routed connectivity to other VPCs. A Project can own more than one VPC. For security purposes the VPC is the key boundary: it is the object a security posture attaches to, and the edge where north-south traffic is evaluated.

**Supervisor (vSphere) Namespace.** The Supervisor Namespace is a Kubernetes resource boundary running on a Supervisor, and it is where workloads are actually deployed. In vSphere it is realized as a resource pool and folder with a namespace class attached — the CPU/memory/storage limits, VM classes, storage classes, and content libraries available inside it. In NSX it is realized as network attachment to a VPC subnet, with every workload's network interface automatically tagged with its owning namespace. Each namespace is bound to exactly one VPC at creation time, but that binding is a per-namespace choice: a **dedicated** VPC serves a single namespace (1:1) for strict isolation, while a **shared** VPC hosts several namespaces (N:1) that pool address space and gateway configuration. §5.2 covers when to choose which.

**Workloads.** VirtualMachines provisioned through VM Service, VKS clusters, and vSphere Pods all land inside a Supervisor Namespace and attach to a subnet of that namespace's VPC. For VMs and vSphere Pods, the network interface is automatically tagged with the owning namespace — which is what makes namespace-scoped security groups work with no manual labeling at all (§5.2).

**VKS clusters.** vSphere Kubernetes Service is how a tenant self-services a conformant Kubernetes cluster without leaving the platform. The cluster is declared inside a Supervisor Namespace like any other object, and the Supervisor provisions its control-plane and worker nodes as VMs — drawing on that namespace's VM classes and storage classes, and attaching to the same VPC subnets as every other workload there. Two consequences matter for security design:

- **A VKS cluster is a nested tenancy layer.** The vDefend constructs in this paper enforce at the node VMs' network interfaces. Traffic *between pods inside the cluster* is governed by the cluster's own Kubernetes network policy and CNI, not by the constructs described here — so a complete design for a tenant running VKS has two policy surfaces to keep consistent, not one.
- **VKS nodes are not covered by the namespace-tag pattern.** Node VMs are grouped through separate, auto-generated tags rather than the namespace tag every other workload carries. The namespace-selector approach in §5.2 therefore does not reach them; plan a distinct grouping strategy wherever VKS is in scope.

Summarized:

| VCFA construct | What the tenant consumes | How it is realized underneath | Who creates it |
|---|---|---|---|
| **Organization** | The tenant boundary; identity and total allocation | An NSX Project, plus a VCFA identity and quota domain | Provider admin |
| **Region** | A place to deploy | One or more vSphere Supervisors and their vSphere/NSX fabric | Provider admin |
| **Project** | Quota, entitlements, and the working scope for a tenant's users | Quota and entitlement scope enforced by the Supervisor | Provider admin, consumed by the tenant |
| **VPC** | A private, routed network with its own address space | An NSX VPC: subnets, gateway, NAT/load-balancer endpoints, optional Transit Gateway attachment | Tenant, within quota |
| **Supervisor Namespace** | A workload and resource boundary | A vSphere resource pool and folder with a namespace class; attached to a VPC subnet, auto-tagged in NSX | Tenant |
| **Workloads** | VMs and vSphere Pods | vSphere VMs and ESXi-native pods on VPC subnet segments, auto-tagged with their namespace | Tenant / application owner |
| **VKS cluster** | A conformant Kubernetes cluster, self-serviced | Control-plane and worker node VMs on the namespace's VPC subnets, using its VM and storage classes; grouped by their own auto-generated tags | Tenant / application owner |

### 3.2 The vDefend Security Constructs Exposed to Tenants

Where §3.1 described the infrastructure a tenant consumes, this section describes the security capabilities layered onto it. vDefend exposes its enforcement engines to VCFA tenants as declarative constructs, so that zero-trust micro-segmentation becomes something a tenant self-manages inside provider-defined boundaries rather than something a network security team hand-configures per request. The concern here is what each construct *is* and what it governs; how each one is addressed as an API object is §4's subject.

**Three enforcement points, one per boundary.** Every rule lands at one of three places in the data path, and each maps onto a construct from §3.1 — which is why the infrastructure hierarchy has to be clear before the security model makes sense:

```
Transit Gateway                    Transit Gateway Firewall
 │                                   VPC ⇄ VPC, across a shared gateway
 │
 └─ VPC                            VPC Gateway Firewall
      │                              north ⇄ south, at the VPC edge
      │
      └─ Supervisor Namespace      Distributed Firewall
           │                         workload ⇄ workload, at each virtual NIC
           ├─ VM
           ├─ VM
           └─ VM
```

**Distributed Firewall (DFW).** The DFW is the innermost and most granular layer. It runs in the hypervisor, at every workload's virtual NIC, which means it inspects traffic between two VMs on the same host and the same subnet — traffic that never touches a physical network device and that a traditional perimeter firewall would never see. This is where micro-segmentation actually happens: tier-to-tier rules inside an application, namespace-to-namespace isolation, and default-deny baselines. Because enforcement is attached to the workload rather than to a network location, a VM carries its policy with it when it migrates, and a newly created VM is covered the moment it powers on if it matches an existing group.

**VPC Gateway Firewall.** At the VPC's own edge, the Gateway Firewall governs north-south traffic — what may enter the VPC from outside, and what workloads inside it may reach beyond it. Where the DFW answers "which of my workloads may talk to each other," the VPC Gateway Firewall answers "what may cross this tenant's perimeter at all." It is the natural home for a tenant's ingress exceptions and controlled egress, and it can also be switched on or off wholesale as part of a Security Profile rather than rule by rule.

**Transit Gateway Firewall.** When a tenant's architecture spans several VPCs attached to a shared Transit Gateway, the Transit Gateway Firewall controls traffic *between* those VPCs — a boundary neither the DFW (intra-VPC) nor the VPC Gateway Firewall (perimeter) is positioned to police. It gives finer control than a blanket connectivity posture, letting a design permit exactly one VPC-to-VPC path (a shared-services VPC reachable on one port, say) while denying the rest. It has a master switch: no Transit Gateway rule enforces anything until the Gateway Firewall feature is explicitly enabled on that gateway. Because the Transit Gateway is shared infrastructure serving multiple tenants, both that switch and review authority over its rules stay platform-owned (§5.5).

**Security Profiles.** A Security Profile packages the two boundary firewalls above into a single named *strategy* for a VPC: whether the north-south Gateway Firewall is on, and which east-west strategy applies. Rather than have tenants author a strategy from scratch, VCFA ships a small, fixed catalog of pre-created, **system-owned** profiles, ranging from no restriction through full VPC isolation. A profile does nothing until it is attached to a specific VPC. This is the highest-leverage construct in the whole model, because it reduces a tenant's entire VPC posture to one small object that can be reviewed in a pull request and audited from Git history — with no free-text rule authoring exposed to the tenant at all. §5.1 walks the full strategy catalog.

**Groups — the reusable "who".** Rules never name workloads directly; they name groups. Groups are intent-based rather than address-based: a group is defined by label selectors, namespace membership, VM property matches, static IPs or CIDRs, or nested references to other groups — and the platform re-evaluates membership continuously as workloads come and go. A group meaning "every VM labeled `tier: app`" never needs editing when a VM is added, removed, or re-IP'd. Groups come in two scopes: a Region-scoped group, referenced by Distributed Firewall and Transit Gateway rules, and a VPC-scoped group, referenced by VPC Gateway rules. Because VCFA auto-tags every VM and vSphere Pod with its owning namespace (§3.1), per-namespace grouping requires no labeling work at all.

**Labels — how membership is decided, and who may decide it.** A label applied to a workload in VCFA is translated into an **NSX tag** on that workload, and it is the tag that a group's selector ultimately matches. Labels are therefore not cosmetic metadata: they are part of the security boundary, because whoever can set a label can change which rules a workload falls under.

VCFA handles that by giving certain labels their own RBAC. **Privileged labels** — also called **protected labels** — are a distinct class whose application, modification, and removal are permission-controlled rather than freely settable by whoever owns the workload:

- **Ordinary labels** can be set by whoever owns the workload. An application owner tags their own VMs `tier: web` or `app: payments`, a group selects on it, and nobody else needs to be involved.
- **Privileged (protected) labels** are defined and assigned at the Organization tier — by the **Organization Admin** or **Organization Security Admin**, not by the application owner whose workload carries the label. That is what makes them useful as a boundary: an application team cannot mark its own workload as in-scope for a compliance policy, nor strip a marker that puts it under one.

Both kinds become NSX tags and are selected on identically; the difference is purely who is authorized to set them. This is the significance of the `protected/` label prefix in §5.3 and §5.4's examples — those groups are keyed to labels an application owner cannot reassign at will. Note that the boundary here is *within* a tenant, not between tenant and provider: protected labels are the tenant's own admins' instrument for governing their application teams, which is what makes a tenant-authored security baseline hold up against the teams operating inside it. Without that split, anyone able to label a VM could label their way into or out of any group, and the tiering described below would be advisory rather than enforced.

**Services — the reusable "what".** Where groups are the "who," services are the "what": named protocol and port definitions (TCP/UDP port sets, ICMP, raw IP protocols, ALG protocols) that any rule can reference by name. Defining "the application's ingress ports" once and referencing it from several policies keeps port literals out of individual rules, so a change to an application's port set is a single edit rather than a sweep across every policy that mentioned it.

Summarized:

| Security construct | What it governs | Where it enforces | Typically owned by |
|---|---|---|---|
| **Distributed Firewall** | East-west traffic between workloads | In the hypervisor, at each workload's virtual NIC | Shared: platform baselines, tenant micro-segmentation |
| **VPC Gateway Firewall** | North-south traffic in and out of a VPC | At the VPC edge | Tenant, within the attached Security Profile |
| **Transit Gateway Firewall** | Traffic between VPCs on a shared gateway | At the shared Transit Gateway | Platform / Security Admin |
| **Security Profile** | A VPC's whole posture, as one named strategy | Generates policy at the VPC edge and east-west | Catalog: platform. Selection: tenant |
| **Group** | Which workloads a rule applies to | n/a — referenced by rules | Platform for shared groups, tenant for app groups |
| **Label** | Which workloads fall into a group; translated to an NSX tag | n/a — an attribute of the workload | Ordinary: workload owner. Privileged/protected: Organization Admin or Organization Security Admin |
| **Service** | Which protocols and ports a rule matches | n/a — referenced by rules | Platform for common services, tenant for app-specific |

**Categories set evaluation order, so the tiering is enforced rather than conventional.** Every firewall policy carries a category — Infrastructure, Environment, or Application — and those categories evaluate top-down in that fixed order: fabric-level rules in Infrastructure, macro-segmentation (blocking Prod from ever reaching Dev, say) in Environment, and tenant micro-segmentation in Application. A global rule authored by a Security Admin is therefore always checked before any Application-category rule a tenant writes. This ordering is what makes the two-tier model below structural rather than a matter of trust.

**Two tiers of ownership.** Isolating tenants from each other is only half the model. Inside a tenant's boundary, VCFA splits control so a platform-wide baseline cannot be quietly overridden, while tenants still get immediate control of their own micro-segmentation:

- **Provider / Security Admin tier.** Rules that must apply to every tenant regardless of what any individual tenant wants are defined centrally and delivered through the system-owned Security Profile catalog and Infrastructure/Environment-category policies. A policy that a Security Profile generates cannot be edited, nor can rules be appended to it — the only supported customization path is a **separate**, higher-priority policy evaluated *before* it. That constraint is deliberate: it keeps the system-owned baseline tamper-evident. §5.6 covers this delegation boundary in full; §5.1 shows it in practice.
- **Tenant tier.** Everything below that baseline is delegated to the Organization. Its own admins select the VPC's Security Profile, define the protected labels their application teams must live with, and set any Organization-wide policy; below them, application owners label their workloads with ordinary labels and create their own groups and Application-category policies to segment their application tiers, with no involvement from anyone per change.

The tenant tier is therefore not flat. A tenant Organization runs the same guardrail pattern internally that the provider runs above it — protected labels and Organization-wide policy in place of the system profile catalog — which is what lets a large tenant delegate to its own application teams without giving up a baseline.

This split maps directly onto the tooling ownership model §7.5 formalizes: Terraform and the platform team own the Infrastructure/Environment-category baselines and the system profile bindings; Argo CD, watching a tenant's own Git path, owns the Application-category policy that tenant iterates on.

### 3.3 Who Can Change What: The RBAC Model

The two-tier model in §3.2 only holds if it is enforced by the platform rather than observed by convention. In VCFA it is enforced by the CCI API server itself, through ordinary Kubernetes authorization primitives — which means a tenant cannot exceed their boundary even with a hand-crafted API call, a rogue script, or a misconfigured pipeline.

**Three mechanisms stacked together** are what stop Organization A from touching Organization B's security posture:

1. **Project boundary.** Every security object a tenant creates lands in the namespace representing their own Organization/Project. Because policies and groups reference their targets by name and label rather than by placement, the tenancy boundary is a namespace boundary — and namespaces are the unit Kubernetes authorization already understands.
2. **RBAC.** A tenant's kubeconfig context is bound to role bindings scoped to their own namespace(s) only. The API server — not an application-layer check that could be bypassed — rejects any request against a namespace the token is not bound to.
3. **Quota.** Even inside their own namespace, a tenant cannot exceed the network and compute limits a provider admin set at Project creation. Self-service has a ceiling, and that ceiling is set outside the tenant's reach.

Together these make "self-service" and "safe" the same sentence, enforced by the API server rather than by policy documents.

**Roles and what each one owns.** VCFA's role bindings partition the constructs from §3.1 and §3.2 across two provider-side and two tenant-side personas — the split matters, because the tenant side has its own internal guardrail tier, not just a single "tenant" identity:

| Role | Owns | Cannot |
|---|---|---|
| **Cloud Admin** (provider) | Organizations, Regions, Projects, quotas, namespace classes, zone and region association — the guardrails that exist *before* any tenant gets self-service access | — |
| **Provider Security Admin** | The system Security Profile catalog and org-wide default strategy; Transit Gateway security config and connectivity profiles; `Infrastructure`/`Environment`-category baselines; review authority over anything affecting more than one tenant | Typically holds no workload-provisioning rights — separation of duties runs both ways |
| **Organization Admin / Organization Security Admin** (tenant) | Their Organization's Projects, VPCs, and Supervisor Namespaces; selecting and switching a VPC's Security Profile; toggling the Gateway Firewall; **defining and assigning protected labels**, and the Organization-wide policy keyed to them | Cannot invent a VPC-level strategy outside the provider's catalog, or edit a profile-generated policy |
| **Application Owner / Developer** (tenant) | Workloads and their *ordinary* labels; `Application`-category groups and policies inside their own namespace | Cannot set or remove a protected label, bypass namespace isolation, or override the VPC-level posture above them |

Each persona receives a kubeconfig context scoped to exactly the namespaces their bindings allow, so the same credential that lets a developer deploy a VM is the credential that constrains which security objects they can see at all. Nothing outside their scope is visible, let alone writable — which is what makes it safe to hand tenants a raw Kubernetes API endpoint in the first place (§4.1).

**The same principle applies to automation identities, not just people**, and it carries directly into §6 and §7: a Terraform CI runner's CCI token and the Argo CD cluster credential should each be scoped to only the tenant namespace(s) they manage — never a Project-wide or Region-wide credential, even when the pipeline itself is platform-owned. A pipeline with broader rights than the humans it serves quietly undoes the whole model.

---

## 4. Consuming vDefend Through the CCI API

§3.2 described *what* the vDefend security constructs are. This section covers *how* they are addressed: the API surface a tenant, a Terraform run, or a GitOps controller actually talks to. It is deliberately short — reference material to make §5–§8 legible, not the paper's main subject. The field-by-field spec is in Appendix A.

### 4.1 CCI as a Standard Kubernetes API Server

VCFA's **Cloud Consumption Interface (CCI)** is a real Kubernetes API server, not a proprietary REST API with a UI bolted in front of it — a developer-centric IaaS consumption layer that aggregates multi-cluster vSphere Supervisors into a single, unified API endpoint. A tenant (or a pipeline) authenticates and receives a **kubeconfig context scoped to their own Supervisor Namespace** — nothing else is visible — via a token exchange (the `vcfa_kubeconfig` Terraform data source is the mechanism §6 uses). From there, any standard Kubernetes tooling works against it directly: `kubectl`, any Kubernetes client library, Terraform's `kubernetes` provider, or a GitOps controller like Argo CD. No vDefend-specific SDK is required.

In CCI, the Organization acts as the parent container for VCFA Projects: authentication tokens (whether from a `kubectl` login flow or a Terraform run) evaluate against a user or pipeline's assigned Organization and Project membership. The Organization itself is an administrative and identity domain managed at the VCFA governance tier, so — unlike the Project (`project.cci.vmware.com`, §4.2) — it is not instantiated as its own Kubernetes Custom Resource Definition (CRD).

### 4.2 The API Groups

CCI presents the constructs from §3 across a handful of API groups, split by who owns them:

| API group | Purpose |
|---|---|
| `project.cci.vmware.com/v1alpha2` | Tenant Project definition (the top-level multi-tenancy boundary) |
| `infrastructure.cci.vmware.com` | Namespace classes, quotas, zone/region association — the guardrails a provider admin sets before self-service access |
| `authorization.cci.vmware.com` | RBAC / role bindings scoped to a Project or namespace |
| `vpc.nsx.vmware.com/v1alpha1` | **VPC networking and security**: `VPC`, `Subnet`, `NetworkSecurityGroup`/`VPCNetworkSecurityGroup`, `NetworkService`, `SecurityProfile`/`SecurityProfileAttachment`, `FirewallPolicy`, `VPCGatewayFirewallPolicy`, `TGWFirewallPolicy`/`TGWSecurityConfig`, `VPCConnectivityProfile`/`Binding` |
| `vmoperator.vmware.com/v1alpha3` | VM lifecycle — the workloads the security policy protects |

Everything this paper automates lives in `vpc.nsx.vmware.com/v1alpha1`. The practical consequence is that a tenant needs no vDefend-specific client: the same `kubectl apply`, the same Terraform `kubernetes_manifest`, and the same GitOps controller that handle a Deployment handle a `FirewallPolicy`.

### 4.3 Security Capabilities and the Kinds That Express Them

Each capability from §3.2 is addressed through one or two custom resource kinds:

| Capability (§3.2) | Kind(s) | Notes |
|---|---|---|
| Distributed Firewall | `FirewallPolicy` | East-west rules; `spec.category` sets evaluation order |
| VPC Gateway Firewall | `VPCGatewayFirewallPolicy` | North-south, per-VPC; requires both a Region and a VPC reference |
| Transit Gateway Firewall | `TGWFirewallPolicy` + `TGWSecurityConfig` | Inert until `TGWSecurityConfig` enables `GatewayFirewall` on the gateway |
| Security Profile | `SecurityProfile` + `SecurityProfileAttachment` | The profile is inert; the attachment binds it to a VPC |
| Group | `NetworkSecurityGroup` (Region-scoped) / `VPCNetworkSecurityGroup` (VPC-scoped) | Gateway rules reference the VPC-scoped kind; DFW and TGW rules the Region-scoped one |
| Service | `NetworkService` | Referenced by name from any rule's service list |
| Label | *(no kind of its own)* | An attribute on the workload object; groups select on it |
| VPC connectivity posture | `VPCConnectivityProfile` + `Binding` | Governs what is *routable* before any rule governs what is permitted |

**Where these objects live.** This is the detail most often assumed wrongly. Security objects are *not* nested inside the VPC or the Supervisor Namespace they protect. They are created in the tenant's own namespace representing the whole Organization/Project, and they point at their target by name or label selector:

```
Project  (the tenant's own namespace — where every object below is created)
 │
 ├─ SecurityProfile + SecurityProfileAttachment    ── attaches a posture to ──>  a VPC
 ├─ NetworkSecurityGroup / VPCNetworkSecurityGroup ── selects ──>  workloads, by label / IP / nesting
 ├─ NetworkService                                 ── referenced by ──>  any rule's service list
 ├─ FirewallPolicy                                 ── enforced at ──>  the Distributed Firewall
 ├─ VPCGatewayFirewallPolicy                       ── enforced at ──>  the VPC gateway
 └─ TGWFirewallPolicy (+ TGWSecurityConfig)        ── enforced at ──>  the shared Transit Gateway
```

A `FirewallPolicy` targets a particular namespace's workloads through a label selector or a VPC/Region reference in its spec — not by being created inside that namespace. The enforced tenancy boundary therefore sits at the Organization's own namespace, which is exactly what §3.3 secures.

### 4.4 How the Kinds Compose

```
NetworkSecurityGroup (regionName)     --referenced by--> FirewallPolicy (east-west, intra-VPC)
                                                          TGWFirewallPolicy (east-west, inter-VPC)

VPCNetworkSecurityGroup (vpcName)     --referenced by--> VPCGatewayFirewallPolicy (north-south)

NetworkService                        --referenced by--> any rule's services[] (all three firewall kinds)

SecurityProfile  --bound to a VPC via--> SecurityProfileAttachment  --governs posture of--> that VPC

TGWSecurityConfig (GatewayFirewall: true)  --gates enforcement of--> TGWFirewallPolicy
```

A group object is the only thing the three firewall-policy kinds *require* to express meaningful rules; `SecurityProfile` is orthogonal, and inert until attached. This composition is exactly what §6.3's Terraform baseline and §7.3's Argo CD `ApplicationSet` provision and reconcile, respectively.

### 4.5 A Note on Source Grounding

The schema in this paper is confirmed against a running VCF 9.1 environment (live `kubectl get` output, reproduced in §5) rather than assumed from documentation alone. The authoritative, current reference is Broadcom's published CCI API documentation at `developer.broadcom.com/xapis/cci-api` (linked in Appendix C) — check it directly before an automation module hard-codes an assumption this paper doesn't cover.

---

## 5. Use Cases and Design Patterns for vDefend Security

Each subsection below walks through one concrete use case for consuming vDefend security through the VCFA Consumption API: what a tenant needs, the design pattern that solves it, and the API objects that implement it — confirmed against a live VCF 9.1 environment. §6 and §7 then show how Terraform and Argo CD actually deliver each pattern; this section stays at the level of the API itself.

### 5.1 VPC Segmentation via vDefend Security Profiles

The foundation of the self-service model is a small, fixed catalog of **system-defined Security Profiles**, each representing a named security *strategy* for a VPC's north-south and VPC-to-VPC traffic. A Tenant Admin does not write DFW rules — they select a strategy, and the platform materializes the underlying policy.

The five strategies, from most to least restrictive:

| Strategy | VPC outbound | VPC inbound | VPC-to-VPC | Notes |
|---|---|---|---|---|
| **None (Default)** | Allowed | Allowed | Allowed | No profile-level restriction; workload-level policy is the only control |
| **VPC Isolation** | Blocked | Blocked | Blocked | Workloads within the VPC may still talk to each other (Jump to Application) |
| **VPC Isolation with Essential Services** | Blocked, except DNS/NTP/DHCP/ICMP | Blocked, except DNS/NTP/DHCP/ICMP | Blocked | Same as above, plus essential infra services are allowed both ways |
| **VPC External Connectivity** | Allowed | Blocked, except Essential Services | Blocked | A VPC that needs to originate connections out but stay closed to inbound |
| **VPC Secure Connection** | Allowed | Blocked, except Essential Services | **Allowed** | Adds controlled VPC-to-VPC (e.g., shared-services) connectivity on top of External Connectivity |

Every strategy ends its rule table the same way: traffic that isn't explicitly permitted at the VPC boundary is either dropped, or handed off with a **Jump to Application** action — meaning the VPC-level profile defers the final decision to whatever `FirewallPolicy` exists at the Application category. This two-tier model — a coarse, tenant-selected VPC posture, plus a fine-grained, workload-scoped application policy — is what lets a single Security Profile catalog serve very different applications safely.

The architectural payoff: a tenant's entire VPC security posture is one small, human-readable object — the `SecurityProfileAttachment`. It can be reviewed in a pull request, reconciled by a GitOps controller, and audited from Git history — with no free-text firewall rule authoring exposed to the tenant at all.

**API example.** A Tenant Admin (or their automation) reads the available profiles and the current attachment for their VPC:

```bash
vcf context use <org-name>
kubectl get securityprofiles
kubectl get securityprofileattachments
```

On a live region this confirms exactly five system-owned profiles: `default--<region>` for `none`, plus one for each of the four strategies above. Switching a VPC to a different strategy is a single declarative patch against the attachment — not a rule rewrite:

```bash
kubectl patch securityprofileattachment vpc-dev -p \
  '{"spec":{"securityProfileName": "system-security-profile-2--m01-reg01"}}'
```

A platform team can also designate an org-wide default strategy and independently toggle the VPC Gateway (north-south) Firewall for a profile:

```bash
kubectl patch securityprofile system-security-profile-4--m01-reg01 -p \
  '{"spec":{"isDefault": true}}'

kubectl patch securityprofile system-security-profile-4--m01-reg01 -p \
  '{"spec":{"northSouthFirewall": {"enabled": true}}}'
```

And a new VPC is itself just a declarative object:

```yaml
apiVersion: vpc.nsx.vmware.com/v1alpha1
kind: VPC
metadata:
  name: vpc-staging
spec:
  loadBalancerVPCEndpoint:
    enabled: true
  privateIPs:
    - 10.10.0.0/16
  regionName: m01-reg01
```

**Confirmed limitations:** the "VPC Isolation" strategy's interaction with private-VPC-subnet workloads exposed via DNAT or a load balancer needs to be verified in your own environment rather than assumed; "VPC Secure Connection" does not extend to private-VPC-subnet workloads' cross-VPC communication; and a `FirewallPolicy`/`VPCGatewayFirewallPolicy` generated by a profile cannot be edited directly — customization requires a **separate**, higher-priority policy authored *before* it, never a patch to the generated policy itself.

### 5.2 Namespace Segmentation

Every Supervisor Namespace is tied to exactly one VPC and one namespace class at creation time, but that VPC assignment is a per-namespace choice, not a fixed platform rule — VCFA supports two design blueprints, and a platform team can mix both within the same Project:

- **Dedicated VPC** — one VPC per namespace (or per small group of namespaces), for stricter isolation. Namespace segmentation and VPC segmentation are the same boundary here, so the Security Profile attached to the VPC *is* the namespace's security posture (§5.1), and there is no need to layer a separate namespace-scoped `FirewallPolicy` on top for east-west isolation between namespaces — there's only ever one namespace in the VPC to isolate from.
- **Shared VPC** — multiple namespaces share one VPC's address space and gateway, for cases where network separation between those namespaces isn't required. This is the common case for a "prod" VPC hosting several related application namespaces (e.g., `prod01`, `prod02`) that want to share transit/gateway configuration and quota pooling, but still need their own east-west isolation from each other without provisioning a VPC per namespace.

The decision is fundamentally about isolation versus sharing: pick Dedicated VPC when a namespace needs its own network boundary (e.g., a namespace whose tenant, compliance scope, or blast-radius requirement doesn't tolerate sharing a gateway with anything else); pick Shared VPC when several namespaces belong to the same trust boundary and gain more from pooled quota and simpler topology than from a hard network split. Namespace class (CPU/memory/storage limits, VM classes, storage classes, content libraries) is a separate, parallel provisioning decision from VPC assignment — choosing a namespace class does not constrain or imply which VPC blueprint a namespace uses.

Dedicated VPC namespaces already get `SecurityProfile`-driven isolation for free (§5.1) — there's nothing further to author. The API example below applies to the Shared VPC case: because the VPC-level `SecurityProfile` only governs traffic crossing the *VPC* boundary, namespaces sharing that VPC are otherwise free to reach each other unless a namespace-scoped `FirewallPolicy` says otherwise.

In the Shared VPC model, VCFA auto-tags every workload with its owning namespace (`kubernetes.io/metadata.name`, `nsx-op/vm_namespace`). Because that tag is applied automatically to every existing and future VM deployed into the namespace, a platform team can build namespace isolation once, generically, using a label-selector-based `NetworkSecurityGroup` — no per-workload rule maintenance required:

```yaml
apiVersion: vpc.nsx.vmware.com/v1alpha1
kind: NetworkSecurityGroup
metadata:
  name: prod01-namespace
spec:
  regionName: m01-reg01
  vmSelectors:
    - labelSelector:
        matchLabels:
          nsx-op/vm_namespace: prod01-8sg7f
---
apiVersion: vpc.nsx.vmware.com/v1alpha1
kind: FirewallPolicy
metadata:
  name: namespace-isolation-prod01
spec:
  regionName: m01-reg01
  category: Environment
  priority: 10001
  appliedTo:
    groupNames: [prod01-namespace]
  stateful: true
  tcpStrict: true
  rules:
    - name: rule-01
      direction: InOut
      action: JumpToApplication
      from: [{ groupName: prod01-namespace }]
      to: [{ groupName: prod01-namespace }]
      services: [{ networkServiceName: Any }]
    - name: rule-02
      direction: InOut
      action: Drop
      from: [{ groupName: Any }]
      to: [{ groupName: Any }]
      services: [{ networkServiceName: Any }]
```

Because this isolation policy lives in the `Environment` category, not `Application` (§3.2), it stays outside the tenant's own RBAC scope (§3.3): a tenant can layer `Application`-category rules on top for cross-namespace exceptions, but cannot edit the isolation baseline itself. Together, this pair makes "one namespace = one blast-radius" true before the first workload ever lands.

**Confirmed limitation:** the namespace-tag grouping pattern does **not** work for VKS cluster nodes (grouped via separate, auto-generated tags instead) or for workloads on a *shared* VPC subnet — plan a separate grouping strategy for those before assuming one pattern covers a whole tenant.

### 5.3 Application Segmentation & Ringfencing

The final, finest-grained tier is the application itself. Where namespace isolation answers "can namespace A talk to namespace B," application ringfencing answers "which of the workloads inside my own namespace can talk to each other." The pattern mirrors namespace segmentation but groups on an explicit label instead of the auto-assigned namespace tag.

This is the layer where "self-service security" is most literal: labelling a VM is all it takes to place it inside a ringfence, and through a thin abstraction (a catalog item, a Terraform module, or a GitOps overlay — §6 and §7) the app-scoped `NetworkSecurityGroup` and `FirewallPolicy` follow — with nobody touching NSX Manager or filing a firewall-change ticket.

Whether that label is an ordinary one or a **protected** one (§3.2) is the design decision worth making deliberately. An ordinary label lets the application team place and move their own workloads freely — maximum autonomy, but a team can also label its way out of its own ringfence. A protected label, assigned by the Organization Admin or Organization Security Admin, makes the ringfence something the application team operates *inside* rather than *controls*. The examples below use the protected form, which is the right default whenever the ringfence exists to satisfy an obligation the tenant's own security owner is accountable for.

Where an application maps one-to-one onto a namespace, application segmentation is namespace segmentation (§5.2) by another name. Where it doesn't — an app spanning multiple namespaces, or a namespace hosting multiple apps that shouldn't reach each other — **app ringfencing** groups by that label instead of the namespace tag:

```bash
kubectl label virtualmachines prod01-vm01 protected/app01=backend
kubectl label virtualmachines prod01-vm03 protected/app01=frontend
```

```yaml
apiVersion: vpc.nsx.vmware.com/v1alpha1
kind: NetworkSecurityGroup
metadata:
  name: app01
spec:
  regionName: m01-reg01
  systemOwned: false
  vmSelectors:
    - labelSelector:
        matchExpressions:
          - key: protected/app01
            operator: Exists
      namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: prod01-8sg7f
```

The paired `FirewallPolicy` layers cleanly — intra-app allow, a specific inbound allow, a specific outbound allow, then a drop-all lockdown:

```yaml
apiVersion: vpc.nsx.vmware.com/v1alpha1
kind: FirewallPolicy
metadata:
  name: app01-ringfencing
spec:
  regionName: m01-reg01
  category: Application
  priority: 10002
  appliedTo:
    groupNames: [app01]
  rules:
    - name: allow-app01-intra
      direction: InOut
      action: Allow
      from: [{ groupName: app01 }]
      to: [{ groupName: app01 }]
      services: [{ networkServiceName: Any }]
    - name: allow-https-inbound
      direction: In
      action: Allow
      from: [{ groupName: Any }]
      to: [{ groupName: app01 }]
      services: [{ networkServiceName: HTTPS }]
    - name: allow-dns-outbound
      direction: Out
      action: Allow
      from: [{ groupName: app01 }]
      to: [{ groupName: Any }]
      services: [{ networkServiceName: DNS }, { networkServiceName: DNS-UDP }]
    - name: app01-lockdown
      direction: InOut
      action: Drop
      from: [{ groupName: Any }]
      to: [{ groupName: Any }]
```

### 5.4 Day-0 Provisioned Security

The pattern above (label → group → policy) generalizes into the mechanism that makes security "out-of-the-box" rather than bolted on after deployment: the protecting label is applied **at VM creation time**, as part of the VM Service spec, so the workload is a member of its security group — and therefore covered by its firewall policy — from the moment it powers on. Because the group and its lockdown policy already exist (provisioned as part of tenant/environment onboarding), there is no window between "VM boots" and "VM is protected."

The tightest version of "secure by default" skips the gap between "workload exists" and "workload is grouped" entirely by assigning the protecting label *at deployment time*, not as a follow-up step:

```yaml
apiVersion: vmoperator.vmware.com/v1alpha5
kind: VirtualMachine
metadata:
  name: dev01-vm01
  namespace: dev01-y3fp4
  labels:
    vm-selector: dev01-vm01
    protected/env: dev
spec:
  className: best-effort-xsmall
  imageName: vmi-9a6ad929557aca964
  storageClass: ftt0-storage-policy
  powerState: PoweredOn
```

Paired with a `NetworkSecurityGroup` selecting `protected/env: dev` and an `Environment`-category `FirewallPolicy` (jump-to-application intra-group, allow outbound, drop everything else) provisioned *before* any workload exists, the VM is born inside its governing policy — there is no window where it's powered on but unprotected, and no manual step for an app owner to remember. This is the pattern to reach for when grouping needs to cut across namespaces by role (`dev`, `staging`) rather than by tenant boundary — the only difference from §5.2's namespace pattern is the selector (`protected/env`, an explicit label) rather than the automatic namespace tag.

### 5.5 Using Transit Gateway (TGW) for Tenant Security

For a tenant whose architecture spans multiple VPCs attached to a shared Transit Gateway, `TGWFirewallPolicy` gives finer control than the blunt Community/Isolated/Promiscuous-style connectivity posture set by a `VPCConnectivityProfile`. It has its own master switch: a `TGWFirewallPolicy` enforces nothing until the Transit Gateway's `TGWSecurityConfig` explicitly enables the `GatewayFirewall` feature. `TGWSecurityConfig` is a platform-owned object, provisioned once alongside the shared `TransitGateway` itself — not per tenant.

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
---
apiVersion: vpc.nsx.vmware.com/v1alpha1
kind: TGWFirewallPolicy
metadata:
  name: acme-shared-services-access
  namespace: acme-prod-ns01
spec:
  regionName: region-a
  category: Default
  rules:
    - name: allow-shared-services-to-acme
      direction: In
      action: Allow
      appliedTo:
        gatewayAttachmentNames: [acme-prod-tgw-attachment]
      from: [{ groupName: shared-services-vpc-egress }]
      to: [{ groupName: acme-app-tier }]
      services: [{ l4PortSet: { l4Protocol: TCP, destinationPorts: ["443"] } }]
    - name: deny-other-vpcs
      direction: In
      action: Drop
```

Tenant-specific `TGWFirewallPolicy` rules carve out exactly which cross-VPC paths a multi-VPC tenant needs. Because a misconfigured rule here can affect traffic between *multiple* tenants' VPCs at once, review authority for these rules stays with the Provider Security Admin (§3.3) rather than the tenant alone.

### 5.6 Delegation Model and Guardrails-as-Code

Pulling 5.1–5.5 together, the delegation boundary looks like this:

| Actor | Self-service | Centrally governed |
|---|---|---|
| **Platform/Security team** | — | The catalog of system Security Profiles; org default strategy; namespace-isolation policy templates; Application-category priority conventions |
| **Tenant Admin** | Select/switch a VPC's Security Profile; toggle the Gateway Firewall | Cannot invent a new VPC-level strategy outside the catalog |
| **Application owner** | Label workloads; request an app-scoped `NetworkSecurityGroup`/`FirewallPolicy` via catalog item or Terraform module | Cannot bypass namespace isolation or the VPC-level profile |

The concrete escape hatch worth calling out explicitly: **a policy created by a Security Profile cannot be edited directly.** Its rules are fixed by the profile definition. Customizing behavior means authoring a *separate*, higher-priority `FirewallPolicy` that is evaluated before the profile-owned one. This is a deliberate guardrail: it keeps the system-owned baseline tamper-evident (nobody can silently punch a hole in the profile itself) while still giving tenants and application teams a supported way to add precision on top of it.

---

## 6. Implementing Day-0 Provisioning with Terraform

*(core technical section #1)*

### 6.1 Why Terraform for the Tenant Security Baseline

Terraform fits naturally where tenant security config is provisioned **as part of** environment stand-up — a "new tenant" pipeline that creates the Project, VPC, Subnets, quotas, and the baseline `SecurityProfile`/`NetworkSecurityGroup`/default-deny `FirewallPolicy`/`VPCGatewayFirewallPolicy` set in one atomic `apply`, with the safety of `plan` review and state-tracked drift detection. Run that `apply` inside a CI job gated by the same pull-request review every other infrastructure change goes through, and the whole tenant shell — including its day-0 security posture — becomes a reviewed, reproducible artifact instead of a runbook someone follows by hand. For platform teams that already run multi-cloud IaC on Terraform, this means zero new tooling to onboard a tenant securely on day one.

### 6.2 Provider Chain

VCFA 9 exposes complementary Terraform providers. For vDefend automation, two matter:

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

### 6.3 Declaring the Tenant Security Baseline

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

This is illustrative of the pattern — provision the profile, bind it to a VPC, and lay down a default-deny baseline — rather than a complete, ready-to-apply module. Treat resource and attribute names as subject to the provider's current schema.

### 6.4 Module Design and State Strategy for Multi-Tenant Scale

- **One Terraform workspace/state per tenant Project**, keyed by tenant ID — never a single monolithic state file spanning tenants. This bounds blast radius: a bad `apply` for one tenant can't corrupt another's state, and it lets pipelines run in parallel.
- Wrap the resources above in a `tenant-vdefend-baseline` module with variables for tier labels, allowed ports, and default-deny posture, versioned in a shared module registry so every tenant onboarding starts from the same vetted security baseline.
- Once Argo CD (§7) takes ownership of a resource's steady-state reconciliation, stop managing that same object from Terraform to avoid field-ownership fights — see §7.5.

### 6.5 Applying Terraform to Each Design Pattern

Restating, per §5 pattern, exactly what Terraform provisions at day-0:

- **VPC Segmentation (§5.1):** provisions the `SecurityProfile` + `SecurityProfileAttachment` pair from §6.3, binding the tenant's VPC to one of the five system-owned profiles.
- **Namespace Segmentation (§5.2):** provisions the namespace-tag `NetworkSecurityGroup` plus its two-rule isolation `FirewallPolicy` as part of the same tenant baseline, so "one namespace = one blast-radius" exists before the first workload lands.
- **Day-0 Provisioned Security (§5.4):** owns both the group and the policy as part of the tenant baseline, exactly like the namespace pattern above — the only difference is the selector (`protected/env`, an explicit label) rather than the automatic namespace tag.
- **Transit Gateway (§5.5):** `TGWSecurityConfig` is a platform-owned object, provisioned once alongside the shared `TransitGateway` — not per tenant. A pre-merge check in the tenant GitOps pipeline should reject a `TGWFirewallPolicy` PR if the target gateway's `TGWSecurityConfig` isn't already enabled; otherwise the rules merge cleanly and silently do nothing.

Application Segmentation & Ringfencing (§5.3) has no Terraform-owned piece — see §7.6.

---

## 7. Implementing Day-2 Operations with Argo CD (GitOps)

*(core technical section #2)*

### 7.1 Why GitOps for Continuous Security Policy

Security policy is not "set once at provisioning" — it changes continuously as tenant applications evolve (new microservice, new port, decommissioned tier). Treating it as a one-time Terraform apply leaves a gap for exactly the kind of manual, undocumented change that turns into an audit finding. Argo CD's continuous reconciliation loop closes that gap:

- **Drift correction.** If someone manually edits a `FirewallPolicy` or `NetworkSecurityGroup` via `kubectl` or the CCI UI, Argo CD reverts it (or flags `OutOfSync`) on the next sync — Git remains the enforceable source of truth for security posture.
- **Self-service without a pipeline run.** Tenant security engineers merge a PR against their tenant's policy repo; Argo CD picks it up within its poll/webhook interval — no separate CI job needs to hold cloud credentials.
- **Native multi-tenant fan-out** via `ApplicationSet`, generating one Argo CD `Application` per tenant from a single template.

### 7.2 Registering a Tenant's Supervisor Namespace as an Argo CD Target

Each tenant's CCI kubeconfig (obtained once, out-of-band or via the same `vcfa_kubeconfig` Terraform data source used for bootstrapping in §6.2) is registered as an Argo CD cluster secret, scoped so Argo CD's service account only has RBAC (via `authorization.cci.vmware.com`) within that tenant's namespace(s) — never cluster-admin on the shared Supervisor.

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

### 7.3 Per-Tenant Application via ApplicationSet

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

`tenants/acme/security-policy/` in Git contains plain `NetworkSecurityGroup` / `FirewallPolicy` / `VPCGatewayFirewallPolicy` / `TGWFirewallPolicy` YAML — the shapes from §3.2 and the worked example in §8 — reviewed via standard pull request workflow, ideally with a `CODEOWNERS` entry requiring the tenant's security lead to approve changes to their own policy.

### 7.4 Ordering and Safety

- Use `argocd.argoproj.io/sync-wave` annotations to guarantee `NetworkSecurityGroup` objects (wave 0) and the default-deny `FirewallPolicy`/`VPCGatewayFirewallPolicy` (wave 1) land before more permissive tier-specific allow rules (wave 2+) — groups must exist before a policy can reference them, and a default-deny baseline should never trail its allow rules into the cluster.
- Run Argo CD in **non-selfHeal, manual-sync mode for a probation period** on newly onboarded tenants, flipping to `automated.selfHeal: true` once the baseline policy has been validated in a lower environment — this gives a soft rollout path for a capability that can otherwise instantly enforce a mistake fleet-wide.

### 7.5 Terraform vs. Argo CD: Choosing an Owner per Object

The two tools aren't competing for the same job — they excel at opposite ends of a tenant's lifecycle.

| Dimension | Terraform | Argo CD (GitOps) |
|---|---|---|
| Best for | Day-0 tenant/VPC provisioning, one-shot baseline | Day-2 continuous security policy management |
| Reconciliation | On-demand (`apply`) | Continuous (default poll ~3 min, or webhook-driven) |
| Drift handling | Detected at next `plan`; requires a pipeline run to fix | Auto-corrected (`selfHeal`) or flagged in near-real-time |
| Ownership model | Terraform state file per tenant | Git repo path per tenant; K8s is desired-state store |
| Credential exposure | CI runner needs tenant CCI token during `apply` | Argo CD holds long-lived scoped token; no per-change CI credential minting |
| Tenant self-service UX | PR → pipeline run → apply (slower, gated) | PR → merge → auto-sync (faster, still gated by review) |
| Blast-radius control | Per-tenant state + `plan` review | Per-tenant `Application`/`AppProject` RBAC + `syncPolicy` |

**Recommended hybrid**: Terraform owns the tenant *shell* (Project, VPC, Subnet, quotas, RBAC bindings, initial `SecurityProfile`, and a default-deny `FirewallPolicy`/`VPCGatewayFirewallPolicy`) as part of the onboarding pipeline from §6. Once the tenant exists, hand off ongoing `NetworkSecurityGroup`, `FirewallPolicy`, `VPCGatewayFirewallPolicy`, and `TGWFirewallPolicy` lifecycle to Argo CD, pointed at a tenant-owned Git path. Never let both tools manage the *same* object — pick one owner per resource to avoid field-ownership flapping. §6.5 and §7.6 apply this split to each of §5's design patterns.

### 7.6 Applying Argo CD to Each Design Pattern

Restating, per §5 pattern, exactly what Argo CD reconciles at day-2:

- **VPC Segmentation (§5.1):** a strategy change — e.g. moving a `dev` VPC from `none` to `vpc-isolation` — is a one-line diff to `SecurityProfileAttachment.spec.securityProfileName` in the tenant's Git path, synced automatically.
- **Namespace Segmentation (§5.2):** any `Application`-category rule opening a specific port between namespaces is added as a normal PR against the tenant's policy repo; the `Environment`-category isolation policy still governs anything not explicitly matched.
- **Application Segmentation & Ringfencing (§5.3):** because a new application being ringfenced is exactly the kind of change that happens continuously as a tenant's portfolio grows, this is squarely an Argo CD-owned change — a PR adding the app's group and policy to the tenant's Git path, reviewed by `CODEOWNERS`, synced automatically.
- **Transit Gateway (§5.5):** tenant-specific `TGWFirewallPolicy` rules are layered in the same way as any other tenant policy change, reviewed and synced from the tenant's Git path.

Day-0 Provisioned Security (§5.4) is fully owned by Terraform at onboarding — see §6.5.

---

## 8. A Worked End-to-End Example

**Scenario**: Tenant `acme` needs a `web` / `app` / `db` three-tier application with default-deny micro-segmentation and a locked-down perimeter, permitting only public HTTPS to the web tier, `web → app:8443`, and `app → db:5432`.

### 8.1 Terraform Onboarding

The onboarding pipeline (extending §6.3) creates the Project, VPC, Subnet, baseline `SecurityProfile`/`SecurityProfileAttachment`, tier groups, and a default-deny `FirewallPolicy`:

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

### 8.2 Handoff to Argo CD

The pipeline opens a PR into `tenants/acme/security-policy/` in the tenant's Git repo containing the tier-specific groups and allow rules, and registers `acme`'s namespace as an `ApplicationSet` element (§7.3).

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

`acme-web-tier-vpc` mirrors `acme-web-tier` as a separate `VPCNetworkSecurityGroup` — `VPCGatewayFirewallPolicy` rules can't reference the region-scoped `NetworkSecurityGroup` kind (§3.2).

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
      to: [{ groupName: acme-web-tier-vpc }]
      services: [{ l4PortSet: { l4Protocol: TCP, destinationPorts: ["443"] } }]
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
      from: [{ groupName: acme-web-tier }]
      to: [{ groupName: acme-app-tier }]
      services: [{ l4PortSet: { l4Protocol: TCP, destinationPorts: ["8443"] } }]
    - name: allow-app-to-db
      direction: In
      action: Allow
      from: [{ groupName: acme-app-tier }]
      to: [{ groupName: acme-db-tier }]
      services: [{ l4PortSet: { l4Protocol: TCP, destinationPorts: ["5432"] } }]
```

### 8.3 Day-2, Tenant-Driven Change

Acme's app team adds a `cache` tier. Their security engineer opens a PR adding a new `NetworkSecurityGroup` (`acme-cache-tier`) and a rule to `tier-isolation.yaml`:

```yaml
    - name: allow-app-to-cache
      direction: In
      action: Allow
      from: [{ groupName: acme-app-tier }]
      to: [{ groupName: acme-cache-tier }]
      services: [{ l4PortSet: { l4Protocol: TCP, destinationPorts: ["6379"] } }]
```

Once merged and approved by the `CODEOWNERS`-designated security lead, Argo CD syncs it — no Terraform run, no platform-team ticket, and the default-deny `FirewallPolicy` and locked-down `VPCGatewayFirewallPolicy` still govern anything not explicitly matched. From empty namespace to a fully isolated, micro-segmented, internet-facing-only-where-intended application, the whole path took the time it took to merge a couple of pull requests — not the days or weeks a ticket-driven model would have taken.

### 8.4 Multi-VPC Extension

If Acme later splits into a `prod` VPC and a `shared-services` VPC on a common Transit Gateway, a `TGWFirewallPolicy` (§5.5) is added to allow only the specific east-west paths needed between them, rather than relying on the coarser connectivity posture alone.

---

## 9. Conclusion

Multi-tenant security in VCF 9.1 works when it is designed as a set of composable, API-addressable layers — VPC-level Security Profiles, namespace isolation, application ringfencing, and Transit Gateway policy — each with a clear owner and a clear delegation boundary (§3, §5). Because every layer is a Kubernetes-native custom resource under the VCFA Consumption API (§4), the same design pattern is automatable on day one with exactly two tools a platform team already runs: Terraform for the atomic, reviewed day-0 baseline (§6), and Argo CD for the continuously reconciled day-2 policy lifecycle (§7). §5 and §8 show that pairing holding up against real, live-environment scenarios — not just a diagram.

**The final thought worth remembering:** by moving enforcement into the hypervisor and consuming it through the same Terraform-and-GitOps surface as every other piece of infrastructure, security stops being a checkpoint someone has to clear and becomes an ambient property of the platform itself. VCF with vDefend doesn't just secure applications — it lets security be measured the way the rest of the business measures itself: faster time-to-market, lower operational cost, and continuous, demonstrable compliance.

---

## Appendix A. VCFA/CCI API Reference

The authoritative, current source for this API is Broadcom's CCI API documentation: [developer.broadcom.com/xapis/cci-api](https://developer.broadcom.com/xapis/cci-api/latest/api-docs.html#k8s-api-vpc-nsx-vmware-com-v1alpha1) — verify field-level details there before an automation module hard-codes an assumption this reference doesn't cover. What follows is the field-by-field detail behind the constructs introduced in §3.2, confirmed against a running VCF 9.1 environment.

### A.1 `NetworkSecurityGroup` / `VPCNetworkSecurityGroup` — the reusable "who"

The verified schema splits this into **two** kinds, scoped differently:

- **`NetworkSecurityGroup`** is scoped by a required `spec.regionName` (not a VPC). `FirewallPolicy` (east-west/DFW) and `TGWFirewallPolicy` (inter-VPC) rules reference these by name.
- **`VPCNetworkSecurityGroup`** is scoped by a required `spec.vpcName` instead. `VPCGatewayFirewallPolicy` (north-south perimeter) rules reference these instead of the region-scoped kind.

Both kinds share the same membership shape: static `ipAddresses[]` (single IPs, ranges, or CIDRs), static `vms[]` (by `instanceUUID`), dynamic `vmSelectors[]`/`podSelectors[]` (each a `labelSelector` and/or `namespaceSelector`, plus a VM-only `propertySelector` matching on `Name`/`OSName`/`ComputerName`), and nested group references (`networkSecurityGroupNames[]`/`vpcNetworkSecurityGroupNames[]`). There is no `memberSelector` wrapper — these are all top-level `spec` fields.

**Free namespace-scoped grouping via auto-tags.** VCFA automatically tags every VM's network interface with `kubernetes.io/metadata.name: <namespace name>` and `nsx-op/vm_namespace: <namespace name>` the moment it's deployed into a Supervisor Namespace — no manual labeling required (used throughout §5.2 and §5.4). Confirmed limitations: this pattern does not work for VKS cluster nodes (grouped via separate, auto-generated tags) or for workloads on a shared VPC subnet.

### A.2 `SecurityProfile` + `SecurityProfileAttachment` — the VPC's security posture

`SecurityProfile` is a standalone, `regionName`-scoped object — it does nothing on its own. `SecurityProfileAttachment` (`regionName` + `securityProfileName` + `vpcName`, all required) is what binds it to a VPC. `SecurityProfileSpec` controls VPC-wide enforcement behavior — whether the north-south firewall is enabled, and which east-west strategy applies (`none`, `vpc-isolation`, `vpc-secure-connection`, `vpc-isolation-with-essential-services`, `vpc-external-connectivity`). There is no `tcpStrict` field here (that's per-firewall-policy-kind) and no Malware Prevention profile reference field in this API group.

Confirmed from a live region — exactly five pre-created, system-owned `SecurityProfile` objects exist, one per strategy:

```
NAME                                    SECURITY STRATEGIES                    NORTHSOUTHFIREWALL ENABLED
default--m01-reg01                      none                                    false
system-security-profile-2--m01-reg01    vpc-isolation                           false
system-security-profile-3--m01-reg01    vpc-isolation-with-essential-services   false
system-security-profile-4--m01-reg01    vpc-external-connectivity               false
system-security-profile-5--m01-reg01    vpc-secure-connection                   false
```

A tenant picks a posture by pointing `SecurityProfileAttachment.spec.securityProfileName` at one of these — not by authoring custom strategy values. Confirmed limitations: a `FirewallPolicy`/`VPCGatewayFirewallPolicy` generated by a `SecurityProfile` cannot be edited or have rules appended directly (customize via a separate, higher-priority policy instead); essential-services rules always allow both directions; and every generated rule terminates in `JumpToApplication`, so `vpc-secure-connection`/`vpc-external-connectivity` fail closed without an explicit tenant `Application`-category allow rule.

### A.3 `FirewallPolicy` — east-west (Distributed Firewall) rules

Holds an ordered `rules[]` list; each rule's `from`/`to` are arrays of single-peer objects (`{ groupName: ... }` or `{ ipAddress: ... }`), not flat string lists. Port/protocol matching nests under `services[].l4PortSet` or a `networkServiceName` reference. `spec.category` (`Infrastructure` | `Environment` | `Application`) determines evaluation order (§3.2).

### A.4 `VPCGatewayFirewallPolicy` — north-south perimeter rules

Same rule shape as `FirewallPolicy`, but scoped to the VPC's own gateway and referencing `VPCNetworkSecurityGroup` (not `NetworkSecurityGroup`) in `groupName` peers. Both `spec.regionName` and `spec.vpcName` are required.

### A.5 `TGWFirewallPolicy` — inter-VPC rules on a shared Transit Gateway

No `spec.transitGateway` field exists on `TGWFirewallPolicySpec` — a rule scopes itself to a specific Transit Gateway attachment via `appliedTo.gatewayAttachmentNames[]`/`gatewayNames[]`. Groups referenced in `from`/`to` are the region-scoped `NetworkSecurityGroup`. Requires the appropriate vDefend/Advanced Cyber Compliance licensing tier.

### A.6 `NetworkService` — reusable service/port definitions

`NetworkServiceSpec.serviceEntries[]` accepts exactly one of five shapes per entry: `l4PortSet` (TCP/UDP + ports), `icmp`, `ipProtocol` (raw IP protocol numbers), `alg` (Application Layer Gateway protocols), or `igmp`. Custom `NetworkService` creation has been observed to reject at least some arbitrary TCP ports (e.g. `6443`) — verify before depending on it in a pipeline.

### A.7 `NetworkSecurityGroupIPMembers` / `VPCNetworkSecurityGroupIPMembers` — realized membership (read-only)

Read-only subresources reporting the IPs a group's selectors actually resolved to. Useful as a post-apply CI check: assert non-empty before promoting a paired `FirewallPolicy` change that references the group, to catch a typo'd selector before it reaches production.

### A.8 `TGWSecurityConfig` — the Transit Gateway firewall on/off switch

A subresource of `TransitGateway`: `spec.features[]` is a list of `{ name, enabled }` pairs, with `GatewayFirewall` the only documented value. Gates all `TGWFirewallPolicy` enforcement on that gateway.

### A.9 `VPCConnectivityProfile` / `VPCConnectivityProfileBinding` — VPC north-south connectivity posture

Governs a VPC's outward connectivity (`externalIPBlockNames[]`, `transitGatewayName`, `serviceGateway`/NAT config). `VPCConnectivityProfileBinding` binds a named profile to a Project/namespace. This schema version has no explicit `Community`/`Isolated`/`Promiscuous`-style isolation-mode field on the profile itself — confirm placement with `kubectl explain` before assuming where that toggle lives in your build.

### A.10 `RegionNetworkingCapabilities` — capability discovery

Read-only, one object per Region: `capabilities[]` array of `{ type, state, reason, message }`. Useful as a pre-flight check before generating manifests that depend on a region-specific capability.

---

## Appendix B. Glossary

| Term | Meaning |
|---|---|
| **VCF** | VMware Cloud Foundation — the private cloud platform this paper builds on |
| **VCFA** | VCF Automation — the self-service consumption layer of VCF, exposing CCI |
| **CCI** | Cloud Consumption Interface — VCFA's per-tenant Kubernetes API server |
| **vDefend** | Broadcom's security suite built into VCF (Distributed Firewall, Gateway Firewall, Transit Gateway Firewall) |
| **NSX** | The networking/security platform underlying vDefend's enforcement |
| **NSX Project** | NSX's representation of a VCF Organization/tenant |
| **VPC** | Virtual Private Cloud — the per-tenant network/security boundary inside VCF |
| **Supervisor Namespace** | A VPC-backed namespace; the unit a tenant Project owns and self-services within |
| **DFW** | Distributed Firewall — east-west, intra-VPC enforcement at the vNIC |
| **TGW** | Transit Gateway — the shared routing construct connecting multiple VPCs |
| **Privileged (protected) label** | A VCFA label whose application and removal are RBAC-controlled, translated to an NSX tag; lets a platform team key policy to a marker a tenant cannot reassign |
| **Micro-segmentation** | Fine-grained, per-workload network isolation, independent of subnet/VLAN |
| **GitOps** | Operating infrastructure by reconciling live state against a Git repository |
| **Argo CD** | The GitOps controller this paper uses for day-2 policy reconciliation |
| **ApplicationSet** | Argo CD's mechanism for generating one `Application` per tenant from a template |
| **sync-wave** | An Argo CD annotation controlling apply order across resources in a sync |
| **kubeconfig** | The credential/context bundle a tenant or pipeline uses to reach CCI |
| **RBAC** | Role-Based Access Control — how CCI scopes what a tenant or automation identity can reach |
| **VKS** | VMware vSphere Kubernetes Service — Kubernetes clusters running as VCF workloads |

---

## Appendix C. Additional Resources

- Broadcom Developer Portal — [CCI API Reference (`xapis/cci-api`, `vpc.nsx.vmware.com/v1alpha1`)](https://developer.broadcom.com/xapis/cci-api/latest/api-docs.html#k8s-api-vpc-nsx-vmware-com-v1alpha1)
- Broadcom TechDocs — [Firewall Policies in an NSX VPC](https://techdocs.broadcom.com/us/en/vmware-cis/nsx/vmware-nsx/9-0/administration-guide/nsx-multi-tenancy/nsx-virtual-private-clouds/firewall-policies-in-an-nsx-vpc.html)
- Broadcom TechDocs — [Groups in an NSX VPC](https://techdocs.broadcom.com/us/en/vmware-cis/nsx/vmware-nsx/4-2/administration-guide/nsx-multi-tenancy/nsx-virtual-private-clouds/groups-in-an-nsx-vpc.html)
- Broadcom TechDocs — [View VPC Security Profile Status](https://techdocs.broadcom.com/us/en/vmware-security-load-balancing/vdefend/vdefend-firewall/9-0/secure-vpc-projects/vpc-security-key-concepts/view-vpc-security-profile-status.html)
- Broadcom TechDocs — [Virtual Private Cloud in NSX (VCF 9.0/9.1)](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-9-0-and-later/9-0/advanced-network-management/administration-guide/virtual-private-cloud-in-nsx.html)
- VMware Cloud Foundation Blog — [VMware Virtual Private Cloud in VCF 9.0](https://blogs.vmware.com/cloud-foundation/2025/07/02/vmware-virtual-private-cloud/)
- VMware Cloud Foundation Blog — [VCF Automation IaC: Cloud Consumption Interface (CCI)](https://blogs.vmware.com/cloud-foundation/2024/11/05/vmware-cloud-foundation-vcf-automation-infrastructure-as-code-iac-cloud-consumption-interface-cci/)
- VMware Cloud Foundation Blog — [VCF 9.1 Networking: Simpler VPC Connectivity Control](https://blogs.vmware.com/cloud-foundation/2026/05/15/vcf-networking-9-1-simpler-vpc-connectivity-control/)
- sdn-warrior.org — [VCF 9 — NSX VPC Part 3: Security](https://sdn-warrior.org/posts/vcf9-nsx-vpc-part3/)
- sdn-warrior.org — [VCF 9.1 — VPCs Connectivity Policies](https://sdn-warrior.org/posts/vcf9.1-vpcs-connectivity-policy/)
- Broadcom TechDocs — [Kubernetes API Reference for the Cloud Consumption Interface](https://techdocs.broadcom.com/us/en/vmware-cis/aria/aria-automation/8-18/consumption-on-prem-using-master-map-8-18/working-with-the-cloud-consumption-interface/other-cci-command-line-interface-options/supervisor-namespaces-cloud-consumption-interface-kubernetes-api-reference.html)
- theaistack.blog — [VCF Automation Tenant Management](https://theaistack.blog/2025/08/12/vcf-automation-tenant-management/)
- vrealize.it — [VCF Automation 9: New Terraform Providers for All-Apps-Org](https://vrealize.it/2025/08/07/vcf-automation-9-new-terraform-providers-for-all-apps-org/)
- William Lam — [Automating VCFA Configuration using the VCFA Terraform Provider](https://williamlam.com/2025/10/automating-vcf-automation-vcfa-configuration-using-vcfa-terraform-provider.html)
- HashiCorp / VMware — [Terraform Provider for VMware Aria Automation / VCF Automation (`vra`)](https://github.com/vmware/terraform-provider-vra)
- Argo CD Documentation — [ApplicationSet Controller](https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/)
