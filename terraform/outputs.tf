output "instance_public_ip" {
  description = "Public IP address of the LibreChat compute instance"
  value       = oci_core_instance.librechat.public_ip
}

output "instance_ocid" {
  description = "OCID of the compute instance"
  value       = oci_core_instance.librechat.id
}

output "librechat_url" {
  description = "Default plain-HTTP URL. Use your own domain + HTTPS for anything beyond testing (see OCI_DEPLOYMENT_GUIDE.md)."
  value       = "http://${oci_core_instance.librechat.public_ip}"
}
