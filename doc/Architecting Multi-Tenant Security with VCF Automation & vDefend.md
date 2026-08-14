# Architecting Multi-Tenant Security with VCF Automation & vDefend
### API-Driven Self-Service Protection for Organizations and Applications

---

## 1. Executive Summary

Private cloud is being re-platformed around a simple expectation: application teams should be able to request infrastructure — and the security that protects it — the same way they consume any other cloud service. In VMware Cloud Foundation (VCF) 9.1, that expectation is met by pairing VCF Automation (VCFA), the platform's Kubernetes-native consumption layer, with **vDefend**, VCF's built-in network and workload security stack. Together they let a platform team define a small set of vetted security postures once, and let tenants attach, switch, and scope those postures to their own Projects, VPCs, namespaces, and applications — without filing a ticket to a network security team.

This paper is written for cloud and platform architects who already know their way around VCFA and vDefend and want a concrete design pattern for wiring the two together to embed zero-trust security directly into self-service cloud templates, Kubernetes manifests, and Infrastructure-as-Code pipelines. It is a blueprint for:

- **Declarative APIs:** Exposing vDefend security features available for VCFA tenants through the Cloud Consumption Interface (CCI) and standard Kubernetes Custom Resource Definitions (CRDs).
- **Layered Multi-Tenancy:** Layering VCFA constructs, like namespaces and applications with Virtual Private Cloud (VPC) and vDefend security posture, so that Providers can properly plan and impose the required infrastructure guardrails, while preserving the tenants' flexibility to define their individual applications' protection without interfering with the infra-wide security baseline.
- **Day-0 Security Baseline:** Enforcing security policies at resource creation time so that workloads are protected immediately upon deployment.
- **Automated Lifecycle Operations:** Delivering end-to-end policy management with Terraform alone — from Day-0 provisioning through Day-2 change — with GitOps-based continuous reconciliation available as an optional pattern for platform teams that want it.

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

- **Distributed Firewall (DFW):** Lateral Security (East-West) workload protection applied directly at the workload interface. Filters traffic within a VPC and namespaces or across VPCs without requiring traffic to route through a central bottleneck.
- **Transit Gateway Firewall:** North-South enforcement at the **Organization boundary** — the Transit Gateway is where a tenant's VPCs meet everything outside them, so this is the control point for what may enter or leave the tenant's domain as a whole.
- **VPC Gateway Firewall:** North-South enforcement at the **VPC perimeter edge**, filtering ingress and egress for a single VPC. Controls external exposure and ingress exceptions.

The two gateway firewalls are the same kind of control applied at different scopes: the Transit Gateway Firewall governs the tenant's outer boundary, the VPC Gateway Firewall governs one VPC's own edge inside it.

**Security Profiles**

Security Profiles package East-West strategy and VPC Gateway Firewall state into a single named configuration for a VPC. vDefend supplies a catalog of system-owned profiles ranging from fully open (default) to isolated VPC postures. Attaching a profile standardizes a VPC's perimeter security state into a single declarative object.

**Groups, Labels, and Services**

- **Groups:** Rule targets defined dynamically using label selectors, namespace membership, VM properties, CIDR blocks, or nested groups. Groups exist in two scopes: Region-scoped (referenced by DFW and Transit Gateway rules) and VPC-scoped (referenced by VPC Gateway rules).
- **Protected (Privileged) Labels:** Prefixed with protected/, these are specific workload labels that translate directly into NSX tags for group matching and security policy enforcement. They are restricted to authorized users only by a specific Role-Based Access Control (RBAC) permission. This RBAC barrier ensures application teams cannot remove mandatory compliance controls, bypass security policies, or self-assign elevated privileges on their workloads.
- **Services:** Named, reusable protocol and port definitions (TCP/UDP port sets, ICMP) and raw protocol support.

### 3.3 Who Can Change What: The RBAC Model

In VCFA, multi-tenancy is enforced directly by the Cloud Consumption Interface (CCI) API server control plane through native Kubernetes authorization primitives. This architectural design ensures that a tenant cannot exceed their allocated boundary, even when executing hand-crafted API calls, running unvetted automation scripts, or deploying misconfigured CI/CD pipelines.

Three integrated mechanisms establish and maintain strict isolation between tenant environments:

- **Project and Namespace Boundaries:** Every infrastructure resource provisioned by a tenant resides within a designated vSphere Namespace linked to a VCFA Project (project.cci.vmware.com). Because security policies, network micro-segmentation rules, and resource groups evaluate targets using localized names and key-value label selectors, the tenancy boundary maps directly to native Kubernetes namespace boundaries.
- **RBAC:** A tenant's authentication context, established via OIDC identity federation and managed through the VCF CLI, is bound strictly to ProjectRoleBinding custom resources (authorization.cci.vmware.com) within their project namespace. The CCI API server evaluates presented JWT tokens during the API admission phase and rejects any request targeting a namespace to which the token lacks explicit authorization bindings.
- **Resource Quotas and Namespace Classes:** Within their assigned namespace, tenants are subject to non-negotiable compute, memory, storage, and object limits established by provider administrators during Project setup. Defined via SupervisorNamespaceClassConfig specifications (spec.limits) and VCFA Resource Quota Policies, these resource ceilings are enforced at API admission, rendering unauthorized capacity expansion impossible from within the self-service layer.

**Roles and what each one owns.** VCFA RBAC and authorization bindings partition platform management across two provider-side and two tenant-side personas. This structural split is critical because the tenant tier enforces its own internal guardrail hierarchy, ensuring developers operate within boundaries established by both provider administrators and internal tenant security leads.

| Persona Tier | Role Name | Scope & Ownership | Guardrails & Restrictions |
|---|---|---|---|
| **Provider Tier** | **Cloud Admin (Provider) / Provider Security Admin** | Global infrastructure constructs: Organizations, Regions, Projects, resource quota policies, SupervisorNamespaceClass templates, and Region-Zone associations. Configures pre-tenant self-service guardrails. | Cannot provision tenant workloads directly, bypass multi-tenant namespace isolation boundaries, or enforce cross-tenant policy except through the Default Project. Provider-level security is authored in NSX. |
| **Tenant Tier** | **Organization Admin / Security Admin** | Tenant Projects, NSX Virtual Private Clouds (VPCs), vSphere Namespaces, Security Strategy selection (Security Profile selection), organization-wide default security strategies, Transit Gateway Security, DFW Environment and Application category policies. VPC Gateway Firewall toggles, protected resource labels, and Org-wide policies. | Cannot create security strategies outside the organization scope or modify profile-generated provider baselines. |
| **Tenant Tier** | **Application Owner / Developer** | Application workloads (VMs, VKS Kubernetes clusters, Data Services), standard workload labels, and Application-category groups/policies inside assigned namespaces. | Cannot assign or remove protected labels, bypass namespace boundaries, or override VPC-level security postures set above them. |

**Context Scoping for Human and Machine Identities**

Each persona receives a kubeconfig context scoped strictly to the specific namespaces permitted by their ProjectRoleBinding (authorization.cci.vmware.com). Consequently, the same token that authorizes a developer to deploy a workload also acts as the boundary constraining their visibility across the platform. Resources outside a persona's assigned scope are neither writable nor discoverable through API enumeration — a key requirement that allows platform providers to safely expose standard Kubernetes API endpoints directly to tenants.

This principle applies equally to machine and automation identities (§6, §8). Whether provisioning infrastructure via a Terraform CI runner using a Cloud Consumption Interface (CCI) token, or executing GitOps syncs through an Argo CD service account for teams layering on that optional pattern (§8), automation credentials must be scoped strictly to the specific tenant namespace(s) they manage. Granting a pipeline Project-wide or Region-wide administrative credentials — even for platform-owned CI/CD runners — introduces a major security anti-pattern: it quietly undermines the tenant isolation model by creating a backchannel for privilege escalation beyond human authorization boundaries.

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
| `vpc.nsx.vmware.com/v1alpha1` | **Security APIs**: `NetworkSecurityGroup`/`VPCNetworkSecurityGroup`, `NetworkService`, `SecurityProfile`/`SecurityProfileAttachment`, `FirewallPolicy`, `VPCGatewayFirewallPolicy`, `TGWFirewallPolicy`/`TGWSecurityConfig`|
| `vmoperator.vmware.com/v1alpha5` | VM lifecycle — the workloads the security policy protects |

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

Each subsection below walks through one concrete use case for consuming vDefend security through the VCFA Consumption API: what a tenant needs, the design pattern that solves it, and the API objects that implement it — confirmed against a live VCF 9.1 environment. §6 then shows how Terraform delivers each pattern, day-0 and day-2 alike (§8 covers an optional GitOps-based alternative for continuous reconciliation); this section stays at the level of the API itself.

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

To bypass the operational burden of manually tracking IP address allocations when provisioning workloads, the Supervisor incorporates an automated infrastructure metadata tagging mechanism. When virtual machines, container hosts, or network interfaces are provisioned within a vSphere Namespace, the Supervisor automatically attaches standardized key-value tags to the underlying network constructs. The Supervisor automatically applies the tag `nsx-op/vm_namespace`, set to the namespace's name, to every VPC subnet segment port created within that namespace.

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
  appliedTo:
    groupNames:
    - prod01-namespace
  category: Environment
  priority: 10001
  regionName: m01-reg01
  rules:
  - action: JumpToApplication
    direction: InOut
    from:
    - groupName: prod01-namespace
    ipProtocol: IPV4
    name: "rule-01"
    services:
    - networkServiceName: Any
    to:
    - groupName: prod01-namespace
  - action: Drop
    direction: InOut
    from:
    - groupName: Any
    ipProtocol: IPV4
    name: "rule-02"
    services:
    - networkServiceName: Any
    to:
    - groupName: Any
  stateful: true
  tcpStrict: true
```

**Note:** A primary operational complexity in Shared VPC topologies arises from handling non-deterministic IP services, such as Load Balancer Virtual Servers and Source Network Address Translation (SNAT) endpoints. By default, NSX assigns Load Balancer services and outbound SNAT IPs dynamically from the Project's shared External IP block. Because these ingress and egress IP addresses are allocated dynamically, dynamic segment port matching must be paired with explicit "IP Addresses Only" groups to account for Virtual IP (VIP) targets in cross-namespace firewall policies.

### 5.3 Application Ringfencing

In modern multi-tenant cloud security architecture, boundary enforcement operates across a strict hierarchy of abstraction tiers. While namespace isolation addresses macro-level perimeter boundaries, application ringfencing governs intra-boundary lateral communication, determining precisely which workload instances within a given namespace or across logical boundaries are permitted to interact. The underlying mechanism of application ringfencing pivots from structural, platform-assigned organization tags to explicit metadata labels attached directly to workload entities.

Through declarative abstraction mechanisms — such as VCFA service catalog items, Terraform modules, or GitOps overlay manifests — security boundaries follow workload deployment pipelines automatically without requiring administrative overhead. When a workload is provisioned or modified, the attachment of a metadata label triggers dynamic evaluation. The platform evaluates key-value pairs and automatically assigns the workload to pre-defined Groups and app-scoped vDefend Distributed Firewall Policies. The application-scoped firewall policy automatically expands or contracts as instances are scaled horizontally, ensuring continuous compliance across the workload lifecycle.

VCFA general tag management is unconstrained; an application team can inadvertently or deliberately modify a label. This capability creates potential vectors for security boundary evasion and accidental exposure of internal services.

Protected security labels establish strict Role-Based Access Control (RBAC) over label administrative lifecycles. In VCFA, protected labels can only be created, assigned, or modified by authorized administrative roles, specifically the Organization Admin or Organization Security Admin.

When protected labels are enforced, the application security becomes an immutable policy envelope. The application team operates within a security boundary defined and audited by the organization's security authority, rather than maintaining control over the boundary itself. Consequently, protected labels represent the imperative operational default whenever application security posture is deployed to fulfill regulatory requirements (such as PCI-DSS, HIPAA, or NIST SP 800-207 Zero Trust frameworks) or contractual security obligations for which the tenant security owner is ultimately accountable.

In deployments where an application maps strictly to a single namespace, application ringfencing acts as an internal refinement of namespace segmentation (§5.2). The namespace establishes the coarse macro-perimeter, while application ringfencing uses metadata labels to divide the application into discrete, microsegmented tiers (such as web, application, and database tiers). In this scenario, application segmentation and namespace segmentation operate in complete structural alignment.

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
  appliedTo:
    groupNames:
    - app01
  category: Application
  priority: 10002
  regionName: m01-reg01
  rules:
  - action: Allow
    direction: InOut
    from:
    - groupName: app01
    ipProtocol: IPV4
    name: "allow-app01-intra"
    services:
    - networkServiceName: Any
    to:
    - groupName: app01
  - action: Allow
    direction: In
    from:
    - groupName: Any
    ipProtocol: IPV4
    name: "allow-https-inbound"
    services:
    - networkServiceName: :HTTPS
    to:
    - groupName: app01
  - action: Allow
    direction: Out
    from:
    - groupName: app01
    ipProtocol: IPV4
    name: "allow-dns-outbound"
    services:
    - networkServiceName: :DNS
    - networkServiceName: :DNS-UDP
    to:
    - groupName: Any
  - action: Drop
    direction: InOut
    from:
    - groupName: Any
    ipProtocol: IPV4
    name: "app01-lockdown"
    services:
    - networkServiceName: Any
    to:
    - groupName: Any
  stateful: true
  tcpStrict: true
```

### 5.4 Zero-Trust Provisioning

This pattern (label → group → policy) bakes security directly into the deployment pipeline rather than bolting it on after launch. Pairing a `NetworkSecurityGroup` selecting `protected/env: dev` with a `FirewallPolicy` provisioned *before* any workload exists ensures the workload immediately joins its respective security group and inherits its firewall policy the moment it powers on. Because these groups and policies are pre-provisioned during environment onboarding, there is zero exposure window between creation and protection.

```yaml
apiVersion: vmoperator.vmware.com/v1alpha5
kind: VirtualMachine
metadata:
  name: dev01-vm01
  namespace: dev01-y3fp4
  labels:
    protected/env: dev
spec:
  className: best-effort-xsmall
  imageName: vmi-9a6ad929557aca964
  storageClass: ftt0-storage-policy
  powerState: PoweredOn
```
**VCFA Blueprint Template Specification**
The following template illustrates how a VM can be provisioned via VCFA blueprint inheriting security posture from day-0:

```yaml
resources:
  CCI_Supervisor_Namespace_1:
    type: CCI.Supervisor.Namespace
    properties:
      name: dev01-y3fp4
      existing: true
  Virtual_Machine_1:
    type: CCI.Supervisor.Resource
    properties:
      context: ${resource.CCI_Supervisor_Namespace_1.id}
      manifest:
        apiVersion: vmoperator.vmware.com/v1alpha5
        kind: VirtualMachine
        metadata:
          name: ${env.deploymentName + "-" + "-" + env.projectName}
          labels:
            protected/env: dev
        spec:
          className: best-effort-xsmall
          imageName: vmi-9a6ad929557aca964
          powerState: PoweredOn
          storageClass: ftt0-storage-policy
      wait:
        conditions:
          - type: VirtualMachineCreated
            status: 'True'
```

### 5.5 Transit Gateway (TGW) for Tenant Security

When a tenant architecture spans multiple VPCs attached to an Organization's Transit Gateway, consolidating north-south security controls at the transit layer offers enhanced operational flexibility. In VCFA 9.1, the vDefend TGW Firewall exposes declarative, fine-grained traffic filtering via the `TGWFirewallPolicy` and `TGWSecurityConfig` CRDs, within the `vpc.nsx.vmware.com/v1alpha1` API group. Because the Transit Gateway sits at the Organization boundary, VPC-specific policies and rules carve out exactly which paths are permitted for the Organization's inbound and outbound communication.

```yaml
apiVersion: vpc.nsx.vmware.com/v1alpha1
kind: TGWSecurityConfig
metadata:
  name: acme-shared-tgw-security-config
spec:
  features:
  - enabled: true
    name: GatewayFirewall
---
apiVersion: vpc.nsx.vmware.com/v1alpha1
kind: TGWFirewallPolicy
metadata:
  name: acme-shared-services-access
spec:
  category: LocalGatewayRules
  regionName: m01-reg01
  rules:
  - action: Allow
    appliedTo:
      gatewayNames:
      - acme-prod-tgw
    direction: In
    from:
    - groupName: shared-services-vpc-egress
    ipProtocol: IPV4
    name: "allow-shared-services"
    services:
    - networkServiceName: :DNS
    - networkServiceName: :DNS-UDP
    to:
    - groupName: shared-services
  - action: Drop
    direction: In
    from:
    - groupName: Any
    ipProtocol: IPV4
    name: "deny-other-vpcs"
    services:
    - networkServiceName: Any
    to:
    - groupName: Any
  stateful: true
  tcpStrict: true
```

---

## 6. Terraform Model for Tenant Security Lifecycle

Terraform fits naturally into modern cloud infrastructure architectures where tenant security configurations are provisioned as an integral component of automated environment stand-up pipelines. VCFA exposes a complementary multi-provider ecosystem designed to handle the structural separation between provider-level administration and tenant-level resource management. For security and network automation within VCF, two primary providers operate in tandem:
- **vcfa (vmware/vcfa):** Manages provider-admin-level operations across the system domain. This includes the creation and governance of Organizations, Identity Provider configurations, Regional Quotas, Organization Networking, and Regional Networking mappings. Critically, the vcfa provider exposes the vcfa_kubeconfig data source, which dynamically mints short-lived authentication credentials for the All-Apps Organization API surface (Supervisor CCI).
- **kubernetes (hashicorp/kubernetes):** Represents HashiCorp's standard Kubernetes provider, which applies declarative manifests (kubernetes_manifest) directly against the Supervisor CCI. In VCF 9, every tenant network and security construct is exposed as a Kubernetes CRD under the vpc.nsx.vmware.com/v1alpha1 API group, enabling native management of Projects, VPCs, Subnets, Security Profiles, and Firewall Policies via standard Kubernetes manifests.

**Scenario**: Tenant `acme`'s `dev01` vSphere Namespace lives in the `dev-vpc` VPC, which keeps the `vpc-isolation-with-essential-services` Security Profile attached as its perimeter baseline (§5.1) — blocking VPC ingress/egress except essential services like DNS. Within that VPC, `dev01` needs a namespace-wide default-deny baseline that permits only inbound HTTPS and intra-namespace traffic, and its `app01` application ringfenced further still, so intra-app traffic is allowed, inbound HTTPS is restricted to sources outside `dev01`, DNS egress is permitted, and everything else is dropped by default.

### 6.1 Provider Chain

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
The authentication workflow relies on dynamic credential chaining across provider boundaries. The root vcfa provider authenticates using a high-privilege refresh token or API token to establish administrative organization boundaries. Once the organization exists, the `vcfa_kubeconfig` data source queries VCFA to retrieve temporary API bearer tokens, cluster endpoint URLs, and TLS verification flags. These values are dynamically passed into the kubernetes provider block, enabling immediate, authenticated provisioning of `vpc.nsx.vmware.com/v1alpha1` CRDs without storing static credentials or cluster certificates in state files or repository secrets.

### 6.2 Declaring the VPC Security Baseline

```hcl
# security_baseline.tf
import {
  to = kubernetes_manifest.patch_profile_attachment
  id = "apiVersion=vpc.nsx.vmware.com/v1alpha1,kind=SecurityProfileAttachment,var.tenant_vpc_name"
}

resource "kubernetes_manifest" "patch_profile_attachment" {
  manifest = {
    apiVersion = "vpc.nsx.vmware.com/v1alpha1"
    kind       = "SecurityProfileAttachment"
    metadata = {
      name = var.tenant_vpc_name
    }
    spec = {
      regionName          = var.region_name
      securityProfileName = var.security_profile_name
      vpcName             = var.tenant_vpc_name
    }
  }

  field_manager {
    force_conflicts = true
  }
}
```
### 6.3 Segmenting vSphere Namespace

The following Terraform script creates a dev01_namespace_group Group defined with dynamic matching criteria. Instead of maintaining static member lists, it dynamically groups all workloads provisioned within the dev01 vSphere Namespace as they scale up or down. The resource then attaches a baseline FirewallPolicy to this group, enforcing the namespace's default security posture:

- Intra-Namespace (East-West): Allowed with Jump to Application catefory policies and rules.
- Egress (Outbound): Allowed
- Ingress (Inbound): Restricted strictly to HTTPS (all other inbound traffic is dropped)

```hcl
# namespace_segmentation.tf
resource "kubernetes_manifest" "dev01_namespace_group" {
  manifest = {
    apiVersion = "vpc.nsx.vmware.com/v1alpha1"
    kind       = "NetworkSecurityGroup"
    metadata = {
      name = "dev01-namespace"
    }
    spec = {
      regionName  = var.region_name
      vmSelectors = [{ labelSelector = { matchLabels = { "nsx-op/vm_namespace" = var.tenant_namespace } } }]
    }
  }
}

resource "kubernetes_manifest" "namespace_segmentation_dev01" {
  manifest = {
    apiVersion = "vpc.nsx.vmware.com/v1alpha1"
    kind       = "FirewallPolicy"
    metadata = {
      name = "namespace-segmentation-dev01"
    }
    spec = {
      appliedTo  = { groupNames = [kubernetes_manifest.dev01_namespace_group.manifest.metadata.name] }
      category   = "Environment"
      priority   = 10001
      regionName = var.region_name
      stateful   = true
      tcpStrict  = true
      rules = [
        {
          name      = "allow-intra-namespace"
          direction = "InOut"
          action    = "JumpToApplication"
          from      = [{ groupName = "dev01-namespace" }]
          to        = [{ groupName = "dev01-namespace" }]
          services  = [{ networkServiceName = "Any" }]
        },
        {
          name      = "allow-https-inbound"
          direction = "In"
          action    = "Allow"
          from      = [{ groupName = "Any" }]
          to        = [{ groupName = "Any" }]
          services  = [{ networkServiceName = ":HTTPS" }]
        },
        {
          name      = "block-any-inbound"
          direction = "In"
          action    = "Drop"
          from      = [{ groupName = "Any" }]
          to        = [{ groupName = "Any" }]
          services  = [{ networkServiceName = "Any" }]
        }
      ]
    }
  }

  depends_on = [kubernetes_manifest.dev01_namespace_group]
}
```

---

### 6.4 Ringfencing an Application

The following resource pair implements the `app01-ringfencing` `FirewallPolicy` from §5.3: an `app01` group built from the protected `protected/app01` label rather than a static IP list, and an Application-category policy that allows intra-app traffic, restricts inbound HTTPS to sources outside the `dev01-namespace` group created in §6.3, permits DNS egress, and drops everything else:

```hcl
# app_ringfencing.tf
resource "kubernetes_manifest" "app01_group" {
  manifest = {
    apiVersion = "vpc.nsx.vmware.com/v1alpha1"
    kind       = "NetworkSecurityGroup"
    metadata = {
      name = "app01"
    }
    spec = {
      regionName  = var.region_name
      systemOwned = false
      vmSelectors = [{
        labelSelector = {
          matchExpressions = [{ key = "protected/app01", operator = "Exists" }]
        }
        namespaceSelector = {
          matchLabels = { "kubernetes.io/metadata.name" = var.tenant_namespace }
        }
      }]
    }
  }
}

resource "kubernetes_manifest" "app01_ringfencing" {
  manifest = {
    apiVersion = "vpc.nsx.vmware.com/v1alpha1"
    kind       = "FirewallPolicy"
    metadata = {
      name = "app01-ringfencing"
    }
    spec = {
      appliedTo  = { groupNames = [kubernetes_manifest.app01_group.manifest.metadata.name] }
      category   = "Application"
      priority   = 10002
      regionName = var.region_name
      stateful   = true
      tcpStrict  = true
      rules = [
        {
          name      = "allow-app01-intra"
          direction = "InOut"
          action    = "Allow"
          from      = [{ groupName = "app01" }]
          to        = [{ groupName = "app01" }]
          services  = [{ networkServiceName = "Any" }]
        },
        {
          name            = "allow-https-inbound"
          direction       = "In"
          action          = "Allow"
          from            = [{ groupName = kubernetes_manifest.dev01_namespace_group.manifest.metadata.name }]
          sourcesExcluded = true
          to              = [{ groupName = "app01" }]
          services        = [{ networkServiceName = ":HTTPS" }]
        },
        {
          name      = "allow-dns-outbound"
          direction = "Out"
          action    = "Allow"
          from      = [{ groupName = "app01" }]
          to        = [{ groupName = "Any" }]
          services  = [{ networkServiceName = ":DNS" }, { networkServiceName = ":DNS-UDP" }]
        },
        {
          name      = "app01-lockdown"
          direction = "InOut"
          action    = "Drop"
          from      = [{ groupName = "Any" }]
          to        = [{ groupName = "Any" }]
          services  = [{ networkServiceName = "Any" }]
        }
      ]
    }
  }

  depends_on = [kubernetes_manifest.app01_group, kubernetes_manifest.dev01_namespace_group]
}
```

`sourcesExcluded = true` negates the `from` match on `allow-https-inbound`, so the rule reads as "allow HTTPS from anywhere *except* the `dev01-namespace` group" — keeping inbound HTTPS open to external and other-namespace clients while denying it from dev workloads specifically. Rule order matters here: NSX evaluates a `FirewallPolicy`'s `rules` list top to bottom, so `app01-lockdown`'s match-all `Drop` has to stay last, or it would shadow every rule below it.

Nothing here is handed off to a second tool or a separate Git path — the namespace baseline from §6.3, the `app01` group, and its ringfencing rules all live in the same tenant module and state from §6.2, applied atomically.

### 6.5 Day-2, Tenant-Driven Change

Acme's app team needs to expose a metrics endpoint to Acme's monitoring VPC. `monitoring01` lives in its own namespace, not `dev01-namespace`, so this traffic doesn't qualify for the `allow-intra-namespace` `JumpToApplication` rule in the Environment-category policy from §6.3 — left alone, it would instead fall through to that same policy's `block-any-inbound` Drop rule. The day-2 PR against the *same Terraform config repo* adds a new `monitoring01` group for the scraper source and a rule inserted directly into `namespace_segmentation_dev01`'s `rules` list — ahead of `block-any-inbound` — that `Allow`s the specific monitoring-to-`app01` path outright, without needing a matching rule in `app01_ringfencing`'s Application-category policy at all:

```hcl
resource "kubernetes_manifest" "monitoring01_group" {
  manifest = {
    apiVersion = "vpc.nsx.vmware.com/v1alpha1"
    kind       = "NetworkSecurityGroup"
    metadata = {
      name = "monitoring01"
    }
    spec = {
      regionName  = var.region_name
      vmSelectors = [{ labelSelector = { matchLabels = { "nsx-op/vm_namespace" = var.monitoring_namespace } } }]
    }
  }
}

# inserted into kubernetes_manifest.namespace_segmentation_dev01.manifest.spec.rules,
# ahead of the "block-any-inbound" rule:
#   {
#     name      = "allow-monitoring-to-app01"
#     direction = "In"
#     action    = "Allow"
#     from      = [{ groupName = kubernetes_manifest.monitoring01_group.manifest.metadata.name }]
#     to        = [{ groupName = kubernetes_manifest.app01_group.manifest.metadata.name }]
#     services  = [{ l4PortSet = { l4Protocol = "TCP", destinationPorts = ["9090"] } }]
#   }
```

Once merged and approved by the `CODEOWNERS`-designated security lead, CI runs the same `terraform plan`/`apply` pipeline from §6.1 — no separate GitOps controller, no platform-team ticket, and `block-any-inbound` still governs anything not explicitly matched. From empty namespace to a fully ringfenced application exposing only the traffic it explicitly allows, the whole path took the time it took to merge a pull request and let CI apply it — not the days or weeks a ticket-driven model would have taken. (§8 discusses the equivalent GitOps-based day-2 model for teams that have adopted that optional pattern.)

---

## 8. Conclusion

Multi-tenant security in VCF 9.1 works when it is designed as a set of composable, API-addressable layers — VPC-level Security Profiles, namespace isolation, application ringfencing, and Transit Gateway policy — each with a clear owner and a clear delegation boundary (§3, §5). Because every layer is a Kubernetes-native custom resource under the VCFA Consumption API (§4), the same design pattern is automatable on day one with a single tool a platform team already runs: Terraform, end-to-end, for both the atomic, reviewed day-0 baseline and every day-2 policy change that follows it (§6). §5 and §6 show that model holding up against real, live-environment scenarios — not just a diagram.

Terraform's periodic `apply` is this paper's default, but it isn't the only valid operating model — because every security object in §6 is just a Kubernetes-native CRD under `vpc.nsx.vmware.com/v1alpha1`, the same objects are equally addressable by a GitOps controller like Argo CD, layered on top rather than replacing it. Each tenant's CCI-scoped kubeconfig registers as an Argo CD cluster target, RBAC-limited to that tenant's namespace and never cluster-admin on the shared Supervisor; an `ApplicationSet` fans a single template out into one `Application` per tenant; and `sync-wave` ordering keeps Groups landing before the policies that reference them, and default-deny baselines landing before the allow rules layered on top of them. The tradeoff for teams that adopt it is continuous drift correction and self-service via a Git merge instead of a pipeline run, at the cost of a second control plane and its own RBAC surface to secure — worthwhile for a platform team reconciling many tenants continuously, unnecessary overhead for one applying periodic, reviewed changes.

**The final thought worth remembering:** by moving enforcement into the hypervisor and consuming it through the same Terraform surface as every other piece of infrastructure, security stops being a checkpoint someone has to clear and becomes an ambient property of the platform itself. VCF with vDefend doesn't just secure applications — it lets security be measured the way the rest of the business measures itself: faster time-to-market, lower operational cost, and continuous, demonstrable compliance.

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
| **Argo CD** | The GitOps controller §8 discusses as an optional, continuous day-2 policy reconciliation pattern |
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
- VMware / Broadcom — [Terraform Provider for VMware Cloud Foundation Automation (`vcfa`)](https://github.com/vmware/terraform-provider-vcfa)
- Argo CD Documentation — [ApplicationSet Controller](https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/)
