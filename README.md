# Architecting Multi-Tenant Security in VCF with vDefend
### API-Driven Self-Service Protection for Organizations and Applications

---

## 1. Executive Summary

Private cloud is being re-platformed around a simple expectation: application teams should be able to request infrastructure — and the security that protects it — the same way they consume any other cloud service. In VMware Cloud Foundation (VCF) 9.1, that expectation is met by pairing **VCF Automation**, the platform's Kubernetes-native consumption layer, with **vDefend**, VCF's built-in network and workload security stack. Together they let a platform team define a small set of vetted security postures once, and let tenants attach, switch, and scope those postures to their own Projects, VPCs, namespaces, and applications — without filing a ticket to a network security team.

This paper is written for cloud and platform architects who already know their way around VCF Automation and vDefend and want a concrete design pattern for wiring the two together in a multi-tenant environment. It is not a product primer. It is a blueprint for:

- Exposing vDefend's Distributed Firewall (DFW) capability to tenants as a small number of self-service, system-defined **Security Profiles**, consumed declaratively through the **VCF Automation Consumption API**.
- Layering **namespace and application segmentation** on top of that VPC-level posture so tenants can ring-fence individual applications without touching the org-wide security baseline.
- Building this out day-0, so security posture exists *before* a workload lands, not as an afterthought.
- Delivering all of the above through **Terraform** (day-0/day-1, PR-reviewed provisioning) and **GitOps via Argo CD** (day-2, continuously reconciled), rather than through point-and-click console operations.

The result is a model where security is not a gate that slows down self-service infrastructure — it is one of the things being self-served, inside guardrails the platform team controls centrally and exposes through the same API surface as compute, network, and storage.

---

## 2. Introduction

### 2.1 Private cloud as a service

VCF Automation turns a VCF private cloud into something application teams can consume the way they consume a public cloud: Projects for tenant boundaries, VPCs and Namespaces for network and workload scoping, and catalog items for repeatable deployment patterns. The pressure this creates for platform teams is familiar from every public-cloud adoption curve — velocity expectations rise faster than the platform team's ability to hand-hold every request.

Security is usually where that pressure breaks something. If every new tenant, VPC, or application requires a network security engineer to author Distributed Firewall rules by hand, self-service infrastructure just relocates the bottleneck instead of removing it — provisioning is instant, but the workload sits unprotected (or blocked) until security work catches up.

### 2.2 Problem statement

In a multi-tenant VCF environment, "security as a manual, centralized process" fails on three axes:

- **Speed** — DFW rule authoring per tenant does not scale with the rate of Project/VPC creation that self-service platforms are designed to enable.
- **Consistency** — hand-authored rules drift in quality and coverage across tenants, widening the actual security posture gap between "well-supported" and "everyone else."
- **Ownership** — tenants have no way to reason about or adjust their own security posture, so every legitimate change (a new inbound port, a new peer VPC) re-enters the same manual queue.

### 2.3 Goals

This paper's design pattern optimizes for:

- **Out-of-the-box security** — a workload should be born into a defined security posture, not provisioned open and secured later.
- **Self-service within guardrails** — tenants choose and adjust posture from a small, vetted catalog; they do not hand-author firewall rules from scratch.
- **API-first consumption** — every capability above is available as a declarative resource under the VCF Automation Consumption API, so it is equally reachable from the UI, `kubectl`, Terraform, or a GitOps controller.

### 2.4 Scope and assumed reader knowledge

This paper assumes the reader is already familiar with VCF Automation's tenancy model (Organizations, Projects, Namespaces, VPCs) and with vDefend fundamentals (the Distributed Firewall, Gateway Firewall, and the general concept of Security Profiles). It does not re-introduce those concepts from first principles.

**vDefend IDS/IPS is explicitly out of scope.** IDS/IPS is not exposed through the VCF Automation Consumption API in the current release and is configured and consumed directly through NSX, not through the multi-tenant self-service surface this paper describes.

---

## 3. Multi-Tenant Security Architecture

*(the model Terraform and Argo CD implement)*

### 3.1 Logical Isolation via VCF VPCs and NSX Projects

A **Virtual Private Cloud (VPC)** inside VCF is what turns a shared physical private cloud into a set of self-contained environments scoped to a tenant — and it's the tenant boundary Terraform provisions in §6 and Argo CD then operates inside in §7. A Project can own more than one VPC (§8.5's multi-VPC tenant is a common case), and a VPC is not 1:1 with a Supervisor Namespace either: one or more Supervisor Namespaces can attach to the *same* VPC and share its address space and gateway, or each namespace can get its own dedicated VPC — §5.2 and §8.2 cover both design blueprints in detail. The full hierarchy, from provider admin down to a workload:

```
Provider Admin
 └─ Region (group of Supervisors)
      └─ Project  (tenant boundary)
           ├─ VPC                       (vpc.nsx.vmware.com/v1alpha1)
           │    ├─ Subnet(s)
           │    ├─ SecurityProfile            <-- posture toggles (N-S FW on/off, TCP-strict)
           │    ├─ NetworkSecurityGroup(s)     <-- reusable "who" (web-tier, app-tier, db-tier...)
           │    ├─ FirewallPolicy(ies)         <-- east-west DFW rules (intra-VPC)
           │    ├─ VPCGatewayFirewallPolicy    <-- north-south perimeter rules (per-VPC)
           │    └─ TGWFirewallPolicy           <-- east-west rules between VPCs on a shared TGW
           └─ Supervisor Namespace(s)          <-- one or more attach to the VPC above: dedicated (1:1) or shared (N:1)
                └─ Workloads: VirtualMachines, VKS clusters, vSphere Pods
```

An **NSX Project** is the representation of an Organization (tenant) in NSX. Everything a tenant can self-service — including security policy — is scoped inside the namespaces their Project owns, bounded by quotas and RBAC a provider admin defined up front via `infrastructure.cci.vmware.com` and `authorization.cci.vmware.com`.

**What actually stops Organization A from touching Organization B's security posture** is three ordinary Kubernetes mechanisms stacked together, not a convention anyone has to remember to follow:

1. **Namespace boundary.** Every `vpc.nsx.vmware.com/v1alpha1` object — `NetworkSecurityGroup`, `FirewallPolicy`, `SecurityProfile`, all of it — is created inside the tenant's own CCI Supervisor Namespace: the single Kubernetes namespace representing the whole Organization/Project (the `acme-prod-ns01`-style namespace used throughout this paper's examples), not inside each individual vSphere Namespace (`prod01`, `prod02`, `dev01`, ...) that exists purely as a workload-placement scope *inside* a VPC. A `FirewallPolicy` or `NetworkSecurityGroup` targets a specific vSphere Namespace's workloads through a label selector (`nsx-op/vm_namespace`, §4.2) or a `vpcName`/`regionName` field in its spec — not by being created inside that namespace. Either way, there is no cluster-scoped variant of these kinds a tenant can reach; the enforced boundary sits at the Organization's own namespace.
2. **RBAC (`authorization.cci.vmware.com`).** A tenant's kubeconfig context is bound to role bindings scoped to their own namespace(s) only. The Kubernetes API server itself — not an application-layer check — rejects a request against a namespace the token isn't bound to.
3. **Quota (`infrastructure.cci.vmware.com`).** Even inside their own namespace, a tenant can't exceed the network/compute limits a provider admin set at Project creation.

Together these are what make "self-service" and "safe" the same sentence, enforced by the API server, not by policy.

### 3.2 Tiered Security Model

Isolating tenants from each other is only half the model. Inside that boundary, VCF splits control into two tiers so a platform-wide baseline can't be quietly overridden by a single tenant, while tenants still get real, immediate control of their own micro-segmentation:

- **Provider/Security Admin level.** Global rules that must apply to every tenant regardless of what any individual app team wants are delivered through `SecurityProfile`. Rather than tenants hand-authoring an east-west strategy from scratch, VCF Automation ships pre-created, **system-owned** `SecurityProfile` objects, one per named strategy; a tenant *selects* a posture by pointing their `SecurityProfileAttachment` at one of these. A `FirewallPolicy`/`VPCGatewayFirewallPolicy` that a `SecurityProfile` generates cannot be edited or have rules appended to it by a tenant directly — the only supported customization path is a **separate**, higher-priority policy that runs *before* it (§4.1 in this paper's design pattern, §7.1 in the use cases below).
- **Tenant level.** Everything below that global baseline is delegated. Inside their own isolated boundary, an app owner creates their own `NetworkSecurityGroup`/`FirewallPolicy` objects to micro-segment their application tiers exactly how they want, with no platform-team involvement per change.

**Evaluation order backs the tiering, not just convention.** Every `FirewallPolicy` carries a `spec.category`, and the confirmed schema values — `Infrastructure`, `Environment`, `Application` — evaluate in that fixed order: fabric-level rules in `Infrastructure`, macro-segmentation (e.g., blocking `Prod` from ever reaching `Dev`) in `Environment`, and tenant micro-segmentation in `Application`. Because categories evaluate top-down, a global rule authored by the Security Admin is always checked before any `Application`-category rule a tenant writes. This split maps directly onto the ownership model §7.5 formalizes: Terraform and the platform team own `Infrastructure`/`Environment`-category baselines and system `SecurityProfile` bindings; Argo CD, watching a tenant's own Git path, owns the `Application`-category policy that tenant iterates on.

### 3.3 RBAC and Separation of Duties

The tiering in §3.2 is enforced, not just documented, through `authorization.cci.vmware.com` RBAC scoped to three distinct roles:

- **Cloud Admin.** Owns `infrastructure.cci.vmware.com` (quotas, namespace classes, zone/region association) and `topology.cci.vmware.com` — the guardrails that exist *before* any tenant gets self-service access at all.
- **Security Admin.** Owns the platform-wide security guardrails from §3.2 — the system `SecurityProfile` catalog, `TGWSecurityConfig`, `VPCConnectivityProfile` — plus review authority over anything that can affect more than one tenant, like `TGWFirewallPolicy` changes on a shared Transit Gateway.
- **Tenant App Developer.** Scoped, via `authorization.cci.vmware.com` role bindings, to exactly their own Project's namespace(s) — full read/write on `NetworkSecurityGroup` and `FirewallPolicy` inside that boundary, and nothing outside it.

The same least-privilege principle extends to automation identities, not just people, and it carries directly into §6 and §7: a Terraform CI runner's CCI token and the Argo CD cluster secret should each be scoped to only the tenant namespace(s) they manage — never a Project-wide or Region-wide credential, even though the pipeline itself may be platform-owned.

---

## 4. The vDefend API Surface, Consumed via VCF Automation (CCI)

*(condensed — this is reference material to make §6–§9 legible, not the paper's main subject; the full field-by-field spec is in Appendix A)*

### 4.1 CCI as a Standard Kubernetes API Server

VCF Automation's **Cloud Consumption Interface (CCI)** is a real Kubernetes API server, not a proprietary REST API with a UI bolted in front of it. A tenant (or a pipeline) authenticates and receives a **kubeconfig context scoped to their own Supervisor Namespace** — nothing else is visible — via a token exchange (the `vcfa_kubeconfig` Terraform data source is the mechanism §6 uses). From there, any standard Kubernetes tooling works against it directly: `kubectl`, any Kubernetes client library, Terraform's `kubernetes` provider, or a GitOps controller like Argo CD. No vDefend-specific SDK is required.

### 4.2 The Object Model at a Glance

vDefend's `NetworkSecurityGroup` objects are built on VM attributes — labels, tags, namespace membership — rather than static IP addresses, so a group like "every VM labeled `tier: app`" never needs editing as VMs are added, removed, or re-IP'd; the Distributed Firewall re-evaluates membership continuously. VCF Automation goes a step further and auto-tags every VM's network interface the moment it lands in a Supervisor Namespace (`nsx-op/vm_namespace: <namespace name>`), so "one namespace = one blast-radius" is a day-0 isolation boundary with zero manual tagging — a pattern §8.2 builds on directly.

The relevant API groups, and the kinds each exposes:

| API group | Purpose |
|---|---|
| `project.cci.vmware.com/v1alpha2` | Tenant Project definition (the top-level multi-tenancy boundary) |
| `infrastructure.cci.vmware.com` | Namespace classes, quotas, zone/region association — the guardrails a provider admin sets before self-service access |
| `authorization.cci.vmware.com` | RBAC / role bindings scoped to a Project or namespace |
| `vpc.nsx.vmware.com/v1alpha1` | **VPC networking and security**: `VPC`, `Subnet`, `NetworkSecurityGroup`/`VPCNetworkSecurityGroup`, `NetworkService`, `SecurityProfile`/`SecurityProfileAttachment`, `FirewallPolicy`, `VPCGatewayFirewallPolicy`, `TGWFirewallPolicy`/`TGWSecurityConfig`, `VPCConnectivityProfile`/`Binding` |
| `vmoperator.vmware.com/v1alpha3` | VM lifecycle — the workloads the security policy protects |

Everything this paper automates lives in `vpc.nsx.vmware.com/v1alpha1`. In brief:

| Kind | Role |
|---|---|
| `NetworkSecurityGroup` / `VPCNetworkSecurityGroup` | The reusable "who" — region-scoped or VPC-scoped membership, by label selector, IP, or nested group |
| `SecurityProfile` + `SecurityProfileAttachment` | The VPC's security posture (north-south firewall on/off, east-west strategy); inert until attached to a VPC |
| `FirewallPolicy` | East-west (Distributed Firewall) rules, intra-VPC |
| `VPCGatewayFirewallPolicy` | North-south perimeter rules, per-VPC |
| `TGWFirewallPolicy` + `TGWSecurityConfig` | East-west rules between VPCs on a shared Transit Gateway; inert until the gateway's `TGWSecurityConfig` enables `GatewayFirewall` |
| `NetworkService` | Reusable protocol/port definitions, referenced by name from any rule |

### 4.3 How the Kinds Compose

```
NetworkSecurityGroup (regionName)     --referenced by--> FirewallPolicy (east-west, intra-VPC)
                                                          TGWFirewallPolicy (east-west, inter-VPC)

VPCNetworkSecurityGroup (vpcName)     --referenced by--> VPCGatewayFirewallPolicy (north-south)

NetworkService                        --referenced by--> any rule's services[] (all three firewall kinds)

SecurityProfile  --bound to a VPC via--> SecurityProfileAttachment  --governs posture of--> that VPC

TGWSecurityConfig (GatewayFirewall: true)  --gates enforcement of--> TGWFirewallPolicy
```

A group object is the only thing the three firewall-policy kinds *require* to express meaningful rules; `SecurityProfile` is orthogonal, and inert until attached. This composition is exactly what §6.3's Terraform baseline and §7.3's Argo CD `ApplicationSet` provision and reconcile, respectively.

### 4.4 A Note on Source Grounding

The schema in this paper is confirmed against a running VCF 9.1 environment (live `kubectl get` output, reproduced in §8) rather than assumed from documentation alone. The authoritative, current reference is Broadcom's published CCI API documentation at `developer.broadcom.com/xapis/cci-api` (linked in Appendix C) — check it directly before an automation module hard-codes an assumption this paper doesn't cover.

---

## 5. Design Pattern: Mapping vDefend Security to Tenants via API

This section walks through the concrete design pattern for consuming vDefend security through the VCF Automation Consumption API, moving from the VPC boundary down to the individual application, then closes with the delegation model and the known constraints an architect needs to design around today. §8 grounds each of these patterns against a live environment as a full use-case scenario.

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

The architectural payoff: a tenant's entire VPC security posture is one small, human-readable object — the `SecurityProfileAttachment`. It can be reviewed in a pull request, reconciled by a GitOps controller, and audited from Git history — with no free-text firewall rule authoring exposed to the tenant at all. §8.1 shows this consumed live against a region.

### 5.2 Namespace Segmentation

Every Supervisor Namespace is tied to exactly one VPC and one namespace class at creation time, but that VPC assignment is a per-namespace choice, not a fixed platform rule — VCF Automation supports two design blueprints, and a platform team can mix both within the same Project:

- **Dedicated VPC** — one VPC per namespace (or per small group of namespaces), for stricter isolation. Namespace segmentation and VPC segmentation are the same boundary here, so the Security Profile attached to the VPC *is* the namespace's security posture (§5.1), and there is no need to layer a separate namespace-scoped `FirewallPolicy` on top for east-west isolation between namespaces — there's only ever one namespace in the VPC to isolate from.
- **Shared VPC** — multiple namespaces share one VPC's address space and gateway, for cases where network separation between those namespaces isn't required. This is the common case for a "prod" VPC hosting several related application namespaces (e.g., `prod01`, `prod02`) that want to share transit/gateway configuration and quota pooling, but still need their own east-west isolation from each other without provisioning a VPC per namespace.

The decision is fundamentally about isolation versus sharing: pick Dedicated VPC when a namespace needs its own network boundary (e.g., a namespace whose tenant, compliance scope, or blast-radius requirement doesn't tolerate sharing a gateway with anything else); pick Shared VPC when several namespaces belong to the same trust boundary and gain more from pooled quota and simpler topology than from a hard network split. Namespace class (CPU/memory/storage limits, VM classes, storage classes, content libraries) is a separate, parallel provisioning decision from VPC assignment — choosing a namespace class does not constrain or imply which VPC blueprint a namespace uses.

In the Shared VPC model, VCF Automation auto-tags every workload with its owning namespace (`kubernetes.io/metadata.name`, `nsx-op/vm_namespace`). Because that tag is applied automatically to every existing and future VM deployed into the namespace, a platform team can build namespace isolation once, generically, using a label-selector-based `NetworkSecurityGroup` — no per-workload rule maintenance required. §8.2 shows the concrete objects, and covers both blueprints in the Terraform/Argo CD ownership split.

### 5.3 Application Segmentation & Ringfencing

The final, finest-grained tier is the application itself. Where namespace isolation answers "can namespace A talk to namespace B," application ringfencing answers "which of the workloads inside my own namespace can talk to each other." The pattern mirrors namespace segmentation but uses a tenant-defined label instead of the auto-assigned namespace tag — this is the piece an application team genuinely self-serves. §8.3 walks through it end to end.

This is the layer where "self-service security" is most literal: an application owner labels their own VMs and, through a thin abstraction (a catalog item, a Terraform module, or a GitOps overlay — §6 and §7), gets an app-scoped `NetworkSecurityGroup` and `FirewallPolicy` without ever touching NSX Manager or filing a firewall-change ticket.

### 5.4 Day-0 Provisioned Security

The pattern above (label → group → policy) generalizes into the mechanism that makes security "out-of-the-box" rather than bolted on after deployment: the protecting label is applied **at VM creation time**, as part of the VM Service spec, so the workload is a member of its security group — and therefore covered by its firewall policy — from the moment it powers on. Because the group and its lockdown policy already exist (provisioned as part of tenant/environment onboarding), there is no window between "VM boots" and "VM is protected." §8.4 shows the manifest.

### 5.5 Delegation Model and Guardrails-as-Code

Pulling 5.1–5.4 together, the delegation boundary looks like this:

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

VCF Automation 9 exposes complementary Terraform providers. For vDefend automation, two matter:

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

`tenants/acme/security-policy/` in Git contains plain `NetworkSecurityGroup` / `FirewallPolicy` / `VPCGatewayFirewallPolicy` / `TGWFirewallPolicy` YAML — the shapes from §4.2 and the worked example in §8 — reviewed via standard pull request workflow, ideally with a `CODEOWNERS` entry requiring the tenant's security lead to approve changes to their own policy.

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

**Recommended hybrid**: Terraform owns the tenant *shell* (Project, VPC, Subnet, quotas, RBAC bindings, initial `SecurityProfile`, and a default-deny `FirewallPolicy`/`VPCGatewayFirewallPolicy`) as part of the onboarding pipeline from §6. Once the tenant exists, hand off ongoing `NetworkSecurityGroup`, `FirewallPolicy`, `VPCGatewayFirewallPolicy`, and `TGWFirewallPolicy` lifecycle to Argo CD, pointed at a tenant-owned Git path. Never let both tools manage the *same* object — pick one owner per resource to avoid field-ownership flapping. §8 applies this split to six concrete use cases.

---

## 8. Use Case Scenarios

*(grounded in a live VCF 9.1/vDefend environment; each shown as a Terraform-owned day-0 baseline plus an Argo CD-owned day-2 change, per the §7.5 ownership model — the worked, end-to-end version of §5's design pattern)*

### 8.1 VPC Segmentation

vDefend's system `SecurityProfile` catalog ships four named east-west strategies plus `none`, each shaping the VPC's default group (`vpc1-default-group`) allow/drop behavior differently (§5.1).

**Consumption pattern.** A Tenant Admin (or their automation) reads the available profiles and the current attachment for their VPC:

```bash
vcf context use <org-name>
kubectl get securityprofiles
kubectl get securityprofileattachments
```

**Terraform (day-0):** provisions the `SecurityProfile` + `SecurityProfileAttachment` pair from §6.3, binding the tenant's VPC to one of the five system-owned profiles (`kubectl get securityprofiles` on a live region confirms exactly five: `default--<region>` — `none`, plus one each for the four strategies).

**Argo CD (day-2):** a strategy change — e.g. moving a `dev` VPC from `none` to `vpc-isolation` — is a one-line diff to `SecurityProfileAttachment.spec.securityProfileName` in the tenant's Git path, synced automatically. The imperative equivalent for a lab or break-glass change is a direct patch:

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

### 8.2 vSphere Namespace Segmentation

**Choosing the blueprint (§5.2) drives what this use case actually needs to provision:**

- **Dedicated VPC** — each namespace already gets `SecurityProfile`-driven isolation for free (§8.1); there is nothing further to author here. Terraform's day-0 job is simply to provision one VPC + `SecurityProfileAttachment` per namespace as part of the same tenant baseline in §6.3.
- **Shared VPC** — this is the case the rest of this section automates: because the VPC-level `SecurityProfile` only governs traffic crossing the *VPC* boundary, namespaces sharing that VPC are otherwise free to reach each other unless a namespace-scoped `FirewallPolicy` says otherwise. That's exactly the gap the objects below close.

Every subnet in a namespace's scope is auto-tagged by VCF Automation with `kubernetes.io/metadata.name: <namespace name>` and `nsx-op/vm_namespace: <namespace name>` — no manual labeling. That tag is what makes namespace-scoped isolation nearly free in the Shared VPC case:

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

**Terraform (day-0):** provisions this pair as part of the tenant baseline in §6.3 — the namespace-tag group plus its two-rule isolation policy — so "one namespace = one blast-radius" exists before the first workload lands.

**Argo CD (day-2):** any `Application`-category rule opening a specific port between namespaces is added as a normal PR against the tenant's policy repo; the `Environment`-category isolation policy above still governs anything not explicitly matched, and — because it's `Environment`, not `Application` — stays outside the tenant's own RBAC scope from §3.3.

**Confirmed limitation:** the namespace-tag grouping pattern does **not** work for VKS cluster nodes (grouped via separate, auto-generated tags instead) or for workloads on a *shared* VPC subnet — plan a separate grouping strategy for those before assuming one pattern covers a whole tenant.

### 8.3 Application Segmentation & Ringfencing

Where an application maps one-to-one onto a namespace, application segmentation is namespace segmentation (§8.2) by another name. Where it doesn't — an app spanning multiple namespaces, or a namespace hosting multiple apps that shouldn't reach each other — **app ringfencing** groups by a custom label instead of the namespace tag:

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

**Terraform vs. Argo CD:** because a new application being ringfenced is exactly the kind of change that happens continuously as a tenant's portfolio grows, this is squarely an Argo CD-owned, day-2 change — a PR adding `app01`'s group and policy to the tenant's Git path, reviewed by `CODEOWNERS`, synced automatically.

### 8.4 Application Day-0 Provisioned Security

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

Paired with a `NetworkSecurityGroup` selecting `protected/env: dev` and an `Environment`-category `FirewallPolicy` (jump-to-application intra-group, allow outbound, drop everything else) provisioned *before* any workload exists, the VM is born inside its governing policy — there is no window where it's powered on but unprotected, and no manual step for an app owner to remember.

**Terraform (day-0):** owns both the group and the policy as part of the tenant baseline in §6.3, exactly like §8.2's namespace pattern — the only difference is the selector (`protected/env`, an explicit label) rather than the automatic namespace tag. This is the pattern to reach for when grouping needs to cut across namespaces by role (`dev`, `staging`) rather than by tenant boundary.

### 8.5 Using Transit Gateway (TGW) for Tenant Security

For a tenant whose architecture spans multiple VPCs attached to a shared Transit Gateway, `TGWFirewallPolicy` gives finer control than the blunt Community/Isolated/Promiscuous-style connectivity posture set by a `VPCConnectivityProfile`. It has its own master switch: a `TGWFirewallPolicy` enforces nothing until the Transit Gateway's `TGWSecurityConfig` explicitly enables the `GatewayFirewall` feature.

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

**Terraform (day-0):** `TGWSecurityConfig` is a platform-owned object, provisioned once alongside the shared `TransitGateway` — not per tenant. A pre-merge check in the tenant GitOps pipeline should reject a `TGWFirewallPolicy` PR if the target gateway's `TGWSecurityConfig` isn't already enabled; otherwise the rules merge cleanly and silently do nothing.

**Argo CD (day-2):** tenant-specific `TGWFirewallPolicy` rules — carving out exactly which cross-VPC paths a multi-VPC tenant needs — are layered in the same way as any other tenant policy change, reviewed and synced from the tenant's Git path. Because a misconfigured rule here can affect traffic between *multiple* tenants' VPCs at once, review authority stays with the Security Admin from §3.3 rather than the tenant alone.

### 8.6 Known Platform Limitations and Considerations

Carried through rather than glossed over, because a platform team building automation around these objects needs to design around them, not discover them in production:

- Protected labels and namespace-tag grouping (§8.2, §8.4) do not work for VKS cluster nodes or for workloads attached to a *shared* VPC subnet — plan a separate grouping strategy (auto-generated tags, or explicit labels) for those workloads.
- Auto-created groups are required for load-balancer VIPs and SNAT — they can't be hand-substituted with a custom group.
- Custom `NetworkService` definitions have been observed to reject at least some arbitrary TCP ports (e.g. the Kubernetes API's `6443`) — verify a custom `NetworkService` actually applies before depending on it in a pipeline.
- A Project's Supervisor context cannot see or reuse VPC-scoped groups (`VPCNetworkSecurityGroup`) the way it can region-scoped `NetworkSecurityGroup` objects — don't assume every automation surface a tenant touches can reach both kinds equally.
- Essential-services rules generated by a `SecurityProfile` (DNS/NTP/DHCP/ICMP) always allow both directions and can't be narrowed per profile; and a profile's east-west/north-south behavior can't be customized beyond selecting one of the five named strategies.
- VPC Security Profiles do not affect NSX Project default DFW rules (an NSX-level, not VCF-Automation-level, construct) — if an environment falls back to default DFW behavior, the Security Profile catalog is not the layer that changed it.

Practically: the ringfencing and Day-0 patterns in §8.3–8.4 are mature for VM-based workloads today; for VKS/Supervisor workloads, plan on NSX-native grouping and policy authoring as the interim path until CCI-native support catches up, and revisit this section against the current release notes before finalizing a design.

---

## 9. The User Journey: A Worked End-to-End Example

**Scenario**: Tenant `acme` needs a `web` / `app` / `db` three-tier application with default-deny micro-segmentation and a locked-down perimeter, permitting only public HTTPS to the web tier, `web → app:8443`, and `app → db:5432`.

### 9.1 Terraform Onboarding

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

### 9.2 Handoff to Argo CD

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

`acme-web-tier-vpc` mirrors `acme-web-tier` as a separate `VPCNetworkSecurityGroup` — `VPCGatewayFirewallPolicy` rules can't reference the region-scoped `NetworkSecurityGroup` kind (§4.2).

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

### 9.3 Day-2, Tenant-Driven Change

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

### 9.4 Multi-VPC Extension

If Acme later splits into a `prod` VPC and a `shared-services` VPC on a common Transit Gateway, a `TGWFirewallPolicy` (§8.5) is added to allow only the specific east-west paths needed between them, rather than relying on the coarser connectivity posture alone.

---

## 10. Conclusion

Multi-tenant security in VCF 9.1 works when it is designed as a set of composable, API-addressable layers — VPC-level Security Profiles, namespace isolation, application ringfencing, and Transit Gateway policy — each with a clear owner and a clear delegation boundary (§3, §5). Because every layer is a Kubernetes-native custom resource under the VCF Automation Consumption API (§4), the same design pattern is automatable on day one with exactly two tools a platform team already runs: Terraform for the atomic, reviewed day-0 baseline (§6), and Argo CD for the continuously reconciled day-2 policy lifecycle (§7). §8 and §9 show that pairing holding up against real, live-environment scenarios — not just a diagram.

**The final thought worth remembering:** by moving enforcement into the hypervisor and consuming it through the same Terraform-and-GitOps surface as every other piece of infrastructure, security stops being a checkpoint someone has to clear and becomes an ambient property of the platform itself. VCF with vDefend doesn't just secure applications — it lets security be measured the way the rest of the business measures itself: faster time-to-market, lower operational cost, and continuous, demonstrable compliance.

---

## Appendix A. VCFA/CCI API Reference

The authoritative, current source for this API is Broadcom's CCI API documentation: [developer.broadcom.com/xapis/cci-api](https://developer.broadcom.com/xapis/cci-api/latest/api-docs.html#k8s-api-vpc-nsx-vmware-com-v1alpha1) — verify field-level details there before an automation module hard-codes an assumption this reference doesn't cover. What follows is the field-by-field detail behind the condensed table in §4.2, confirmed against a running VCF 9.1 environment.

### A.1 `NetworkSecurityGroup` / `VPCNetworkSecurityGroup` — the reusable "who"

The verified schema splits this into **two** kinds, scoped differently:

- **`NetworkSecurityGroup`** is scoped by a required `spec.regionName` (not a VPC). `FirewallPolicy` (east-west/DFW) and `TGWFirewallPolicy` (inter-VPC) rules reference these by name.
- **`VPCNetworkSecurityGroup`** is scoped by a required `spec.vpcName` instead. `VPCGatewayFirewallPolicy` (north-south perimeter) rules reference these instead of the region-scoped kind.

Both kinds share the same membership shape: static `ipAddresses[]` (single IPs, ranges, or CIDRs), static `vms[]` (by `instanceUUID`), dynamic `vmSelectors[]`/`podSelectors[]` (each a `labelSelector` and/or `namespaceSelector`, plus a VM-only `propertySelector` matching on `Name`/`OSName`/`ComputerName`), and nested group references (`networkSecurityGroupNames[]`/`vpcNetworkSecurityGroupNames[]`). There is no `memberSelector` wrapper — these are all top-level `spec` fields.

**Free namespace-scoped grouping via auto-tags.** VCF Automation automatically tags every VM's network interface with `kubernetes.io/metadata.name: <namespace name>` and `nsx-op/vm_namespace: <namespace name>` the moment it's deployed into a Supervisor Namespace — no manual labeling required (used throughout §8.2 and §8.4). Confirmed limitations: this pattern does not work for VKS cluster nodes (grouped via separate, auto-generated tags) or for workloads on a shared VPC subnet.

### A.2 `SecurityProfile` + `SecurityProfileAttachment` — the VPC's security posture

`SecurityProfile` is a standalone, `regionName`-scoped object — it does nothing on its own. `SecurityProfileAttachment` (`regionName` + `securityProfileName` + `vpcName`, all required) is what binds it to a VPC. `SecurityProfileSpec` controls VPC-wide enforcement behavior — whether the north-south firewall is enabled, and which east-west strategy applies (`none`, `vpc-isolation`, `vpc-secure-connection`, `vpc-isolation-with-essential-services`, `vpc-external-connectivity`). There is no `tcpStrict` field here (that's per-firewall-policy-kind) and no IDS/IPS or Malware Prevention profile reference field in this API group.

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
| **VCF Automation** | The self-service consumption layer of VCF, exposing CCI |
| **CCI** | Cloud Consumption Interface — VCF Automation's per-tenant Kubernetes API server |
| **vDefend** | Broadcom's security suite built into VCF (Distributed Firewall, Gateway Firewall, Transit Gateway Firewall) |
| **NSX** | The networking/security platform underlying vDefend's enforcement |
| **NSX Project** | NSX's representation of a VCF Organization/tenant |
| **VPC** | Virtual Private Cloud — the per-tenant network/security boundary inside VCF |
| **Supervisor Namespace** | A VPC-backed namespace; the unit a tenant Project owns and self-services within |
| **DFW** | Distributed Firewall — east-west, intra-VPC enforcement at the vNIC |
| **TGW** | Transit Gateway — the shared routing construct connecting multiple VPCs |
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
