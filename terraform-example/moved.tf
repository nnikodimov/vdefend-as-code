# moved.tf
# Carries state from the pre-module flat layout to the module addresses.
# Safe to delete once every workspace has applied past this change.

moved {
  from = kubernetes_manifest.patch_profile_attachment
  to   = module.security_baseline.kubernetes_manifest.patch_profile_attachment
}

moved {
  from = kubernetes_manifest.dev01_namespace_group
  to   = module.namespace_segmentation.kubernetes_manifest.dev01_namespace_group
}

moved {
  from = kubernetes_manifest.namespace_segmentation_dev01
  to   = module.namespace_segmentation.kubernetes_manifest.namespace_segmentation_dev01
}

moved {
  from = kubernetes_manifest.app01_group
  to   = module.app_ringfencing.kubernetes_manifest.app01_group
}

moved {
  from = kubernetes_manifest.app01_ringfencing
  to   = module.app_ringfencing.kubernetes_manifest.app01_ringfencing
}
