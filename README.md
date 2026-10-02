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

A minimal Terraform module implementing §6 of the paper end-to-end against a real CCI endpoint: provider chain, Day-0 VPC security baseline, vSphere Namespace segmentation, application ringfencing, and Transit Gateway firewalling — each as its own module.

| File | Implements | What it does |
|---|---|---|
| `providers.tf` | §6.1 | `vcfa` + `kubernetes` provider chain — mints a short-lived CCI kubeconfig via `vcfa_kubeconfig` and hands it to the `kubernetes` provider |
| `main.tf` | — | Root module: calls the four modules below and holds the `SecurityProfileAttachment` `import` block (import blocks are root-only) |
| `modules/security_baseline/` | §6.2 | Patches the tenant VPC's existing `SecurityProfileAttachment` |
| `modules/namespace_segmentation/` | §6.3 | Dynamically groups a vSphere Namespace's workloads and applies a default-deny, HTTPS-only `FirewallPolicy` |
| `modules/app_ringfencing/` | §6.4 | Ringfences a protected-label application into its own `FirewallPolicy` |
| `modules/tgw_firewall/` | §5.5 | One `TGWFirewallPolicy` per external connection of a single Transit Gateway (`tgw_name`). Reads the live `TGWAttachment` objects to resolve each connection, then scopes each rule via `appliedTo.gatewayAttachmentNames` |
| `moved.tf` | — | Moves state from the earlier flat layout to the module addresses |
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

#### Deploying one module at a time

Each security pattern is its own module, so you can roll them out one at a time with `-target`:

```bash
terraform plan  -target=module.security_baseline       # §6.2 — import + patch the VPC's SecurityProfileAttachment
terraform apply -target=module.security_baseline

terraform apply -target=module.namespace_segmentation  # §6.3 — namespace group + segmentation FirewallPolicy
terraform apply -target=module.app_ringfencing         # §6.4 — app01 group + ringfencing FirewallPolicy
terraform apply -target=module.tgw_firewall            # §5.5 — one TGWFirewallPolicy per external connection
```

To target several modules in one run, repeat the flag:

```bash
terraform apply -target=module.namespace_segmentation -target=module.app_ringfencing
```

To narrow a run to a single resource, including one instance of a `for_each` resource such as one external connection, use its full address. Quote it so the shell doesn't interpret the brackets:

```bash
terraform apply -target='module.tgw_firewall.kubernetes_manifest.tgw_connection_policy["corp-wan"]'
```

Notes:

- **Dependencies are pulled in automatically.** `app_ringfencing` takes the namespace group's name from `namespace_segmentation`, so `-target=module.app_ringfencing` also creates the `dev01-namespace` group. It does not create that module's `FirewallPolicy`.
- **All root variables are still required.** Even a targeted run needs a complete `terraform.tfvars`, including `tgw_name` and `tgw_external_connections`.
- **`-target` is for staged rollout and troubleshooting.** Once every module is in place, run a plain `terraform plan` / `terraform apply` so the whole configuration is checked for drift. Terraform prints a warning on every targeted run as a reminder.
- **Be careful with destroy.** `terraform destroy -target=module.tgw_firewall` (or another module) removes only that module's objects. Don't destroy `module.security_baseline`, though: its `SecurityProfileAttachment` is a pre-existing object that Terraform imported and patched, not one it created. To stop managing it without deleting it, run `terraform state rm module.security_baseline` instead.

## Status

The paper's schema and examples are confirmed against a live VCF 9.1 environment (§4.4), and `terraform-example/` is kept in sync with §6 as the primary reference — if the two ever disagree, that's a bug.
