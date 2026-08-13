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

This principle applies equally to machine and automation identities (§6, Appendix A). Whether provisioning infrastructure via a Terraform CI runner using a Cloud Consumption Interface (CCI) token, or executing GitOps syncs through an Argo CD service account for teams layering on Appendix A's optional pattern, automation credentials must be scoped strictly to the specific tenant namespace(s) they manage. Granting a pipeline Project-wide or Region-wide administrative credentials — even for platform-owned CI/CD runners — introduces a major security anti-pattern: it quietly undermines the tenant isolation model by creating a backchannel for privilege escalation beyond human authorization boundaries.

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

Each subsection below walks through one concrete use case for consuming vDefend security through the VCFA Consumption API: what a tenant needs, the design pattern that solves it, and the API objects that implement it — confirmed against a live VCF 9.1 environment. §6 then shows how Terraform delivers each pattern, day-0 and day-2 alike (Appendix A covers an optional GitOps-based alternative for continuous reconciliation); this section stays at the level of the API itself.

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
  regionName: region-a
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

### 6.2 Declaring the Security Baseline

```hcl
# security_baseline.tf
resource "kubernetes_manifest" "prod01_namespace_group" {
  manifest = {
    apiVersion = "vpc.nsx.vmware.com/v1alpha1"
    kind       = "NetworkSecurityGroup"
    metadata = {
      name = "prod01-namespace"
    }
    spec = {
      regionName  = "m01-reg01"
      vmSelectors = [{ labelSelector = { matchLabels = { "nsx-op/vm_namespace" = "prod01-8sg7f" } } }]
    }
  }
}

resource "kubernetes_manifest" "namespace_isolation_prod01" {
  manifest = {
    apiVersion = "vpc.nsx.vmware.com/v1alpha1"
    kind       = "FirewallPolicy"
    metadata = {
      name = "namespace-isolation-prod01"
    }
    spec = {
      appliedTo  = { groupNames = [kubernetes_manifest.prod01_namespace_group.manifest.metadata.name] }
      category   = "Environment"
      priority   = 10001
      regionName = "m01-reg01"
      stateful   = true
      tcpStrict  = true
      rules = [
        {
          name      = "allow-intra-namespace"
          direction = "InOut"
          action    = "JumpToApplication"
          from      = [{ groupName = "prod01-namespace" }]
          to        = [{ groupName = "prod01-namespace" }]
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

  depends_on = [kubernetes_manifest.prod01_namespace_group]
}
```

This is the Terraform-managed form of the `NetworkSecurityGroup`/`FirewallPolicy` pair from §5.2. `namespace_isolation_prod01`'s `appliedTo` references the group's own resource attribute (`kubernetes_manifest.prod01_namespace_group.manifest.metadata.name`) instead of retyping its name as a string, which is what avoids the exact "dependent objects... does not exist" failure a mismatched `groupNames` reference produces. Its rules' `from`/`to` fields still reference the group by the literal string `"prod01-namespace"`, though — since Terraform can only infer creation order from an actual attribute reference, the explicit `depends_on` is what guarantees the group exists before the policy that references it by name is submitted. Treat resource and attribute names as subject to the provider's current schema.

---

## 7. A Worked End-to-End Example

**Scenario**: Tenant `acme` needs a `web` / `app` / `db` three-tier application with default-deny micro-segmentation and a locked-down perimeter, permitting only public HTTPS to the web tier, `web → app:8443`, and `app → db:5432`.

### 7.1 Terraform Onboarding

The onboarding pipeline (extending §6.2) creates the Project, VPC, Subnet, baseline `SecurityProfile`/`SecurityProfileAttachment`, and the complete tier-based security posture — tier groups, a locked-down perimeter, tier-isolation rules, and a default-deny baseline — as one module, one state, one `apply`:

```hcl
resource "kubernetes_manifest" "acme_namespace_group" {
  manifest = {
    apiVersion = "vpc.nsx.vmware.com/v1alpha1"
    kind       = "NetworkSecurityGroup"
    metadata = {
      name = "acme-namespace"
    }
    spec = {
      regionName  = var.region_name
      vmSelectors = [{ labelSelector = { matchLabels = { "nsx-op/vm_namespace" = "acme-prod-ns01" } } }]
    }
  }
}

resource "kubernetes_manifest" "default_deny_east_west" {
  manifest = {
    apiVersion = "vpc.nsx.vmware.com/v1alpha1"
    kind       = "FirewallPolicy"
    metadata = {
      name      = "acme-default-deny"
    }
    spec = {
      regionName = var.region_name
      category   = "Application"
      stateful   = true
      appliedTo  = { groupNames = ["acme-namespace"] }
      rules = [
        {
          name      = "deny-all-in"
          direction = "In"
          action    = "Drop"
          from      = [{ groupName = "Any" }]
          to        = [{ groupName = "Any" }]
          services  = [{ networkServiceName = "Any" }]
        },
        {
          name      = "deny-all-out"
          direction = "Out"
          action    = "Drop"
          from      = [{ groupName = "Any" }]
          to        = [{ groupName = "Any" }]
          services  = [{ networkServiceName = "Any" }]
        }
      ]
    }
  }
}

resource "kubernetes_manifest" "acme_web_tier" {
  manifest = {
    apiVersion = "vpc.nsx.vmware.com/v1alpha1"
    kind       = "NetworkSecurityGroup"
    metadata = {
      name      = "acme-web-tier"
    }
    spec = {
      regionName  = var.region_name
      vmSelectors = [{ labelSelector = { matchLabels = { tier = "web" } } }]
    }
  }
}

resource "kubernetes_manifest" "acme_app_tier" {
  manifest = {
    apiVersion = "vpc.nsx.vmware.com/v1alpha1"
    kind       = "NetworkSecurityGroup"
    metadata = {
      name      = "acme-app-tier"
    }
    spec = {
      regionName  = var.region_name
      vmSelectors = [{ labelSelector = { matchLabels = { tier = "app" } } }]
    }
  }
}

resource "kubernetes_manifest" "acme_db_tier" {
  manifest = {
    apiVersion = "vpc.nsx.vmware.com/v1alpha1"
    kind       = "NetworkSecurityGroup"
    metadata = {
      name      = "acme-db-tier"
    }
    spec = {
      regionName  = var.region_name
      vmSelectors = [{ labelSelector = { matchLabels = { tier = "db" } } }]
    }
  }
}

resource "kubernetes_manifest" "acme_web_tier_vpc" {
  manifest = {
    apiVersion = "vpc.nsx.vmware.com/v1alpha1"
    kind       = "VPCNetworkSecurityGroup"
    metadata = {
      name      = "acme-web-tier-vpc"
    }
    spec = {
      vpcName     = "acme-prod-vpc01"
      vmSelectors = [{ labelSelector = { matchLabels = { tier = "web" } } }]
    }
  }
}
```

`acme_web_tier_vpc` mirrors `acme_web_tier` as a separate `VPCNetworkSecurityGroup` — `VPCGatewayFirewallPolicy` rules can't reference the region-scoped `NetworkSecurityGroup` kind (§3.2).

```hcl
resource "kubernetes_manifest" "acme_perimeter" {
  manifest = {
    apiVersion = "vpc.nsx.vmware.com/v1alpha1"
    kind       = "VPCGatewayFirewallPolicy"
    metadata = {
      name      = "acme-perimeter"
    }
    spec = {
      regionName = var.region_name
      vpcName    = "acme-prod-vpc01"
      category   = "LocalGatewayRules"
      rules = [
        {
          name      = "allow-inbound-https"
          direction = "In"
          action    = "Allow"
          from      = [{ groupName = "Any" }]
          to        = [{ groupName = "acme-web-tier-vpc" }]
          services  = [{ l4PortSet = { l4Protocol = "TCP", destinationPorts = ["443"] } }]
        },
        {
          name      = "deny-all-other-inbound"
          direction = "In"
          action    = "Drop"
          from      = [{ groupName = "Any" }]
          to        = [{ groupName = "Any" }]
          services  = [{ networkServiceName = "Any" }]
        }
      ]
    }
  }
}

resource "kubernetes_manifest" "app_tier_group" {
  manifest = {
    apiVersion = "vpc.nsx.vmware.com/v1alpha1"
    kind       = "NetworkSecurityGroup"
    metadata = {
      name      = "${var.tenant_name}-app-tier"
    }
    spec = {
      regionName  = var.region_name
      vmSelectors = [{ labelSelector = { matchLabels = { tier = "app" } } }]
    }
  }
}

resource "kubernetes_manifest" "acme_tier_isolation" {
  manifest = {
    apiVersion = "vpc.nsx.vmware.com/v1alpha1"
    kind       = "FirewallPolicy"
    metadata = {
      name      = "acme-tier-isolation"
    }
    spec = {
      regionName = var.region_name
      category   = "Application"
      appliedTo = { groupNames = [kubernetes_manifest.app_tier_group.manifest.metadata.name] }
      rules = [
        {
          name      = "allow-web-to-app"
          direction = "In"
          action    = "Allow"
          from      = [{ groupName = "acme-web-tier" }]
          to        = [{ groupName = "acme-app-tier" }]
          services  = [{ l4PortSet = { l4Protocol = "TCP", destinationPorts = ["8443"] } }]
        },
        {
          name      = "allow-app-to-db"
          direction = "In"
          action    = "Allow"
          from      = [{ groupName = "acme-app-tier" }]
          to        = [{ groupName = "acme-db-tier" }]
          services  = [{ l4PortSet = { l4Protocol = "TCP", destinationPorts = ["5432"] } }]
        }
      ]
    }
  }
}
```

Nothing here is handed off to a second tool or a separate Git path — the default-deny baseline, the tier groups, the perimeter, and the tier-isolation rules all live in the same tenant module and state from §6.2, applied atomically.

### 7.2 Day-2, Tenant-Driven Change

Acme's app team adds a `cache` tier. Their security engineer opens a PR against the *same Terraform config repo*, adding a new `kubernetes_manifest.acme_cache_tier` resource and a new rule block appended to `acme_tier_isolation`'s `rules` list:

```hcl
resource "kubernetes_manifest" "acme_cache_tier" {
  manifest = {
    apiVersion = "vpc.nsx.vmware.com/v1alpha1"
    kind       = "NetworkSecurityGroup"
    metadata = {
      name      = "acme-cache-tier"
    }
    spec = {
      regionName  = var.region_name
      vmSelectors = [{ labelSelector = { matchLabels = { tier = "cache" } } }]
    }
  }
}

# appended to kubernetes_manifest.acme_tier_isolation.manifest.spec.rules:
#   {
#     name      = "allow-app-to-cache"
#     direction = "In"
#     action    = "Allow"
#     from      = [{ groupName = "acme-app-tier" }]
#     to        = [{ groupName = "acme-cache-tier" }]
#     services  = [{ l4PortSet = { l4Protocol = "TCP", destinationPorts = ["6379"] } }]
#   }
```

Once merged and approved by the `CODEOWNERS`-designated security lead, CI runs the same `terraform plan`/`apply` pipeline from §6.1 — no separate GitOps controller, no platform-team ticket, and the default-deny `FirewallPolicy` and locked-down `VPCGatewayFirewallPolicy` still govern anything not explicitly matched. From empty namespace to a fully isolated, micro-segmented, internet-facing-only-where-intended application, the whole path took the time it took to merge a pull request and let CI apply it — not the days or weeks a ticket-driven model would have taken. (Appendix A shows this same change delivered as a GitOps-synced PR instead, for teams that have adopted that optional pattern.)

### 7.3 Multi-VPC Extension

If Acme later splits into a `prod` VPC and a `shared-services` VPC on a common Transit Gateway, a `TGWFirewallPolicy` (§5.5) is added to allow only the specific east-west paths needed between them, rather than relying on the coarser connectivity posture alone — just another `kubernetes_manifest` resource in the same Terraform module and state as everything else in this section.

---

## 8. Conclusion

Multi-tenant security in VCF 9.1 works when it is designed as a set of composable, API-addressable layers — VPC-level Security Profiles, namespace isolation, application ringfencing, and Transit Gateway policy — each with a clear owner and a clear delegation boundary (§3, §5). Because every layer is a Kubernetes-native custom resource under the VCFA Consumption API (§4), the same design pattern is automatable on day one with a single tool a platform team already runs: Terraform, end-to-end, for both the atomic, reviewed day-0 baseline and every day-2 policy change that follows it (§6) — with GitOps-based continuous reconciliation available as an optional layer for teams that want it (Appendix A). §5 and §7 show that model holding up against real, live-environment scenarios — not just a diagram.

**The final thought worth remembering:** by moving enforcement into the hypervisor and consuming it through the same Terraform surface as every other piece of infrastructure, security stops being a checkpoint someone has to clear and becomes an ambient property of the platform itself. VCF with vDefend doesn't just secure applications — it lets security be measured the way the rest of the business measures itself: faster time-to-market, lower operational cost, and continuous, demonstrable compliance.

---

## Appendix A. Continuous Day-2 Operations with Argo CD (GitOps)

§6 and §7 show this paper's default model: Terraform, end-to-end, for both the day-0 baseline and every day-2 change. Some platform teams want more than periodic `apply` — an always-on reconciliation loop with continuous drift correction, self-service via a Git merge instead of a pipeline run, and native per-tenant fan-out. This appendix shows how to layer Argo CD GitOps reconciliation on top of the same CCI-exposed objects, as an optional pattern rather than this paper's default.

### A.1 Why GitOps for Continuous Security Policy

Security policy is not "set once at provisioning" — it changes continuously as tenant applications evolve (new microservice, new port, decommissioned tier). Treating it as a one-time Terraform apply leaves a gap for exactly the kind of manual, undocumented change that turns into an audit finding. Argo CD's continuous reconciliation loop closes that gap:

- **Drift correction.** If someone manually edits a `FirewallPolicy` or `NetworkSecurityGroup` via `kubectl` or the CCI UI, Argo CD reverts it (or flags `OutOfSync`) on the next sync — Git remains the enforceable source of truth for security posture.
- **Self-service without a pipeline run.** Tenant security engineers merge a PR against their tenant's policy repo; Argo CD picks it up within its poll/webhook interval — no separate CI job needs to hold cloud credentials.
- **Native multi-tenant fan-out** via `ApplicationSet`, generating one Argo CD `Application` per tenant from a single template.

### A.2 Registering a Tenant's vSphere Namespace as an Argo CD Target

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

### A.3 Per-Tenant Application via ApplicationSet

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

`tenants/acme/security-policy/` in Git contains plain `NetworkSecurityGroup` / `FirewallPolicy` / `VPCGatewayFirewallPolicy` / `TGWFirewallPolicy` YAML — the shapes from §4.3 and the worked example in §7 — reviewed via standard pull request workflow, ideally with a `CODEOWNERS` entry requiring the tenant's security lead to approve changes to their own policy.

### A.4 Ordering and Safety

- Use `argocd.argoproj.io/sync-wave` annotations to guarantee `NetworkSecurityGroup` objects (wave 0) and the default-deny `FirewallPolicy`/`VPCGatewayFirewallPolicy` (wave 1) land before more permissive tier-specific allow rules (wave 2+) — groups must exist before a policy can reference them, and a default-deny baseline should never trail its allow rules into the cluster.
- Run Argo CD in **non-selfHeal, manual-sync mode for a probation period** on newly onboarded tenants, flipping to `automated.selfHeal: true` once the baseline policy has been validated in a lower environment — this gives a soft rollout path for a capability that can otherwise instantly enforce a mistake fleet-wide.

### A.5 Applying Argo CD to Each Design Pattern

Restating, per §5 pattern, exactly what Argo CD reconciles at day-2, as an alternative to this paper's Terraform-owned default (§6, §7):

- **VPC Segmentation (§5.1):** a strategy change — e.g. moving a `dev` VPC from `none` to `vpc-isolation` — is a one-line diff to `SecurityProfileAttachment.spec.securityProfileName` in the tenant's Git path, synced automatically.
- **Namespace Segmentation (§5.2):** any `Application`-category rule opening a specific port between namespaces is added as a normal PR against the tenant's policy repo; the `Environment`-category isolation policy still governs anything not explicitly matched.
- **Application Ringfencing (§5.3):** because a new application being ringfenced is exactly the kind of change that happens continuously as a tenant's portfolio grows, this is squarely a GitOps-friendly change — a PR adding the app's group and policy to the tenant's Git path, reviewed by `CODEOWNERS`, synced automatically.
- **Transit Gateway (§5.5):** tenant-specific `TGWFirewallPolicy` rules are layered in the same way as any other tenant policy change, reviewed and synced from the tenant's Git path.

Day-0 Provisioned Security (§5.4) is fully owned by Terraform at onboarding regardless of which day-2 model a team chooses — see §6.2.

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
| **vSphere Namespace** | A VPC-backed namespace; the unit a tenant Project owns and self-services within |
| **DFW** | Distributed Firewall — east-west, intra-VPC enforcement at the vNIC |
| **TGW** | Transit Gateway — the shared routing construct connecting multiple VPCs |
| **Privileged (protected) label** | A VCFA label whose application and removal are RBAC-controlled, translated to an NSX tag; lets an Organization's admins key policy to a marker its application teams cannot reassign |
| **Micro-segmentation** | Fine-grained, per-workload network isolation, independent of subnet/VLAN |
| **GitOps** | Operating infrastructure by reconciling live state against a Git repository |
| **Argo CD** | The GitOps controller Appendix A uses for its optional, continuous day-2 policy reconciliation pattern |
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
- HashiCorp / VMware — [Terraform Provider for VMware Aria Automation / VCF Automation (`vra`)](https://github.com/vmware/terraform-provider-vra)
- Argo CD Documentation — [ApplicationSet Controller](https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/)
