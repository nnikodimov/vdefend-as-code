# Automating Tenant vDefend Security Configuration with VCF Automation, Terraform, and Argo CD

**A Technical White Paper**

*Audience: Platform, cloud, and security architects designing self-service, policy-as-code workflows for tenant network security on VMware Cloud Foundation (VCF).*

---

## Abstract

VMware Cloud Foundation (VCF) 9's VPC (Virtual Private Cloud) model exposes NSX networking and **vDefend** security — Distributed Firewall (micro-segmentation), VPC Gateway Firewall, and Transit Gateway Firewall — as declarative Kubernetes-style custom resources through VCF Automation's **Cloud Consumption Interface (CCI)**, under the `vpc.nsx.vmware.com/v1alpha1` API group. This turns tenant security configuration from a series of NSX Manager UI clicks into version-controlled, reviewable, and automatable code. This paper focuses on the five resource kinds that carry that security model — **`NetworkSecurityGroup`**, **`SecurityProfile`**, **`FirewallPolicy`**, **`VPCGatewayFirewallPolicy`**, and **`TGWFirewallPolicy`** — and presents two production-grade automation patterns against them: **Terraform** (apply-time infrastructure-as-code) and **Argo CD** (continuous GitOps reconciliation), including a worked multi-tier tenant onboarding example with runnable code.

> **Accuracy note:** The Broadcom Developer Portal's interactive API reference for `xapis/cci-api` (`vpc.nsx.vmware.com/v1alpha1`) renders as a JavaScript single-page app; automated retrieval of its raw schema was not possible while researching this paper, so exact field names below are reconstructed from Broadcom's published NSX VPC administration guides (Groups in an NSX VPC, Firewall Policies in an NSX VPC, VPC Security Profile status/API, VPC Connectivity Policies) rather than copied verbatim from the Swagger definitions. The **resource kinds, their purpose, and their relationships to each other are accurate**; treat the exact spec field names in the YAML examples as representative and confirm them against your environment with `kubectl explain <kind> --api-version=vpc.nsx.vmware.com/v1alpha1` or the live Swagger UI before committing production manifests.

---

## 1. Executive Summary

Traditionally, configuring per-tenant network security in an NSX-backed private cloud meant a security admin logging into NSX Manager, building Groups and DFW/gateway firewall rules by hand, and hoping change control caught drift. VCF Automation's CCI changes this by projecting a VPC's entire security model — group membership, firewall behavior toggles, and firewall rules at three distinct enforcement points — as Kubernetes custom resources scoped to a **Supervisor Namespace** inside a tenant **Project**. Because these are ordinary Kubernetes objects behind a standard API server, every mainstream infrastructure-as-code and GitOps tool works against them without a bespoke integration.

The five resource kinds this paper focuses on map directly onto NSX's three real enforcement points inside and around a VPC:

| Resource kind | Enforcement point | Analogous to |
|---|---|---|
| `NetworkSecurityGroup` | N/A — reusable membership object | An NSX Group, scoped to a VPC |
| `SecurityProfile` | N/A — cross-cutting policy-mode object | The NSX `VpcSecurityProfile` (e.g. north-south firewall on/off, TCP-strict mode) |
| `FirewallPolicy` | East-west, intra-VPC | The Distributed Firewall (micro-segmentation) |
| `VPCGatewayFirewallPolicy` | North-south, per-VPC perimeter | The VPC's Gateway Firewall |
| `TGWFirewallPolicy` | East-west, inter-VPC | Transit Gateway firewalling / VPC Connectivity Policies |

This gives platform teams two complementary automation levers:

1. **Terraform**, using the `kubernetes` provider (fed a kubeconfig retrieved from the `vcfa` provider) to declare these objects as part of a tenant's provisioning pipeline — good for day-0 environment stand-up and for teams already standardized on Terraform for multi-cloud IaC.
2. **Argo CD**, registering the tenant's Supervisor Namespace as a target and continuously reconciling `NetworkSecurityGroup`/`FirewallPolicy`/`VPCGatewayFirewallPolicy`/`TGWFirewallPolicy` manifests from Git — good for day-2 drift correction, self-healing enforcement, and a pure GitOps self-service loop.

The recommended pattern for most enterprises is **hybrid**: Terraform provisions the tenant "shell" (Project, VPC, Subnets, quotas, RBAC, and a baseline `SecurityProfile`/default-deny `FirewallPolicy`) as part of the onboarding pipeline, and Argo CD owns the day-2 lifecycle of `NetworkSecurityGroup`, `FirewallPolicy`, `VPCGatewayFirewallPolicy`, and `TGWFirewallPolicy` objects as long-lived, continuously reconciled state that tenants and security teams iterate on independently of infrastructure changes.

---

## 2. Background: VCF Automation, CCI, and the VPC Security Model

### 2.1 Cloud Consumption Interface (CCI)

CCI is the Kubernetes-style consumption layer of VCF Automation. Instead of a proprietary REST API, CCI exposes a real Kubernetes API server: tenants authenticate, receive a **kubeconfig context per Supervisor Namespace** their Project owns, and interact with it via `kubectl`, any Kubernetes client library, Terraform's `kubernetes`/`kubectl` providers, or a GitOps controller like Argo CD. Relevant API groups include:

| API group | Purpose |
|---|---|
| `project.cci.vmware.com/v1alpha2` | Tenant Project definition (the top-level multi-tenancy boundary) |
| `infrastructure.cci.vmware.com/v1alpha1-3` | Namespace classes, quotas, zone/region association — the guardrails a provider admin sets before a tenant gets self-service access |
| `authorization.cci.vmware.com/v1alpha1` | RBAC / role bindings scoped to a Project or namespace |
| `topology.cci.vmware.com/v1alpha1-2` | Region/zone/supervisor topology |
| `vpc.nsx.vmware.com/v1alpha1` | **VPC networking and vDefend security**: `VPC`, `Subnet`, `NetworkSecurityGroup`, `SecurityProfile`, `FirewallPolicy`, `VPCGatewayFirewallPolicy`, `TGWFirewallPolicy` |
| `vmoperator.vmware.com/v1alpha3` | VM lifecycle (the workloads the security policy protects) |

### 2.2 Multi-tenancy hierarchy

```
Provider Admin
   └─ Region (group of Supervisors)
        └─ Project  (tenant boundary; maps to an NSX Project)
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

A **Project** is the tenant. Everything a tenant can self-service — including security policy — is scoped inside the namespaces their Project owns, bounded by quotas and RBAC the provider admin defined up front via `infrastructure.cci.vmware.com` and `authorization.cci.vmware.com`. This is the enforcement point that makes tenant self-service safe: tenants can create/update `FirewallPolicy` and related objects freely inside their own namespace, but cannot touch another tenant's VPC or exceed their allotted network/compute quota.

### 2.3 vDefend security constructs surfaced through the VPC

vDefend is Broadcom's NSX-native security suite. Inside a VPC, its three enforcement points are:

- **Distributed Firewall (micro-segmentation)** — east-west enforcement at each workload's vNIC *within* a VPC, driven by `FirewallPolicy` objects that reference `NetworkSecurityGroup`s as source/destination. This is the primary object tenants author to isolate application tiers (e.g., only the app tier may talk to the DB tier on 5432).
- **VPC Gateway Firewall** — stateful north-south perimeter enforcement at the VPC's own gateway, driven by `VPCGatewayFirewallPolicy`. NSX creates a default allow-all north-south rule per VPC; tenants are expected to add explicit `VPCGatewayFirewallPolicy` rules to restrict what can enter or leave the VPC boundary.
- **Transit Gateway Firewall (inter-VPC)** — east-west enforcement *between* VPCs that share a Transit Gateway, driven by `TGWFirewallPolicy`. This is the granular complement to the coarser Community/Isolated/Promiscuous VPC Connectivity Policies, letting a platform team carve out precise exceptions (e.g., "a shared-services VPC may reach any tenant VPC on port 443 only").
- **`SecurityProfile`** is not itself an enforcement point but the cross-cutting object that controls *how* the above behave for a given VPC — e.g., whether the VPC's north-south firewall is enabled at all, and whether TCP-strict mode is on.
- **IDS/IPS and Malware Prevention for vDefend** layer on top of these firewall rules as additional detection/prevention profiles (distributed or gateway-based); where exposed via CCI, they attach as profile references on `SecurityProfile` or the relevant `FirewallPolicy`/`VPCGatewayFirewallPolicy` object.

Automating "tenant vDefend security" in practice means automating these five resource kinds — declaratively, reviewably, in Git.

---

## 3. The vDefend Security Resources in `vpc.nsx.vmware.com/v1alpha1`

### 3.1 `NetworkSecurityGroup` — the reusable "who"

The Kubernetes-native mirror of an NSX VPC Group: a named, reusable set of workloads or addresses, defined by membership criteria rather than static IPs. `FirewallPolicy`, `VPCGatewayFirewallPolicy`, and `TGWFirewallPolicy` rules reference groups by name instead of embedding selectors inline — this indirection is what lets a tenant build a stable "web-tier / app-tier / db-tier" vocabulary once and reuse it across every policy that needs it.

```yaml
apiVersion: vpc.nsx.vmware.com/v1alpha1
kind: NetworkSecurityGroup
metadata:
  name: acme-app-tier
  namespace: acme-prod-ns01
spec:
  memberSelector:
    vmSelector:
      matchLabels:
        tier: app
---
apiVersion: vpc.nsx.vmware.com/v1alpha1
kind: NetworkSecurityGroup
metadata:
  name: acme-corp-admin-cidrs
  namespace: acme-prod-ns01
spec:
  memberSelector:
    ipAddresses:
      - 10.100.0.0/24
```

### 3.2 `SecurityProfile` — the VPC's security posture

Confirmed at the NSX Policy API level as `VpcSecurityProfile` (fields observed: `is_default`, `north_south_firewall.enabled`, `display_name`), this object controls VPC-wide enforcement behavior rather than individual rules — whether the Gateway Firewall is active at all, stateful/TCP-strict behavior, and (where licensed) which IDS/IPS or Malware Prevention profile applies.

```yaml
apiVersion: vpc.nsx.vmware.com/v1alpha1
kind: SecurityProfile
metadata:
  name: acme-vpc-security-profile
  namespace: acme-prod-ns01
spec:
  northSouthFirewall:
    enabled: true
  tcpStrict: true
  idsIpsProfile: default-standard-detection   # vDefend ATP, if licensed
```

### 3.3 `FirewallPolicy` — east-west (Distributed Firewall) rules

The general-purpose, intra-VPC micro-segmentation policy. Holds an ordered `rules[]` list where each rule's source/destination reference `NetworkSecurityGroup` names.

```yaml
apiVersion: vpc.nsx.vmware.com/v1alpha1
kind: FirewallPolicy
metadata:
  name: acme-tier-isolation
  namespace: acme-prod-ns01
spec:
  securityProfile: acme-vpc-security-profile
  rules:
    - name: allow-web-to-app
      direction: IN
      action: ALLOW
      sourceGroups: [acme-web-tier]
      destinationGroups: [acme-app-tier]
      services:
        - protocol: TCP
          destinationPorts: ["8443"]
    - name: deny-all-app-inbound
      direction: IN
      action: DROP
      destinationGroups: [acme-app-tier]
```

Key fields:

| Field | Purpose |
|---|---|
| `spec.securityProfile` | Reference to the `SecurityProfile` governing this policy's enforcement mode |
| `spec.rules[].direction` | `IN` / `OUT` |
| `spec.rules[].action` | `ALLOW` / `DROP` / `REJECT` |
| `spec.rules[].sourceGroups` / `destinationGroups` | Lists of `NetworkSecurityGroup` names — the label-based micro-segmentation building blocks |
| `spec.rules[].services` | Protocol/port match (with a port range field for ranges) |
| Rule order | Rules evaluate top-to-bottom within a `FirewallPolicy`; policy-to-policy ordering follows a priority/category field on the policy itself |

### 3.4 `VPCGatewayFirewallPolicy` — north-south perimeter rules

Same rule shape as `FirewallPolicy`, but scoped to the VPC's own gateway rather than to workload vNICs — this is the object a tenant edits to control what's allowed to enter or leave their VPC boundary.

```yaml
apiVersion: vpc.nsx.vmware.com/v1alpha1
kind: VPCGatewayFirewallPolicy
metadata:
  name: acme-perimeter
  namespace: acme-prod-ns01
spec:
  rules:
    - name: allow-inbound-https
      direction: IN
      action: ALLOW
      destinationGroups: [acme-web-tier]
      services:
        - protocol: TCP
          destinationPorts: ["443"]
    - name: deny-all-other-inbound
      direction: IN
      action: DROP
```

### 3.5 `TGWFirewallPolicy` — inter-VPC rules on a shared Transit Gateway

Applies where a tenant's (or the platform's) VPCs are attached to a common Transit Gateway and need finer control than the blunt Community/Isolated/Promiscuous connectivity posture — e.g., allowing a shared-services VPC to reach specific tenant VPCs on specific ports while otherwise remaining isolated. Note this capability requires the appropriate vDefend/Advanced Cyber Compliance licensing tier.

```yaml
apiVersion: vpc.nsx.vmware.com/v1alpha1
kind: TGWFirewallPolicy
metadata:
  name: acme-shared-services-access
  namespace: acme-prod-ns01
spec:
  transitGateway: corp-shared-tgw
  rules:
    - name: allow-shared-services-to-acme
      direction: IN
      action: ALLOW
      sourceGroups: [shared-services-vpc-egress]
      destinationGroups: [acme-app-tier]
      services:
        - protocol: TCP
          destinationPorts: ["443"]
    - name: deny-other-vpcs
      direction: IN
      action: DROP
```

### 3.6 How the five kinds compose

```
NetworkSecurityGroup  ──referenced by──▶  FirewallPolicy (east-west, intra-VPC)
        ▲                                  VPCGatewayFirewallPolicy (north-south)
        │                                  TGWFirewallPolicy (east-west, inter-VPC)
        │
SecurityProfile  ──governs enforcement mode of──▶  all of the above within a VPC
```

`NetworkSecurityGroup` is the only object the other three *require* to express meaningful rules; `SecurityProfile` is orthogonal and VPC-scoped. In practice, a tenant onboarding baseline creates one `SecurityProfile`, a handful of `NetworkSecurityGroup`s (one per application tier or trust zone), a default-deny `FirewallPolicy` and `VPCGatewayFirewallPolicy`, and adds `TGWFirewallPolicy` only if the tenant's architecture spans multiple VPCs.

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
      northSouthFirewall = { enabled = true }
      tcpStrict          = true
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
      memberSelector = { vmSelector = { matchLabels = { tier = "app" } } }
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
      rules = [
        { name = "deny-all-inbound", direction = "IN", action = "DROP" }
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
                     │   NSX Manager / Policy         │
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

**Step 1 (Terraform, onboarding pipeline)** — create the Project, VPC, Subnet, baseline `SecurityProfile`, tier `NetworkSecurityGroup`s, and default-deny `FirewallPolicy`/`VPCGatewayFirewallPolicy` (extends §4.3):

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
      securityProfile = "${var.tenant_name}-security-profile"
      rules = [
        { name = "deny-all-in", direction = "IN", action = "DROP" },
        { name = "deny-all-out", direction = "OUT", action = "DROP" }
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
  memberSelector:
    vmSelector:
      matchLabels: { tier: web }
---
apiVersion: vpc.nsx.vmware.com/v1alpha1
kind: NetworkSecurityGroup
metadata:
  name: acme-app-tier
  namespace: acme-prod-ns01
spec:
  memberSelector:
    vmSelector:
      matchLabels: { tier: app }
---
apiVersion: vpc.nsx.vmware.com/v1alpha1
kind: NetworkSecurityGroup
metadata:
  name: acme-db-tier
  namespace: acme-prod-ns01
spec:
  memberSelector:
    vmSelector:
      matchLabels: { tier: db }
```

`tenants/acme/security-policy/perimeter.yaml`:

```yaml
apiVersion: vpc.nsx.vmware.com/v1alpha1
kind: VPCGatewayFirewallPolicy
metadata:
  name: acme-perimeter
  namespace: acme-prod-ns01
spec:
  rules:
    - name: allow-inbound-https
      direction: IN
      action: ALLOW
      destinationGroups: [acme-web-tier]
      services:
        - protocol: TCP
          destinationPorts: ["443"]
    - name: deny-all-other-inbound
      direction: IN
      action: DROP
```

`tenants/acme/security-policy/tier-isolation.yaml`:

```yaml
apiVersion: vpc.nsx.vmware.com/v1alpha1
kind: FirewallPolicy
metadata:
  name: acme-tier-isolation
  namespace: acme-prod-ns01
spec:
  rules:
    - name: allow-web-to-app
      direction: IN
      action: ALLOW
      sourceGroups: [acme-web-tier]
      destinationGroups: [acme-app-tier]
      services:
        - protocol: TCP
          destinationPorts: ["8443"]
    - name: allow-app-to-db
      direction: IN
      action: ALLOW
      sourceGroups: [acme-app-tier]
      destinationGroups: [acme-db-tier]
      services:
        - protocol: TCP
          destinationPorts: ["5432"]
```

**Step 3 (day-2, tenant-driven)** — Acme's app team adds a `cache` tier. Their security engineer opens a PR adding a new `NetworkSecurityGroup` (`acme-cache-tier`) and a rule to `tier-isolation.yaml`:

```yaml
    - name: allow-app-to-cache
      direction: IN
      action: ALLOW
      sourceGroups: [acme-app-tier]
      destinationGroups: [acme-cache-tier]
      services:
        - protocol: TCP
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
- **Audit trail = Git history.** Because both patterns terminate in Git-reviewed changes, `git log` on the tenant security repo (or Terraform module) becomes your compliance evidence trail for "who approved this firewall change and when" — a materially stronger artifact than NSX Manager UI audit logs alone.
- **Feed enforcement telemetry back into the loop.** IDS/IPS and Malware Prevention detections (surfaced via NSX Intelligence / vDefend, and attached via `SecurityProfile`) should inform future `FirewallPolicy` tightening — treat detected-but-not-yet-blocked lateral movement attempts as backlog items for the next policy PR.
- **Watch the TGW blast radius.** `TGWFirewallPolicy` changes can affect traffic between multiple tenants' VPCs if they share a Transit Gateway — route these through the platform team's `AppProject`/module rather than granting individual tenants write access to this kind.

---

## 10. Conclusion

VCF Automation's CCI turns vDefend tenant security from an NSX-Manager, click-driven process into ordinary Kubernetes custom resources under `vpc.nsx.vmware.com/v1alpha1` — `NetworkSecurityGroup` for reusable workload membership, `SecurityProfile` for VPC-wide enforcement posture, and `FirewallPolicy` / `VPCGatewayFirewallPolicy` / `TGWFirewallPolicy` for the three real enforcement points (intra-VPC east-west, per-VPC north-south, and inter-VPC east-west, respectively). That single fact is what unlocks both Terraform and Argo CD as first-class automation paths without any custom tooling. Use Terraform for atomic, reviewed, day-0 tenant and baseline-policy provisioning; use Argo CD for continuous, self-healing, Git-driven day-2 policy management; and draw a hard ownership line between the two so they never fight over the same object. Combined with quota- and RBAC-based guardrails set by the provider team, this gives tenants real self-service over their own micro-segmentation posture — without giving up centralized governance, auditability, or the ability to prove compliance from Git history alone.

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
