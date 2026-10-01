output "app_group_name" {
  description = "Name of the NetworkSecurityGroup selecting the application's workloads"
  value       = kubernetes_manifest.app01_group.manifest.metadata.name
}
