variable "oci_tenancy_ocid" {
  type        = string
  description = "OCI tenancy OCID"
  sensitive   = true
}

variable "oci_user_ocid" {
  type        = string
  description = "OCID of the OCI user Terraform authenticates as"
  sensitive   = true
}

variable "oci_fingerprint" {
  type        = string
  description = "Fingerprint of the OCI API signing key"
  sensitive   = true
}

variable "oci_private_key" {
  type        = string
  description = "PEM contents of the OCI API signing private key"
  sensitive   = true
}

variable "oci_region" {
  type        = string
  description = "OCI region identifier, e.g. ap-tokyo-1"
}

variable "oci_compartment_ocid" {
  type        = string
  description = "Compartment OCID to create resources in (root compartment = tenancy OCID)"
}

variable "ssh_public_key" {
  type        = string
  description = "Public key (contents of the .pub file) installed on the instance for the 'ubuntu' user"
}

variable "ssh_allowed_cidr" {
  type        = string
  description = "CIDR block allowed to reach the instance on port 22. Restrict this to your own IP outside of quick testing."
  default     = "0.0.0.0/0"
}

variable "instance_shape" {
  type        = string
  description = "Compute shape. VM.Standard.A1.Flex is Always-Free eligible (up to 4 OCPU / 24 GB total per tenancy)."
  default     = "VM.Standard.A1.Flex"
}

variable "instance_ocpus" {
  type        = number
  description = "OCPUs for the instance (Always Free covers up to 4 total across all A1.Flex instances)"
  default     = 2
}

variable "instance_memory_gb" {
  type        = number
  description = "Memory in GB for the instance (Always Free covers up to 24 GB total)"
  default     = 12
}

variable "boot_volume_size_gb" {
  type        = number
  description = "Boot volume size in GB (Always Free covers up to 200 GB of block storage total)"
  default     = 100
}
