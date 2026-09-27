variable "tenancy_ocid" {
  type = string
}

variable "user_ocid" {
  type = string
}

variable "fingerprint" {
  type = string
}

variable "private_key_path" {
  type = string
}

variable "region" {
  type = string
}

variable "compartment_ocid" {
  type    = string
  default = null
}

variable "availability_domain_index" {
  description = "Index into the tenancy's availability domains. Change and re-apply if you hit 'out of host capacity'."
  type        = number
  default     = 0
}

variable "ssh_public_key" {
  type = string
}

variable "admin_cidr" {
  description = "CIDR allowed to reach SSH."
  type        = string
  default     = "0.0.0.0/0"
}

variable "ocpus" {
  description = "Always Free A1 allowance is 2 OCPU total per tenancy. Do not exceed."
  type        = number
  default     = 2

  validation {
    condition     = var.ocpus <= 2
    error_message = "Always Free A1 total is 2 OCPU; var.ocpus must be <= 2."
  }
}

variable "memory_in_gbs" {
  description = "Always Free A1 allowance is 12 GB total per tenancy. Do not exceed."
  type        = number
  default     = 12

  validation {
    condition     = var.memory_in_gbs <= 12
    error_message = "Always Free A1 total is 12 GB; var.memory_in_gbs must be <= 12."
  }
}

variable "objectstorage_namespace" {
  description = "Object Storage namespace of the tenancy (visible in the bucket's details page)."
  type        = string
}

variable "admin_email" {
  description = "Notification address for the OCI budget alert that guards the Always Free account."
  type        = string
}

variable "boot_volume_size_in_gbs" {
  description = "Keep total block storage across the tenancy at or under 200 GB to stay Always Free."
  type        = number
  default     = 50

  validation {
    condition     = var.boot_volume_size_in_gbs <= 200
    error_message = "Always Free block volume total is 200 GB; var.boot_volume_size_in_gbs must be <= 200."
  }
}
