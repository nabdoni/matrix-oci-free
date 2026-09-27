locals {
  compartment_ocid = coalesce(var.compartment_ocid, var.tenancy_ocid)
}

resource "oci_core_vcn" "this" {
  compartment_id = local.compartment_ocid
  cidr_blocks    = ["10.0.0.0/16"]
  display_name   = "matrix-vcn"
  dns_label      = "matrixvcn"
}

resource "oci_core_internet_gateway" "this" {
  compartment_id = local.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "matrix-igw"
  enabled        = true
}

resource "oci_core_route_table" "this" {
  compartment_id = local.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "matrix-rt"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.this.id
  }
}

resource "oci_core_security_list" "this" {
  compartment_id = local.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "matrix-sl"

  egress_security_rules {
    destination      = "0.0.0.0/0"
    destination_type = "CIDR_BLOCK"
    protocol         = "all"
  }

  ingress_security_rules {
    protocol    = "6"
    source      = var.admin_cidr
    source_type = "CIDR_BLOCK"
    tcp_options {
      min = 22
      max = 22
    }
  }

  ingress_security_rules {
    protocol    = "6"
    source      = "0.0.0.0/0"
    source_type = "CIDR_BLOCK"
    tcp_options {
      min = 80
      max = 80
    }
  }

  ingress_security_rules {
    protocol    = "6"
    source      = "0.0.0.0/0"
    source_type = "CIDR_BLOCK"
    tcp_options {
      min = 443
      max = 443
    }
  }

  # NOTE: 8448 (federation) intentionally NOT opened — this is a private server and
  # we do not want it discoverable/crawlable by other homeservers.

  ingress_security_rules {
    protocol    = "6"
    source      = "0.0.0.0/0"
    source_type = "CIDR_BLOCK"
    tcp_options {
      min = 7881
      max = 7881
    }
  }

  ingress_security_rules {
    protocol    = "6"
    source      = "0.0.0.0/0"
    source_type = "CIDR_BLOCK"
    tcp_options {
      min = 3478
      max = 3478
    }
  }

  ingress_security_rules {
    protocol    = "17"
    source      = "0.0.0.0/0"
    source_type = "CIDR_BLOCK"
    udp_options {
      min = 3478
      max = 3478
    }
  }

  ingress_security_rules {
    protocol    = "17"
    source      = "0.0.0.0/0"
    source_type = "CIDR_BLOCK"
    udp_options {
      min = 50000
      max = 60000
    }
  }

  ingress_security_rules {
    protocol    = "1"
    source      = "0.0.0.0/0"
    source_type = "CIDR_BLOCK"
    icmp_options {
      type = 3
      code = 4
    }
  }
}

resource "oci_core_subnet" "this" {
  compartment_id             = local.compartment_ocid
  vcn_id                     = oci_core_vcn.this.id
  cidr_block                 = "10.0.1.0/24"
  display_name               = "matrix-subnet"
  dns_label                  = "matrixsub"
  route_table_id             = oci_core_route_table.this.id
  security_list_ids          = [oci_core_security_list.this.id]
  prohibit_public_ip_on_vnic = false
}
