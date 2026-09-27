# Cost controls and backup authorization, both Always Free features.
#
# Everything here is deliberately in Terraform rather than a console click, so a
# rebuild restores the cost tripwires and the backup permissions instead of
# silently dropping them. The standing rule for this stack: no resource type that
# is billed continuously may ever be added (NAT gateway, WAF, load balancer,
# backups policy, paid logging) — those are the only things that can turn a $0
# instance into a bill.

locals {
  # Literal name, not a reference to the resource below: the policy must be
  # appliable on its own. Referring to the dynamic group (which refers to the
  # instance) would make Terraform pull the instance into the operation set, and
  # a stale cloud-init user_data would then replace the live VM.
  backup_dynamic_group_name = "buncha-backup"
}

# Least privilege: only this instance's principal, not "everything in tenancy".
resource "oci_identity_dynamic_group" "backup" {
  compartment_id = local.compartment_ocid
  name           = local.backup_dynamic_group_name
  description    = "buncha backup uploader: the Matrix instance principal, and nothing else."
  matching_rule  = "ALL {resource.id = '${oci_core_instance.this.id}'}"
}

# Object Storage only. No VCN, no instances, no other compartments' objects.
resource "oci_identity_policy" "backup" {
  compartment_id = local.compartment_ocid
  name           = "buncha-backup-policy"
  description    = "Lets the buncha backup dynamic group use the buncha-backups bucket (nightly DB/config uploads)."

  # "manage buckets" (not "read") is required: OCI answers a PutObject/ListObjects
  # from an unauthorized-but-existing bucket with 404 BucketNotFound, not 403, so a
  # too-narrow verb looks exactly like a missing bucket. Scope stays tenancy-wide
  # on buckets/objects only — no VCN, no instances, no other object namespaces.
  statements = [
    "Allow dynamicgroup buncha-backup to manage buckets in tenancy",
    "Allow dynamicgroup buncha-backup to manage objects in tenancy",
  ]
}

# The only runtime cost tripwire. OCI has no hard spending limit on free
# accounts, so this alert is what actually notifies us; the variable validations
# in variables.tf and importer-free-tier-guard are the earlier, harder gates.
resource "oci_budget_budget" "always_free_guard" {
  compartment_id = local.compartment_ocid
  amount         = 1
  display_name   = "buncha-always-free-guard"
  description    = "buncha should never cost anything. Any spend at all is a bug: this $$1/month budget exists so OCI tells us before the bill does."

  processing_period_type = "MONTH"
  reset_period           = "MONTHLY"
  target_type            = "COMPARTMENT"
  target_compartment_id  = local.compartment_ocid
}

resource "oci_budget_alert_rule" "half_spent" {
  budget_id    = oci_budget_budget.always_free_guard.id
  display_name = "half-of-guard-budget-spent"
  description  = "Fires at $$0.50 of the $$1 guard budget."

  type           = "ACTUAL"
  threshold      = 0.5
  threshold_type = "PERCENTAGE"
  recipients     = var.admin_email

  message = <<-EOT
    buncha cost guard: 50% of the $1/month guard budget spent (~$0.50).
    This stack is meant to be $0.00 (2 OCPU / 12 GB A1, 200 GB block, 20 GB Object
    Storage). Look for a resource that is not Always Free — NAT gateway, WAF,
    load balancer, backups policy, paid logging, or an oversized shape/volume —
    and check terraform/free-tier-guard.ps1.
  EOT
}
