terraform {
  required_version = ">= 1.6.0"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 5.0"
    }
  }

  # Remote state stored on OCI Object Storage via its S3-compatible API.
  # The actual bucket/credentials are supplied at `terraform init` time via
  # -backend-config flags (see .github/workflows/*.yml), so nothing
  # sensitive lives in this file or in version control.
  #
  # For local/manual use, initialize with:
  #   terraform init \
  #     -backend-config="bucket=<bucket>" \
  #     -backend-config="key=librechat/terraform.tfstate" \
  #     -backend-config="region=<region>" \
  #     -backend-config="endpoint=https://<namespace>.compat.objectstorage.<region>.oraclecloud.com" \
  #     -backend-config="access_key=<customer-secret-key-id>" \
  #     -backend-config="secret_key=<customer-secret-key-secret>" \
  #     -backend-config="skip_region_validation=true" \
  #     -backend-config="skip_credentials_validation=true" \
  #     -backend-config="skip_metadata_api_check=true" \
  #     -backend-config="force_path_style=true"
  backend "s3" {}
}
