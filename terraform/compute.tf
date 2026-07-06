# -----------------------------------------------------------------------------
# Latest Canonical Ubuntu 24.04 Minimal (aarch64) image compatible with the
# chosen shape. Sorted newest-first; [0] picks the latest.
#
# NOTE: if this returns no images (e.g. Oracle tweaks the naming convention),
# open the OCI Console -> Compute -> Images, find the current
# "Canonical-Ubuntu-24.04-Minimal-aarch64-*" image, and either adjust the
# filter below or hard-code its OCID temporarily via `source_id`.
# -----------------------------------------------------------------------------
data "oci_core_images" "ubuntu" {
  compartment_id           = var.oci_compartment_ocid
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "24.04"
  shape                    = var.instance_shape
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"

  filter {
    name   = "display_name"
    values = ["^Canonical-Ubuntu-24\\.04-Minimal-aarch64-.*"]
    regex  = true
  }
}

data "oci_identity_availability_domains" "ads" {
  compartment_id = var.oci_tenancy_ocid
}

resource "oci_core_instance" "librechat" {
  compartment_id      = var.oci_compartment_ocid
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
  display_name        = "librechat-server"
  shape               = var.instance_shape

  shape_config {
    ocpus         = var.instance_ocpus
    memory_in_gbs = var.instance_memory_gb
  }

  source_details {
    source_type             = "image"
    source_id               = data.oci_core_images.ubuntu.images[0].id
    boot_volume_size_in_gbs = var.boot_volume_size_gb
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.public.id
    assign_public_ip = true
    hostname_label   = "librechat"
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
    # Static cloud-init: installs Docker, opens 80/443 in the instance's own
    # iptables (OCI images reject inbound traffic other than SSH by default,
    # regardless of the Security List above), and prepares /opt/librechat.
    # The actual LibreChat files are placed there by the GitHub Actions
    # workflows, not by cloud-init, so app-only redeploys never touch this.
    user_data = base64encode(file("${path.module}/cloud-init.yaml"))
  }

  timeouts {
    create = "30m"
  }

  lifecycle {
    # Don't replace (and wipe) an existing instance just because a newer
    # Ubuntu image was published upstream between applies.
    ignore_changes = [source_details]
  }
}
