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

## 2. Introduction & Business Context

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

## 3. The VCF Automation Consumption API (CCI): API-First Security Consumption

### 3.1 A Kubernetes-native control plane for infrastructure

VCF Automation's consumption layer — the Cloud Consumption Interface (CCI) — is built as a Kubernetes-native API: every consumable resource (Projects, Namespaces, VPCs, security bindings, RBAC) is a Kubernetes Custom Resource, reconciled the same way any Kubernetes controller reconciles desired state against actual state. Two API groups matter most for this paper:

- **`cci.vmware.com`** — Projects, catalog items, blueprints, instances, and the RBAC primitives (`ProjectRole`, `ProjectRoleBinding`) that scope who can act on what.
- **`vpc.nsx.vmware.com/v1alpha1`** — the networking and security surface: `VPC`, `SecurityProfile`, `SecurityProfileAttachment`, `NetworkSecurityGroup`, and `FirewallPolicy`.

This matters architecturally for one reason: **a Kubernetes-shaped API is naturally multi-tenant**. RBAC, namespacing, label selectors, and desired-state reconciliation are the same primitives that make Kubernetes itself safe to share across teams — VCF Automation reuses them instead of inventing a parallel permissions model for infrastructure.

### 3.2 Resource kinds relevant to security

| Kind | API Group | Purpose |
|---|---|---|
| `VPC` | `vpc.nsx.vmware.com/v1alpha1` | Tenant-scoped virtual private cloud; the unit a Security Profile attaches to |
| `SecurityProfile` | `vpc.nsx.vmware.com/v1alpha1` | A named, system- (or org-) defined security strategy that can be attached to a VPC |
| `SecurityProfileAttachment` | `vpc.nsx.vmware.com/v1alpha1` | The binding of a VPC to a specific `SecurityProfile` |
| `NetworkSecurityGroup` | `vpc.nsx.vmware.com/v1alpha1` | A label-selector-defined group of workloads (by namespace, by app label, etc.) |
| `FirewallPolicy` | `vpc.nsx.vmware.com/v1alpha1` | A set of DFW rules, scoped to a category and applied to one or more groups |
| `ProjectRole` / `ProjectRoleBinding` | `cci.vmware.com` | Fine-grained, project-scoped RBAC — who can read/attach/switch security resources |

### 3.3 One API surface, three consumption paths

Because all of the above are ordinary Kubernetes custom resources, they are reachable identically through:

1. The **VCF Automation UI**, for interactive administration and visibility.
2. **`kubectl`**, against a VCF Automation Org/Project context (`vcf context use <org>`), for scripting and troubleshooting.
3. **Terraform** and **GitOps controllers** (Argo CD), for repeatable, versioned, and continuously reconciled infrastructure delivery.

This is the property that makes the design pattern in Section 4 portable across the console, day-0 automation, and day-2 GitOps — it is the same resource model underneath all three.

---

## 4. Design Pattern: Mapping vDefend Security to Tenants via API

This is the central section of the paper. It walks through the concrete, field-tested use cases for consuming vDefend security through the VCF Automation Consumption API, moving from the VPC boundary down to the individual application, then closes with the delegation model and the known constraints an architect needs to design around today.

### 4.1 VPC Segmentation via vDefend Security Profiles

The foundation of the self-service model is a small, fixed catalog of **system-defined Security Profiles**, each representing a named security *strategy* for a VPC's north-south and VPC-to-VPC traffic. A Tenant Admin does not write DFW rules — they select a strategy, and the platform materializes the underlying policy.

The five strategies, from most to least restrictive:

| Strategy | VPC outbound | VPC inbound | VPC-to-VPC | Notes |
|---|---|---|---|---|
| **None (Default)** | Allowed | Allowed | Allowed | No profile-level restriction; workload-level policy is the only control |
| **VPC Isolation** | Blocked | Blocked | Blocked | Workloads within the VPC may still talk to each other (Jump to Application) |
| **VPC Isolation with Essential Services** | Blocked, except DNS/NTP/DHCP/ICMP | Blocked, except DNS/NTP/DHCP/ICMP | Blocked | Same as above, plus essential infra services are allowed both ways |
| **VPC External Connectivity** | Allowed | Blocked, except Essential Services | Blocked | A VPC that needs to originate connections out but stay closed to inbound |
| **VPC Secure Connection** | Allowed | Blocked, except Essential Services | **Allowed** | Adds controlled VPC-to-VPC (e.g., shared-services) connectivity on top of External Connectivity |

Every strategy ends its rule table the same way: traffic that isn't explicitly permitted at the VPC boundary is either dropped, or handed off with a **Jump to Application** action — meaning the VPC-level profile defers the final decision to whatever `FirewallPolicy` exists at the Application category (Section 4.3). This two-tier model — a coarse, tenant-selected VPC posture, plus a fine-grained, workload-scoped application policy — is what lets a single Security Profile catalog serve very different applications safely.

**Consumption pattern.** A Tenant Admin (or their automation) reads the available profiles and the current attachment for their VPC:

```bash
vcf context use <org-name>
kubectl get securityprofiles
kubectl get securityprofileattachments
```

Switching a VPC to a different strategy is a single declarative patch against the attachment — not a rule rewrite:

```bash
kubectl patch securityprofileattachment vpc-dev -p \
  '{"spec":{"securityProfileName": "system-security-profile-2--m01-reg01"}}'
```

A platform team can also designate an org-wide default strategy (applied to any VPC that doesn't explicitly choose one) and independently toggle the VPC Gateway (north-south) Firewall for a profile:

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

The architectural payoff: a tenant's entire VPC security posture is one small, human-readable object. It can be reviewed in a pull request, reconciled by a GitOps controller, and audited from Git history — with no free-text firewall rule authoring exposed to the tenant at all.

### 4.2 Namespace Segmentation

Namespaces are the next scoping boundary down from the VPC, and VCF Automation supports two design blueprints:

- **Dedicated VPC** — one VPC per namespace (or per small group of namespaces). Namespace segmentation and VPC segmentation are the same boundary, so the Security Profile attached to the VPC *is* the namespace's security posture.
- **Shared VPC** — multiple namespaces share one VPC's address space and gateway. This is the common case for a "prod" VPC hosting several related application namespaces that need their own east-west isolation without provisioning a VPC each.

In the Shared VPC model, VCF Automation auto-tags every workload with its owning namespace:

- `kubernetes.io/metadata.name: <namespace-name>`
- `nsx-op/vm_namespace: <namespace-name>`

Because that tag is applied automatically to every existing and future VM deployed into the namespace, a platform team can build namespace isolation once, generically, using a label-selector-based `NetworkSecurityGroup` — no per-workload rule maintenance required:

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
```

...and a `FirewallPolicy` scoped to that group, permitting intra-namespace traffic and dropping everything else at the Environment category:

```yaml
apiVersion: vpc.nsx.vmware.com/v1alpha1
kind: FirewallPolicy
metadata:
  name: namespace-isolation-prod01
spec:
  appliedTo:
    groupNames: [prod01-namespace]
  category: Environment
  priority: 10001
  regionName: m01-reg01
  rules:
    - name: rule-01
      action: JumpToApplication
      direction: InOut
      from: [{groupName: prod01-namespace}]
      to: [{groupName: prod01-namespace}]
      services: [{networkServiceName: Any}]
    - name: rule-02
      action: Drop
      direction: InOut
      from: [{groupName: Any}]
      to: [{groupName: Any}]
      services: [{networkServiceName: Any}]
  stateful: true
  tcpStrict: true
```

This is a template the platform team authors **once** and instantiates per namespace — it is not something a tenant hand-writes.

### 4.3 Application Segmentation & Ringfencing

The final, finest-grained tier is the application itself. Where namespace isolation answers "can namespace A talk to namespace B," application ringfencing answers "which of the workloads inside my own namespace can talk to each other."

The pattern mirrors namespace segmentation but uses a tenant-defined label instead of the auto-assigned namespace tag — this is the piece an application team genuinely self-serves:

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
  vmSelectors:
    - labelSelector:
        matchExpressions:
          - key: protected/app01
            operator: Exists
```

The resulting `FirewallPolicy`, scoped to the Application category, demonstrates the fine-grained allow-list a ringfenced app typically needs — intra-app traffic, a specific inbound service, a specific outbound service, and a default lockdown:

```yaml
apiVersion: vpc.nsx.vmware.com/v1alpha1
kind: FirewallPolicy
metadata:
  name: app01-ringfencing
spec:
  appliedTo:
    groupNames: [app01]
  category: Application
  priority: 10002
  regionName: m01-reg01
  rules:
    - name: allow-app01-intra
      action: Allow
      direction: InOut
      from: [{groupName: app01}]
      to: [{groupName: app01}]
      services: [{networkServiceName: Any}]
    - name: allow-https-inbound
      action: Allow
      direction: In
      from: [{groupName: Any}]
      to: [{groupName: app01}]
      services: [{networkServiceName: HTTPS}]
    - name: allow-dns-outbound
      action: Allow
      direction: Out
      from: [{groupName: app01}]
      to: [{groupName: Any}]
      services: [{networkServiceName: DNS}, {networkServiceName: DNS-UDP}]
    - name: app01-lockdown
      action: Drop
      direction: InOut
      from: [{groupName: Any}]
      to: [{groupName: Any}]
      services: [{networkServiceName: Any}]
  stateful: true
  tcpStrict: true
```

This is the layer where "self-service security" is most literal: an application owner labels their own VMs and, through a thin abstraction (a catalog item, a Terraform module, or a GitOps overlay — see Sections 6–7), gets an app-scoped `NetworkSecurityGroup` and `FirewallPolicy` without ever touching NSX Manager or filing a firewall-change ticket.

### 4.4 Day-0 Provisioned Security

The pattern above (label → group → policy) generalizes into the mechanism that makes security "out-of-the-box" rather than bolted on after deployment: the label is applied **at VM creation time**, as part of the VM Service spec, so the workload is a member of its security group — and therefore covered by its firewall policy — from the moment it powers on:

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

Because the group and its lockdown policy already exist (typically provisioned as part of the tenant/environment onboarding in Section 8), there is no window between "VM boots" and "VM is protected." This is the practical definition of day-0 security in this design pattern: **groups and policies precede workloads**, not the other way around.

### 4.5 Delegation Model and Guardrails-as-Code

Pulling 4.1–4.4 together, the delegation boundary looks like this:

| Actor | Self-service | Centrally governed |
|---|---|---|
| **Platform/Security team** | — | The catalog of system Security Profiles; org default strategy; namespace-isolation policy templates; Application-category priority conventions |
| **Tenant Admin** | Select/switch a VPC's Security Profile; toggle the Gateway Firewall | Cannot invent a new VPC-level strategy outside the catalog |
| **Application owner** | Label workloads; request an app-scoped `NetworkSecurityGroup`/`FirewallPolicy` via catalog item or Terraform module | Cannot bypass namespace isolation or the VPC-level profile |

The concrete escape hatch worth calling out explicitly: **a policy created by a Security Profile cannot be edited directly.** Its rules are fixed by the profile definition. Customizing behavior means authoring a *separate*, higher-priority `FirewallPolicy` that is evaluated before the profile-owned one — exactly the pattern shown in Sections 4.2 and 4.3. This is a deliberate guardrail: it keeps the system-owned baseline tamper-evident (nobody can silently punch a hole in the profile itself) while still giving tenants and application teams a supported way to add precision on top of it.

### 4.6 Known Consumption Gaps and Design Constraints

An honest design pattern includes the edges of the current release. These are not criticisms of the platform — they are constraints an architect should design around today:

- **Private-VPC subnet workloads exposed via DNAT or a load balancer VIP** can behave unexpectedly under the "VPC Isolation" strategy, since the profile's VPC-boundary rules are evaluated against the workload's real (private) address, not the externally exposed one. Validate exposed-service behavior explicitly when selecting this strategy for a VPC that also fronts a load balancer.
- **"VPC Secure Connection" does not extend to Private-VPC subnet workloads' cross-VPC communication** — it governs the VPC boundary, not private-subnet-to-private-subnet paths across VPCs. Don't assume this strategy alone solves cross-VPC connectivity for private subnets.
- **VPC Security Profiles do not affect NSX Project default DFW rules** (an NSX-level, not VCF-Automation-level, construct). If an environment falls back to default DFW behavior, know that the Security Profile catalog is not the layer that changed it.
- **Supervisor and VKS have narrower support today**: "protected" labels used in Sections 4.3–4.4 do not currently apply to VKS clusters, nor to workloads connected to a shared VPC subnet. VKS workload grouping instead relies on NSX's auto-generated tags, and there is no support yet for defining custom services (e.g., a user-defined TCP/6443 rule for the Kubernetes API) at the CCI layer. Auto-created groups are still required to support load-balancer VIP and SNAT paths.

Practically: the ringfencing and Day-0 patterns in 4.3–4.4 are mature for VM-based workloads today; for VKS/Supervisor workloads, plan on NSX-native grouping and policy authoring as the interim path until CCI-native support catches up, and revisit this section against the current release notes before finalizing a design.

---

## 5. Reference Architecture

### 5.1 Layered model

```
Organization
 └─ Project (tenant boundary, RBAC via ProjectRole/ProjectRoleBinding)
     └─ VPC  ──── SecurityProfileAttachment ──── SecurityProfile (VPC-level posture, §4.1)
         └─ Namespace(s)  ──── NetworkSecurityGroup + FirewallPolicy (namespace isolation, §4.2)
             └─ Application  ──── NetworkSecurityGroup + FirewallPolicy (app ringfencing, §4.3)
                 └─ VirtualMachine (labeled at creation — Day-0 security, §4.4)
```

Each layer's security object is scoped and owned independently, but they compose through the "Jump to Application" handoff described in Section 4.1: a packet that survives the VPC-level profile is then evaluated against namespace policy, then application policy. No single layer needs to encode the full picture.

### 5.2 Provisioning sequence

1. **Platform team (once)**: publish the Security Profile catalog, namespace-isolation policy template, and Application-category priority convention.
2. **Tenant onboarding (day-0)**: create Project → create VPC → attach a Security Profile → create namespace(s), which auto-inherit namespace-isolation policy.
3. **Application onboarding (day-0/day-1)**: label workloads → provision app-scoped `NetworkSecurityGroup`/`FirewallPolicy` → deploy VMs already carrying the label.
4. **Ongoing (day-2)**: tenant switches Security Profile as needs change; application owners adjust their own ringfencing rules within the guardrails above.

### 5.3 Where Terraform and Argo CD fit

Steps 1–2 above are naturally **Terraform's** territory: infrequent, platform/security-admin-owned, PR-reviewed changes to the tenant's foundational posture. Steps 3–4 are naturally **Argo CD's** territory: frequent, application-team-owned, continuously reconciled changes that should self-heal if someone edits a rule out-of-band. Section 8 walks through this composite flow end-to-end.

---

## 6. Implementation Workflow: Infrastructure as Code with Terraform

### 6.1 Role of `terraform-provider-vcfa`

The official Terraform Provider for VCF Automation (`terraform-provider-vcfa`) exposes the same CCI resource model described in Sections 3–4 as Terraform resources, letting a platform team provision Projects, VPCs, and their Security Profile attachments through a normal PR-reviewed IaC pipeline rather than imperative `kubectl` commands.

### 6.2 Illustrative snippet

```hcl
resource "vcfa_vpc" "tenant_prod" {
  name        = "vpc-prod"
  region_name = "m01-reg01"
  private_ips = ["10.20.0.0/16"]
}

resource "vcfa_security_profile_attachment" "tenant_prod" {
  vpc_name             = vcfa_vpc.tenant_prod.name
  security_profile_name = "system-security-profile-3--m01-reg01" # VPC Isolation w/ Essential Services
}
```

This is illustrative of the pattern — provision the VPC, attach a catalog Security Profile by name — rather than a complete, ready-to-apply module. Treat the actual resource and attribute names as subject to the provider's current schema.

### 6.3 Pipeline pattern

Because Security Profile attachment is the tenant's foundational security posture, treat it like any other platform-owned infrastructure change:

- Changes land as pull requests against a per-tenant `.tf` file or module invocation.
- The platform/security team reviews and approves changes to which Security Profile a VPC is attached to.
- `terraform plan` output becomes the audit trail for "who changed a tenant's security posture and when" — a property that ad hoc `kubectl patch` commands don't give you for free.

### 6.4 State and drift in a multi-tenant context

Two things to design deliberately:

- **State isolation per tenant** (workspace, or state file per Project) so one tenant's `terraform apply` cannot blast-radius into another's resources.
- **Drift detection cadence** — because the underlying resources are reconciled continuously by the CCI controllers, out-of-band changes (e.g., a Tenant Admin flipping a profile through the UI) will drift from Terraform's last-known state. Decide up front whether Terraform is the sole path for VPC-level profile changes, or whether it's expected to reconcile drift on a schedule.

---

## 7. Implementation Workflow: GitOps with Argo CD

### 7.1 Role of the Broadcom Argo CD Operator for VCF

The Broadcom-built Argo CD Operator for VCF runs on vSphere Supervisor and is purpose-built to integrate with VCF's namespace and RBAC model — Argo CD `AppProject`s and `Application`s map naturally onto VCF Automation Projects and Namespaces, and its access control respects namespace boundaries rather than requiring a separate authorization layer.

This makes it the natural fit for the **day-2, continuously reconciled** half of the design pattern in Section 5.3: application-level `NetworkSecurityGroup` and `FirewallPolicy` objects (Sections 4.3–4.4), which change more often and benefit most from drift correction and self-healing.

### 7.2 Illustrative snippet

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: app01-security
  namespace: argocd
spec:
  project: prod01-namespace
  source:
    repoURL: https://git.example.com/platform/tenant-security-policies.git
    path: apps/app01/security
    targetRevision: main
  destination:
    namespace: prod01-8sg7f
  syncPolicy:
    automated:
      selfHeal: true
      prune: true
```

`selfHeal: true` is the operative setting for security posture specifically: if a `FirewallPolicy` is edited or deleted out-of-band (accidentally, or by someone bypassing the intended process), Argo CD reverts it to the Git-declared state on the next sync — turning "security drift" into a self-correcting property instead of something that has to be caught by an audit.

### 7.3 Repository structure and sync ordering

A per-tenant repository (or a per-tenant path within a shared repo) works well, mirroring the layered model from Section 5.1:

```
tenant-security-policies/
├── namespaces/prod01/isolation-policy.yaml        # sync wave 0
├── apps/app01/security/                           # sync wave 1
│   ├── network-security-group.yaml
│   └── firewall-policy.yaml
└── apps/app02/security/                           # sync wave 1
```

Sync waves (or App-of-Apps ordering) matter here for the same reason `priority` matters in Section 4.5: a namespace-isolation policy should exist before an application policy is layered on top of it, so the intermediate state is never "wide open."

### 7.4 Drift detection as a security property, not just a hygiene property

Frame this explicitly to stakeholders: in a manually managed DFW environment, "someone changed a rule without going through review" is usually discovered during an audit, if at all. In the GitOps model described here, it's discovered — and reverted — within one reconciliation interval.

---

## 8. End-to-End Self-Service Flow: From Tenant Onboarding to Protected Workload

Composing Sections 5–7 into a single walkthrough:

1. **Platform team (Terraform, one-time per tenant)** — creates the tenant's Project and VPC, and attaches the appropriate Security Profile from the catalog (Section 6). This is the PR-reviewed, infrequent, foundational step.
2. **Platform team (Terraform or catalog item)** — provisions the tenant's namespace(s) with the standard namespace-isolation `FirewallPolicy` template (Section 4.2) applied automatically.
3. **Application team (Git commit → Argo CD)** — commits a `NetworkSecurityGroup` + `FirewallPolicy` pair for their application under the tenant's repository path (Section 7), scoped by a label they control.
4. **Application team (VM Service spec)** — deploys their VM(s) carrying the label from step 3, so the workload is a member of its security group from boot (Section 4.4).
5. **Day-2** — the application team iterates on their own `FirewallPolicy` (adding a service, adjusting a rule) purely through Git; Argo CD reconciles and self-heals it. Tenant-level posture changes (switching Security Profile) go back through the Terraform path in step 1, preserving the review boundary between "my app's rules" and "my tenant's foundational posture."

What the Tenant Admin experiences: pick a Security Profile at onboarding, then largely stay out of day-2 application security decisions. What the application team experiences: label a VM, commit a policy file, and get a working, isolated application without ever opening NSX Manager. What the platform team retains: sole, auditable control over the Security Profile catalog and the boundary between tenants.

---

## 9. Conclusion

Multi-tenant security in VCF 9.1 works when it is designed as three composable, API-addressable layers — VPC-level Security Profiles, namespace isolation, and application ringfencing — each with a clear owner and a clear delegation boundary. Because every layer is a Kubernetes-native custom resource under the VCF Automation Consumption API, the same design pattern is consumable identically from the console, from `kubectl`, from Terraform, and from a GitOps controller like Argo CD. That consistency is what turns "self-service security" from a slogan into an operating model: platform teams author guardrails once, as code; tenants and application teams consume them declaratively, day-0, with the freedom to adjust their own posture inside those guardrails and the confidence that drift outside them gets corrected automatically.

---

## 10. Appendix

### A. Glossary

- **CCI** — Cloud Consumption Interface; the Kubernetes-native API layer underlying VCF Automation's consumption experience.
- **DFW** — Distributed Firewall; vDefend's workload-level, hypervisor-enforced firewall.
- **NDR** — Network Detection and Response; a vDefend capability outside the scope of this paper's API consumption pattern.
- **VPC** — Virtual Private Cloud; the tenant-facing network and security scoping boundary in VCF Automation.
- **Tenant Admin** — the delegated administrator role for a Project/VPC, distinct from the platform-level Cloud/Org Admin.
- **Security Profile** — a named, catalog-defined VPC security strategy (Section 4.1).
- **Security Profile Attachment** — the binding of a specific VPC to a Security Profile.

### B. Illustrative Terraform snippet (extended)

See Section 6.2. Treat resource/attribute names as illustrative of the pattern, not a pinned schema — validate against the current `terraform-provider-vcfa` documentation before use.

### C. Illustrative Argo CD Application manifest (extended)

See Section 7.2.

### D. Illustrative CRD examples

See Sections 4.1–4.4 for `SecurityProfileAttachment` patches, the namespace-isolation `FirewallPolicy`, and the app-ringfencing `NetworkSecurityGroup`/`FirewallPolicy` pair.

### E. Reference links

- Broadcom TechDocs — VMware Cloud Foundation 9.x design library, Network Consumption Models
- `github.com/vmware/terraform-provider-vcfa`
- VMware Cloud Foundation Blog — vDefend for VCF 9.1: Zero Trust Lateral Security; GitOps for VCF: Broadcom Argo CD Operator
