data "oci_identity_availability_domains" "this" {
  compartment_id = var.tenancy_ocid
}

data "oci_core_images" "this" {
  compartment_id           = var.tenancy_ocid
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "24.04"
  shape                    = "VM.Standard.A1.Flex"
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

resource "oci_core_instance" "this" {
  availability_domain = data.oci_identity_availability_domains.this.availability_domains[var.availability_domain_index].name
  compartment_id      = local.compartment_ocid
  display_name        = "matrix-a1"
  shape               = "VM.Standard.A1.Flex"

  shape_config {
    ocpus         = var.ocpus
    memory_in_gbs = var.memory_in_gbs
  }

  source_details {
    source_type             = "image"
    source_id               = data.oci_core_images.this.images[0].id
    boot_volume_size_in_gbs = var.boot_volume_size_in_gbs
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.this.id
    assign_public_ip = true
    display_name     = "matrix-vnic"
    hostname_label   = "matrix"
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
    user_data           = base64encode(file("${path.module}/cloud-init.yaml"))
  }

  lifecycle {
    # source_details: a shape/volume change must not silently resize the volume.
    #
    # metadata: cloud-init.yaml is creation-time only, but in this provider a change
    # to metadata.user_data forces instance REPLACEMENT — which would destroy
    # /opt/matrix (Matrix DB, media, bridge config) and change the public IP.
    # The live instance is kept in sync by importer/*.sh instead, so user_data drift
    # is ignored. To roll a cloud-init change in deliberately:
    #   terraform taint oci_core_instance.this && terraform apply
    ignore_changes = [source_details, metadata]
  }
}

output "public_ip" {
  value = oci_core_instance.this.public_ip
}

output "ssh" {
  value = "ssh ubuntu@${oci_core_instance.this.public_ip}"
}
