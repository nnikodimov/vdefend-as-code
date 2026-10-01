output "namespace_group_name" {
  description = "Name of the NetworkSecurityGroup selecting the namespace's workloads"
  value       = kubernetes_manifest.dev01_namespace_group.manifest.metadata.name
}
