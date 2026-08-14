# vDefend as Code via VCFA CCI

Patterns and a working Terraform example for managing VMware Cloud Foundation (VCF) 9.1's **vDefend** security constructs — Distributed Firewall, Gateway Firewall, Security Profiles, Groups, Transit Gateway policy — as declarative, self-service Infrastructure-as-Code through VCF Automation's Cloud Consumption Interface (CCI).

## What's here

### 📄 [`doc/`](doc/) — the paper

**[Architecting Multi-Tenant Security with VCF Automation & vDefend](doc/Architecting%20Multi-Tenant%20Security%20with%20VCF%20Automation%20%26%20vDefend.md)**

A blueprint for platform and security architects who already know VCFA and vDefend, and want a concrete design for wiring the two together — so tenant security is delivered through the same self-service, API-first, Infrastructure-as-Code surface as compute, network, and storage, instead of sitting in front of it as a manual gate.

Covers:
- How vDefend's constructs (`FirewallPolicy`, `NetworkSecurityGroup`, `SecurityProfile`, `TGWFirewallPolicy`, etc.) are exposed as Kubernetes CRDs under CCI, and who — provider admin vs. tenant — can change what
- Five worked design patterns: VPC-level Security Profiles, vSphere Namespace segmentation, application ringfencing, Day-0 zero-trust provisioning, and Transit Gateway security
- A Terraform model for both Day-0 baseline provisioning and Day-2 tenant-driven change, confirmed against a live VCF 9.1 environment — mirrored in [`terraform-example/`](terraform-example/)
- An optional Argo CD/GitOps operating model for teams that want continuous reconciliation instead of periodic `apply`

### 🧱 [`terraform-example/`](terraform-example/) — the working example

A minimal Terraform module implementing §6 of the paper end-to-end against a real CCI endpoint: provider chain, Day-0 VPC security baseline, vSphere Namespace segmentation, and application ringfencing.

| File | Implements | What it does |
|---|---|---|
| `providers.tf` | §6.1 | `vcfa` + `kubernetes` provider chain — mints a short-lived CCI kubeconfig via `vcfa_kubeconfig` and hands it to the `kubernetes` provider |
| `security_baseline.tf` | §6.2 | Imports and patches the tenant VPC's existing `SecurityProfileAttachment` |
| `namespace_segmentation.tf` | §6.3 | Dynamically groups a vSphere Namespace's workloads and applies a default-deny, HTTPS-only `FirewallPolicy` |
| `app_ringfencing.tf` | §6.4 | Ringfences a protected-label application into its own `FirewallPolicy` |
| `variables.tf` / `terraform.tfvars.example` | — | Input variables and an example `tfvars` file |

#### Usage

```bash
cd terraform-example
cp terraform.tfvars.example terraform.tfvars   # fill in your VCFA URL, token, org, etc.
terraform init
terraform plan
terraform apply
```

Requires a running VCF 9.1 environment with CCI enabled and a valid VCFA API/refresh token.

## Status

The paper's schema and examples are confirmed against a live VCF 9.1 environment (§4.4), and `terraform-example/` is kept in sync with §6 as the primary reference — if the two ever disagree, that's a bug.
