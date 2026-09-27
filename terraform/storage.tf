# Object Storage: the nightly backup target.
#
# Free tier: 20 GB across Standard + Infrequent Access, 50,000 requests/month.
#
# The bucket is asserted, not created. It was created once by hand, and
# `terraform import oci_objectstorage_bucket...` fails in the current provider
# ("can not marshal to path in request for field NamespaceName ... nil pointer")
# for both the documented `n/<ns>/<name>` id and the bare bucket name. Asserting
# it with a data source still gives us the useful property: `terraform plan`
# fails loudly if the backup target ever disappears, and nothing tries to create a
# duplicate. To create it on a fresh tenancy, run importer/create-backup-bucket.sh
# (or the console), then this data source will resolve.
data "oci_objectstorage_bucket" "backups" {
  name      = "buncha-backups"
  namespace = var.objectstorage_namespace
}

output "backup_bucket" {
  value = data.oci_objectstorage_bucket.backups.name
}
