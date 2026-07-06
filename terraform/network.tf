resource "oci_core_vcn" "this" {
  compartment_id = var.oci_compartment_ocid
  cidr_blocks    = ["10.20.0.0/16"]
  display_name   = "librechat-vcn"
  dns_label      = "librechat"
}

resource "oci_core_internet_gateway" "this" {
  compartment_id = var.oci_compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "librechat-igw"
  enabled        = true
}

resource "oci_core_route_table" "this" {
  compartment_id = var.oci_compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "librechat-rt"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.this.id
  }
}

resource "oci_core_security_list" "this" {
  compartment_id = var.oci_compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "librechat-sl"

  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
  }

  # SSH - restrict via var.ssh_allowed_cidr (see terraform.tfvars.example)
  ingress_security_rules {
    protocol = "6" # TCP
    source   = var.ssh_allowed_cidr

    tcp_options {
      min = 22
      max = 22
    }
  }

  # HTTP - nginx serves LibreChat here
  ingress_security_rules {
    protocol = "6"
    source   = "0.0.0.0/0"

    tcp_options {
      min = 80
      max = 80
    }
  }

  # HTTPS - only useful once you terminate TLS yourself or via Cloudflare
  # (see OCI_DEPLOYMENT_GUIDE.md)
  ingress_security_rules {
    protocol = "6"
    source   = "0.0.0.0/0"

    tcp_options {
      min = 443
      max = 443
    }
  }

  # Path MTU discovery (standard practice for OCI VCNs)
  ingress_security_rules {
    protocol = "1" # ICMP
    source   = "0.0.0.0/0"

    icmp_options {
      type = 3
      code = 4
    }
  }
}

resource "oci_core_subnet" "public" {
  compartment_id             = var.oci_compartment_ocid
  vcn_id                     = oci_core_vcn.this.id
  cidr_block                 = "10.20.1.0/24"
  display_name               = "librechat-public-subnet"
  dns_label                  = "public"
  route_table_id             = oci_core_route_table.this.id
  security_list_ids          = [oci_core_security_list.this.id]
  prohibit_public_ip_on_vnic = false
}
