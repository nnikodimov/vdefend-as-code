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
Security is usually where that pressure breaks something. If every new tenant, VPC, or application requires a security engineer to author the workload protection by hand, self-service infrastructure just relocates the bottleneck instead of removing it — provisioning is instant, but the workload sits unprotected (or blocked) until security work catches up.

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

Before any security design can be expressed as code, we need to understand what VCFA constructs a tenant actually consumes and how these are mapped with the underlying VCF private cloud infrastructure.

### 3.1 From VCFA Abstractions to Infrastructure

VCFA maps tenant abstractions onto native vSphere, VCF Networking (NSX) and Security (vDefend) constructs, using the vSphere Supervisor as its control plane and translation engine. A tenant never provisions resources by hand — they declare intent against VCFA, and the Supervisor renders it into the fabric objects underneath.
A provider admin establishes top-level administrative boundaries, while tenant users self-service consumable resources underneath within defined RBAC and quotas:

- **Organization:** The top-level tenant identity, governance, and quota boundary. Provisioning an Organization automatically provisions a corresponding NSX Project — a dedicated fabric-side domain that isolates tenant network addressing, routing, and security policies.
  - **Region:** Aggregates one or more vSphere Supervisors, compute clusters, storage, and shared NSX Manager instances into a placement target. Regions define security scope: vDefend constructs are Region-scoped, requiring tenants spanning multiple Regions to maintain security definitions within each.
    - **Project:** The self-service consumption boundary where tenant users operate. It carries assigned quotas and entitlements (accessible Regions, namespace classes, VM classes, storage policies) and bounds all tenant security policies.
      - **Virtual Private Cloud (VPC):** Realized as an NSX VPC inside the tenant's NSX Project. Provides a self-contained routed network domain with private address spaces, customizable subnets, local VPC Gateways, and optional Transit Gateway attachments. The VPC boundary is where Security Profiles attach and North-South perimeter traffic is evaluated.
        - **Subnet(s):** The underlying IP address space where workloads reside.
      - **vSphere Namespace:** A Kubernetes resource boundary mapped to a vSphere resource pool and folder carrying compute, memory, and storage limits. Each namespace binds to exactly one VPC, either as a dedicated (1:1) binding for strict isolation or a shared (N:1) binding to pool IP address space and gateway configurations across multiple namespaces.
        - **VirtualMachines:** Virtual machines managed via the VM Service Operator.
        - **VKS Cluster(s):** Kubernetes clusters whose control plane and worker nodes are provisioned as VMs on the same VPC subnets.
        - **vSphere Pods:** Containers running natively on ESXi hypervisors.

### 3.2 The vDefend Security Constructs Exposed to Tenants

vDefend security capabilities layer directly onto the VCFA infrastructure hierarchy across three distinct data-path enforcement points:

**Enforcement Points Across Boundaries**

- **Distributed Firewall (DFW):** LLateral Security (East-West) workload protection applied directly at the workload interface. Filters traffic within a VPC and namespaces or across VPCs without requiring traffic to route through a central bottleneck.
- **Transit Gateway Firewall:** North-South enforcement at the **Organization boundary** — the Transit Gateway is where a tenant's VPCs meet everything outside them, so this is the control point for what may enter or leave the tenant's domain as a whole.
- **VPC Gateway Firewall:** North-South enforcement at the **VPC perimeter edge**, filtering ingress and egress for a single VPC. Controls external exposure and ingress exceptions.

The two gateway firewalls are the same kind of control applied at different scopes: the Transit Gateway Firewall governs the tenant's outer boundary, the VPC Gateway Firewall governs one VPC's own edge inside it.

**Security Profiles**

Security Profiles package East-West strategy and VPC Gateway Firewall state into a single named configuration for a VPC. vDefend supplies a catalog of system-owned profiles ranging from fully open (default) to isolated VPC postures. Attaching a profile standardizes a VPC's perimeter security state into a single declarative object.

**Groups, Labels, and Services**

- **Groups:** Rule targets defined dynamically using label selectors, namespace membership, VM properties, CIDR blocks, or nested groups. Groups exist in two scopes: Region-scoped (referenced by DFW and Transit Gateway rules) and VPC-scoped (referenced by VPC Gateway rules).
- **Protected (Privileged) Labels:** Prefixed with protected/, these are specific workload labels that translate directly into NSX tags for group matching and security policy enforcement. They are restricted to authorized users only by a specific Role-Based Access Control (RBAC) permission. This RBAC barrier ensures application teams cannot remove mandatory compliance controls, bypass security policies, or self-assign elevated privileges on their workloads.
- **Services:** Named, reusable protocol and port definitions (TCP/UDP port sets, ICMP) and raw prtotocol support.

### 3.3 Who Can Change What: The RBAC Model

In VCFA, multi-tenancy is enforced directly by the Cloud Consumption Interface (CCI) API server control plane through native Kubernetes authorization primitives. This architectural design ensures that a tenant cannot exceed their allocated boundary, even when executing hand-crafted API calls, running unvetted automation scripts, or deploying misconfigured CI/CD pipelines.

Three integrated mechanisms establish and maintain strict isolation between tenant environments:

- **Project and Namespace Boundaries:** Every infrastructure resource provisioned by a tenant resides within a designated vSphere Namespace linked to a VCFA Project (project.cci.vmware.com). Because security policies, network micro-segmentation rules, and resource groups evaluate targets using localized names and key-value label selectors, the tenancy boundary maps directly to native Kubernetes namespace boundaries.
- **RBAC:** A tenant's authentication context, established via OIDC identity federation and managed through the VCF CLI, is bound strictly to ProjectRoleBinding custom resources (authorization.cci.vmware.com) within their project namespace. The CCI API server evaluates presented JWT tokens during the API admission phase and rejects any request targeting a namespace to which the token lacks explicit authorization bindings.
- **Resource Quotas and Namespace Classes:** Within their assigned namespace, tenants are subject to non-negotiable compute, memory, storage, and object limits established by provider administrators during Project setup. Defined via SupervisorNamespaceClassConfig specifications (spec.limits) and VCFA Resource Quota Policies, these resource ceilings are enforced at API admission, rendering unauthorized capacity expansion impossible from within the self-service layer.

**Roles and what each one owns.** VCFA RBAC and authorization bindings partition platform management across two provider-side and two tenant-side personas. This structural split is critical because the tenant tier enforces its own internal guardrail hierarchy, ensuring developers operate within boundaries established by both provider administrators and internal tenant security leads.

| Persona Tier | Role Name | Scope & Ownership | Guardrails & Restrictions |
|---|---|---|---|
| **Provider Tier** | **Cloud Admin (Provider) / Provider Security Admin** | Global infrastructure constructs: Organizations, Regions, Projects, resource quota policies, SupervisorNamespaceClass templates, and Region-Zone associations. Configures pre-tenant self-service guardrails. | Cannot provision tenant workloads directly or bypass multi-tenant namespace isolation boundaries. Provider-level security is authored in NSX. Enforce cross-tenant policy using the Default Project. |
| **Tenant Tier** | **Organization Admin / Security Admin** | Tenant Projects, NSX Virtual Private Clouds (VPCs), vSphere Namespaces, Security Strategy selection (Security Profile selection), organization-wide default security strategies, Transit Gateway Security, DFW Environment and Application category policies. VPC Gateway Firewall toggles, protected resource labels, and Org-wide policies. | Cannot create security strategies outside the organization scope or modify profile-generated provider baselines. |
| **Tenant Tier** | **Application Owner / Developer** | Application workloads (VMs, VKS Kubernetes clusters, Data Services), standard workload labels, and Application-category groups/policies inside assigned namespaces. | Cannot assign or remove protected labels, bypass namespace boundaries, or override VPC-level security postures set above them. |

**Context Scoping for Human and Machine Identities**

Each persona receives a kubeconfig context scoped strictly to the specific namespaces permitted by their ProjectRoleBinding (authorization.cci.vmware.com). Consequently, the same token that authorizes a developer to deploy a workload also acts as the boundary constraining their visibility across the platform. Resources outside a persona's assigned scope are neither writable nor discoverable through API enumeration — a key requirement that allows platform providers to safely expose standard Kubernetes API endpoints directly to tenants.

This principle applies equally to machine and automation identities (§6, §7). Whether provisioning infrastructure via a Terraform CI runner using a Cloud Consumption Interface (CCI) token or executing GitOps syncs through an Argo CD service account, automation credentials must be scoped strictly to the specific tenant namespace(s) they manage. Granting a pipeline Project-wide or Region-wide administrative credentials — even for platform-owned CI/CD runners — introduces a major security anti-pattern: it quietly undermines the tenant isolation model by creating a backchannel for privilege escalation beyond human authorization boundaries.

---

## 4. Consuming vDefend Through the CCI API

### 4.1 CCI as a Standard Kubernetes API Server

VCFA's **Cloud Consumption Interface (CCI)** is a native Kubernetes API server aggregator delivering a developer-centric IaaS consumption fabric that unifies multi-cluster vSphere Supervisors into a single API endpoint. A tenant (or a pipeline) authenticates and receives a **kubeconfig context scoped to their own vSphere Namespace** — nothing else is visible — via a token exchange (the `vcfa_kubeconfig` Terraform data source is the mechanism §6 uses). Consequently, standard Kubernetes ecosystem tooling operates against CCI directly — including kubectl, native client libraries, Terraform, and GitOps controllers like Argo CD — without requiring proprietary SDKs.

Within CCI structural hierarchy, the Organization serves as the top-level identity and administrative container for VCFA Projects. Authentication tokens — whether generated during a CLI login session or an automated Terraform pipeline run — evaluate directly against a subject's assigned Organization and Project role bindings (`ProjectRoleBinding`). Because the Organization is managed at the VCFA governance tier, it is not instantiated as an in-cluster Custom Resource Definition (CRD), unlike the Project resource (`project.cci.vmware.com`, §4.2), which exists natively as a declarative object within the CCI control plane.

### 4.2 The API Groups

CCI presents the constructs discussed in §3 across a handful of API groups. Tenants require no proprietary clients or vendor-specific SDKs. Standard Kubernetes tooling — whether `kubectl apply`, Terraform's `kubernetes_manifest` resource, or a GitOps controller like Argo CD — manages workload primitives like a `Deployment` and network security constructs like a `FirewallPolicy` using the exact same declarative workflow.

| API group | Purpose |
|---|---|
| `project.cci.vmware.com/v1alpha2` | Tenant Project definition (the top-level multi-tenancy boundary) |
| `infrastructure.cci.vmware.com` | Namespace classes, quotas, zone/region association — the guardrails a provider admin sets before self-service access |
| `authorization.cci.vmware.com` | RBAC / role bindings scoped to a Project or namespace |
| `vpc.nsx.vmware.com/v1alpha1` | **VPC networking and security**: `VPC`, `Subnet`, `NetworkSecurityGroup`/`VPCNetworkSecurityGroup`, `NetworkService`, `SecurityProfile`/`SecurityProfileAttachment`, `FirewallPolicy`, `VPCGatewayFirewallPolicy`, `TGWFirewallPolicy`/`TGWSecurityConfig`, `VPCConnectivityProfile`/`Binding` |
| `vmoperator.vmware.com/v1alpha3` | VM lifecycle — the workloads the security policy protects |

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
| Label (Protected) | *(no kind of its own)* | An attribute on the workload object; groups select on it |

### 4.4 A Note on Source Grounding

The schema in this paper is confirmed against a running VCF 9.1 environment (live `kubectl get` output, reproduced in §5) rather than assumed from documentation alone. The authoritative, current reference is Broadcom's published CCI API documentation at `https://developer.broadcom.com/xapis/cci-api/latest/api-docs.html` — check it directly before an automation module hard-codes an assumption this paper doesn't cover.

---

## 5. Use Cases and Design Patterns

Each subsection below walks through one concrete use case for consuming vDefend security through the VCFA Consumption API: what a tenant needs, the design pattern that solves it, and the API objects that implement it — confirmed against a live VCF 9.1 environment. §6 and §7 then show how Terraform and Argo CD actually deliver each pattern; this section stays at the level of the API itself.

### 5.1 VPC Segmentation

In VMware Cloud Foundation (VCF), a VPC is a self-service, logically isolated networking domain provisioned within a shared private cloud architecture. Its security posture, however, is an independent concern that has to be addressed. VCFA delivers the declarative self-service consumption layer through the Cloud Consumption Interface (CCI), while vDefend operates as the underlying enforcement engine that materializes Distributed Firewall (DFW) lateral security and VPC Gateway North-South perimeter protection.

**Declarative Security Profile Abstractions**

To bridge tenant self-service with a foundational workload protection, vDefend delivers the Security Strategies abstraction. These strategies are exposed via two declarative custom resources within the `vpc.nsx.vmware.com/v1alpha1` API group:

- **`SecurityProfile`**: A system-curated resource that specifies a standardized vDefend security strategy.
- **`SecurityProfileAttachment`**: A tenant-facing resource that binds a chosen `SecurityProfile` directly to a specific VPC.

The `SecurityProfile` resource offers five standardized strategies, each defining a distinct posture for VPC Inbound and Outbound traffic as well as cross-VPC communication. Rather than authoring low-level firewall rules manually, Tenant Admins select a strategy, allowing vDefend to materialize the corresponding security baseline:

| Strategy | VPC outbound | VPC inbound | VPC-to-VPC | Notes |
|---|---|---|---|---|
| **None (Default)** | Allowed | Allowed | Allowed | No profile-level restriction; workload-level policy is the only control |
| **VPC Isolation** | Blocked | Blocked | Blocked | Workloads within the VPC may still talk to each other (Jump to Application) |
| **VPC Isolation with Essential Services** | Blocked, except DNS/NTP/DHCP/ICMP | Blocked, except DNS/NTP/DHCP/ICMP | Blocked | Same as above, plus essential infra services are allowed both ways |
| **VPC External Connectivity** | Allowed | Blocked, except Essential Services | Blocked | A VPC that needs to originate connections out but stay closed to inbound |
| **VPC Secure Connection** | Allowed | Blocked, except Essential Services | **Allowed** | Adds controlled VPC-to-VPC (e.g., shared-services) connectivity on top of External Connectivity |

Every strategy follows the same basic pattern: traffic that isn't explicitly permitted at the VPC boundary is either dropped, or handed off with a **Jump to Application** action — meaning the VPC-level profile defers the final decision to the Application category `FirewallPolicy`. This is important to know, because if an application category policy does not exist, traffic that matches the **Jump to Application** rule in the Environment category will be allowed by default. As the Security Profiles DFW policies have the lowest priority in the Environment section, any custom-created policy and rule will have precedence for traffic inspection. This provides the flexibility for the tenant admin to customize the overall VPC security strategy when it is needed.

The two-tier model — a coarse, tenant admin selected VPC posture, plus a fine-grained, workload-scoped application policy — is what lets a single security profile serve very different applications' protection needs.

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

This is the platform-owned half of the same catalog a tenant only ever selects from: a platform team can also designate an org-wide default strategy and independently toggle the VPC Gateway (north-south) Firewall for a profile:

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

### 5.2 vSphere Namespace Segmentation

The vSphere Namespace serves as the primary administrative and logical boundary for resource allocation, access control, and multi-tenant workload isolation within the vSphere Supervisor. At creation time, every vSphere Namespace is bound to two fundamental construct definitions: a VPC assignment and a specific Namespace Class. A Namespace Class establishes the compute, memory, and storage quotas, VM classes, storage policies, and content libraries available to the namespace; it imposes no structural constraints or dependencies on the underlying network topology.

Platform teams have the operational flexibility to evaluate and assign VPC boundaries on a per-namespace basis, choosing between two basic architecture blueprints: a Dedicated VPC model and a Shared VPC model.

In the Dedicated VPC model, the namespace boundary and the network VPC boundary are structurally identical, providing isolated perimeter security via the VPC's Security Profile. In the Shared VPC model, multiple namespaces inhabit a single VPC, allowing applications to pool quota and share transit configurations while relying on micro-segmentation for east-west isolation. The decision to deploy either model hinges on a fundamental trade-off between strict perimeter isolation and resource efficiency.

- **Dedicated VPC** — the blueprint establishes a strict one-to-one mapping between a vSphere Namespace and a VPC. vDefend Security Profiles (§5.1) attached directly to the VPC can govern ingress and egress traffic crossing the VPC boundary, serving as the explicit security posture for the contained namespace. Because no other application namespaces reside within the same VPC address space, east-west network isolation between namespaces is guaranteed by the vDefend Security Strategy chosen.
- **Shared VPC** — the Shared VPC blueprint enables multiple vSphere Namespaces to occupy a single VPC address space, sharing a common VPC Gateway. This pattern is commonly deployed for application ecosystems that belong to a single administrative trust boundary (such as related production namespaces `prod01` and `prod02`). Consolidating namespaces into a shared VPC optimizes IP address space allocation, simplifies overall network routing, and allows for pooled network resource quotas. The traffic moving between subnets inside the same VPC is natively routed across distributed switches without traversing the VPC Gateway firewall. All Security Profiles have a default strategy to conditionally allow (**Jump to Application**) intra-VPC traffic, relying on more-granular DFW application category policies when such segmentation is required. To prevent unrestricted lateral movement between VPC co-located namespaces, platform teams must therefore deploy namespace-scoped Distributed Firewall (DFW) policies.

To bypass the operational burden of manually tracking IP address allocations when provisioning workloads, the Supervisor incorporates an automated infrastructure metadata tagging mechanism. When virtual machines, container hosts, or network interfaces are provisioned within a vSphere Namespace, the Supervisor automatically attaches standardized key-value tags to the underlying network constructs. In VCF Networking with VPC stack deployments, the Supervisor automatically applies the tag `nsx-op/vm_namespace` set to the namespace's name on every VPC subnet segment port created within that namespace. In deployments utilizing NSX Classic mode or legacy segment models, the system tags the NSX Segment directly using the scope `kubernetes.io/metadata.name`.

These auto-generated tags enable security architects to construct generic, dynamic Groups using label selectors. Rather than defining static IPv4 objects, the dynamic Group matches any segment port where the tag key `nsx-op/vm_namespace` equals the target namespace identifier.

As new Virtual Machines or VKS clusters scale up within the namespace, their interfaces automatically inherit the namespace tag and fall under the enforcement of the corresponding security policies.

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

Implementing segmentation across namespaces sharing a single VPC requires configuring Distributed Firewall (DFW) policy at the Tenant scope. The Organization Admins author the namespace isolation policy in the `Environment` category, to ensure security baseline precedence.

```yaml
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

**Note:** A primary operational complexity in Shared VPC topologies arises from handling non-deterministic IP services, such as Load Balancer Virtual Servers and Source Network Address Translation (SNAT) endpoints. By default, NSX assigns Load Balancer services and outbound SNAT IPs dynamically from the Project's shared External IP block. Because these ingress and egress IP addresses are allocated dynamically, dynamic segment port matching must be paired with explicit "IP Addresses Only" groups to account for Virtual IP (VIP) targets in cross-namespace firewall policies.

### 5.3 Application Ringfencing

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

For a tenant whose architecture spans multiple VPCs attached to the Organization's Transit Gateway, `TGWFirewallPolicy` gives finer control than the blunt Community/Isolated/Promiscuous-style connectivity posture set by a `VPCConnectivityProfile`. It has its own master switch: a `TGWFirewallPolicy` enforces nothing until the Transit Gateway's `TGWSecurityConfig` explicitly enables the `GatewayFirewall` feature. Both the Transit Gateway and its firewall are exposed to the tenant in VCFA, so `TGWSecurityConfig` is an Organization-level object the tenant's own admins own — provisioned once for the Organization, not per VPC.

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

Tenant-specific `TGWFirewallPolicy` rules carve out exactly which cross-VPC paths a multi-VPC tenant needs. Because the gateway sits at the Organization boundary, a misconfigured rule here can affect traffic across *every* VPC the Organization owns at once — a far wider blast radius than a single VPC's policy. Review authority therefore belongs with the Organization Security Admin (§3.3) rather than with an individual application team.

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
- **Transit Gateway (§5.5):** `TGWSecurityConfig` is an Organization-level object, provisioned once for the Organization rather than per VPC, so it belongs in the tenant onboarding baseline alongside the Project and VPCs. A pre-merge check in the tenant GitOps pipeline should reject a `TGWFirewallPolicy` PR if the target gateway's `TGWSecurityConfig` isn't already enabled; otherwise the rules merge cleanly and silently do nothing.

Application Segmentation & Ringfencing (§5.3) has no Terraform-owned piece — see §7.6.

---

## 7. Implementing Day-2 Operations with Argo CD (GitOps)

*(core technical section #2)*

### 7.1 Why GitOps for Continuous Security Policy

Security policy is not "set once at provisioning" — it changes continuously as tenant applications evolve (new microservice, new port, decommissioned tier). Treating it as a one-time Terraform apply leaves a gap for exactly the kind of manual, undocumented change that turns into an audit finding. Argo CD's continuous reconciliation loop closes that gap:

- **Drift correction.** If someone manually edits a `FirewallPolicy` or `NetworkSecurityGroup` via `kubectl` or the CCI UI, Argo CD reverts it (or flags `OutOfSync`) on the next sync — Git remains the enforceable source of truth for security posture.
- **Self-service without a pipeline run.** Tenant security engineers merge a PR against their tenant's policy repo; Argo CD picks it up within its poll/webhook interval — no separate CI job needs to hold cloud credentials.
- **Native multi-tenant fan-out** via `ApplicationSet`, generating one Argo CD `Application` per tenant from a single template.

### 7.2 Registering a Tenant's vSphere Namespace as an Argo CD Target

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

`tenants/acme/security-policy/` in Git contains plain `NetworkSecurityGroup` / `FirewallPolicy` / `VPCGatewayFirewallPolicy` / `TGWFirewallPolicy` YAML — the shapes from §4.3 and the worked example in §8 — reviewed via standard pull request workflow, ideally with a `CODEOWNERS` entry requiring the tenant's security lead to approve changes to their own policy.

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

## Appendix A. Glossary

| Term | Meaning |
|---|---|
| **VCF** | VMware Cloud Foundation — the private cloud platform this paper builds on |
| **VCFA** | VCF Automation — the self-service consumption layer of VCF, exposing CCI |
| **CCI** | Cloud Consumption Interface — VCFA's per-tenant Kubernetes API server |
| **vDefend** | Broadcom's security suite built into VCF (Distributed Firewall, Gateway Firewall, Transit Gateway Firewall) |
| **NSX** | The networking/security platform underlying vDefend's enforcement |
| **NSX Project** | NSX's representation of a VCF Organization/tenant |
| **VPC** | Virtual Private Cloud — the per-tenant network/security boundary inside VCF |
| **vSphere Namespace** | A VPC-backed namespace; the unit a tenant Project owns and self-services within |
| **DFW** | Distributed Firewall — east-west, intra-VPC enforcement at the vNIC |
| **TGW** | Transit Gateway — the shared routing construct connecting multiple VPCs |
| **Privileged (protected) label** | A VCFA label whose application and removal are RBAC-controlled, translated to an NSX tag; lets an Organization's admins key policy to a marker its application teams cannot reassign |
| **Micro-segmentation** | Fine-grained, per-workload network isolation, independent of subnet/VLAN |
| **GitOps** | Operating infrastructure by reconciling live state against a Git repository |
| **Argo CD** | The GitOps controller this paper uses for day-2 policy reconciliation |
| **ApplicationSet** | Argo CD's mechanism for generating one `Application` per tenant from a template |
| **sync-wave** | An Argo CD annotation controlling apply order across resources in a sync |
| **kubeconfig** | The credential/context bundle a tenant or pipeline uses to reach CCI |
| **RBAC** | Role-Based Access Control — how CCI scopes what a tenant or automation identity can reach |
| **VKS** | VMware vSphere Kubernetes Service — Kubernetes clusters running as VCF workloads |

---

## Appendix B. Additional Resources

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
