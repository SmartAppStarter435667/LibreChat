#!/usr/bin/env bash
# =============================================================================
# oci-setup-secrets.sh
#
# One-time local bootstrap for the LibreChat-on-OCI CI/CD pipeline.
#
# What it does:
#   1. Reads your OCI API key details from ~/.oci/config
#   2. Generates a dedicated SSH key pair for the compute instance
#   3. Generates strong random secrets required by LibreChat
#   4. Creates (or reuses) an OCI Object Storage bucket + Customer Secret Key
#      for Terraform's remote state
#   5. Pushes everything to this repository's GitHub Actions secrets via `gh`
#
# What it can NOT do, and why:
#   GitHub secrets can only be written by something that already holds a
#   credential with permission to do so. That first credential — your `gh`
#   login used by this script — has to come from somewhere; GitHub has no
#   way to bootstrap permission to write its own secrets from nothing. This
#   script IS that one manual step. Everything after it is automatic.
#
# Requirements: gh (authenticated: `gh auth login`),
#               oci  (configured:   `oci setup config`),
#               openssl, ssh-keygen, jq
# =============================================================================
set -euo pipefail

OCI_PROFILE="${OCI_PROFILE:-DEFAULT}"
OCI_CONFIG_FILE="${OCI_CONFIG_FILE:-$HOME/.oci/config}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEY_DIR="$REPO_ROOT/.secrets"
STATE_BUCKET_NAME="${STATE_BUCKET_NAME:-librechat-tfstate}"
CUSTOMER_KEY_DISPLAY_NAME="${CUSTOMER_KEY_DISPLAY_NAME:-librechat-tfstate-s3}"

bold() { printf '\n\033[1m%s\033[0m\n' "$1"; }
info() { printf '  -> %s\n' "$1"; }
warn() { printf '  ! %s\n' "$1" >&2; }

# --- 0. Preflight ------------------------------------------------------------
bold "[0/6] Checking required tools"
for cmd in gh oci openssl ssh-keygen jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required tool: $cmd" >&2
    exit 1
  fi
done

if ! gh auth status >/dev/null 2>&1; then
  echo "Please run 'gh auth login' first." >&2
  exit 1
fi

REPO="${REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)}"
if [ -z "$REPO" ]; then
  read -rp "GitHub repo (owner/name): " REPO
fi
info "Target repository: $REPO"

# Make sure the generated key material can never be committed by accident.
if [ -f "$REPO_ROOT/.gitignore" ]; then
  grep -qxF '.secrets/' "$REPO_ROOT/.gitignore" || echo '.secrets/' >> "$REPO_ROOT/.gitignore"
else
  echo '.secrets/' > "$REPO_ROOT/.gitignore"
fi

set_secret() {
  # $1 = secret name, $2 = value (piped via stdin so it never appears in
  # shell history or `ps` output)
  printf '%s' "$2" | gh secret set "$1" --repo "$REPO" >/dev/null
  info "Set secret $1"
}

# --- 1. Read OCI identity from ~/.oci/config ---------------------------------
bold "[1/6] Reading OCI credentials from $OCI_CONFIG_FILE ([$OCI_PROFILE] profile)"
if [ ! -f "$OCI_CONFIG_FILE" ]; then
  echo "OCI CLI config not found. Run 'oci setup config' first." >&2
  exit 1
fi

read_ini_value() {
  awk -v section="[$OCI_PROFILE]" -v key="$1" '
    $0 == section { in_section=1; next }
    /^\[/ { in_section=0 }
    in_section && $0 ~ "^"key"[[:space:]]*=" {
      sub("^"key"[[:space:]]*=[[:space:]]*", "");
      print;
      exit
    }
  ' "$OCI_CONFIG_FILE"
}

OCI_TENANCY_OCID="$(read_ini_value tenancy)"
OCI_USER_OCID="$(read_ini_value user)"
OCI_FINGERPRINT="$(read_ini_value fingerprint)"
OCI_REGION="$(read_ini_value region)"
OCI_KEY_FILE="$(read_ini_value key_file)"
OCI_KEY_FILE="${OCI_KEY_FILE/#\~/$HOME}"

for v in OCI_TENANCY_OCID OCI_USER_OCID OCI_FINGERPRINT OCI_REGION OCI_KEY_FILE; do
  if [ -z "${!v}" ]; then
    echo "Could not read $v from $OCI_CONFIG_FILE — check the [$OCI_PROFILE] section." >&2
    exit 1
  fi
done
OCI_PRIVATE_KEY="$(cat "$OCI_KEY_FILE")"
info "tenancy=$OCI_TENANCY_OCID region=$OCI_REGION"

read -rp "Compartment OCID to deploy into [Enter = tenancy root]: " OCI_COMPARTMENT_OCID
OCI_COMPARTMENT_OCID="${OCI_COMPARTMENT_OCID:-$OCI_TENANCY_OCID}"

read -rp "Domain name for LibreChat [Enter = use the instance's IP instead]: " DOMAIN_NAME
read -rp "CIDR allowed to SSH into the instance [Enter = 0.0.0.0/0, tighten later]: " SSH_ALLOWED_CIDR
SSH_ALLOWED_CIDR="${SSH_ALLOWED_CIDR:-0.0.0.0/0}"

# --- 2. SSH key pair for the instance -----------------------------------------
bold "[2/6] Preparing an SSH key pair for the compute instance"
mkdir -p "$KEY_DIR"
SSH_KEY_PATH="$KEY_DIR/librechat_oci_ed25519"
if [ ! -f "$SSH_KEY_PATH" ]; then
  ssh-keygen -t ed25519 -N "" -C "librechat-oci-deploy" -f "$SSH_KEY_PATH" >/dev/null
  info "Generated a new key pair at $SSH_KEY_PATH"
else
  info "Reusing existing key pair at $SSH_KEY_PATH"
fi
SSH_PRIVATE_KEY="$(cat "$SSH_KEY_PATH")"
SSH_PUBLIC_KEY="$(cat "$SSH_KEY_PATH.pub")"

# --- 3. LibreChat application secrets -----------------------------------------
bold "[3/6] Generating LibreChat application secrets"
LIBRECHAT_JWT_SECRET="$(openssl rand -hex 32)"
LIBRECHAT_JWT_REFRESH_SECRET="$(openssl rand -hex 32)"
LIBRECHAT_CREDS_KEY="$(openssl rand -hex 32)"
LIBRECHAT_CREDS_IV="$(openssl rand -hex 16)"
LIBRECHAT_MEILI_MASTER_KEY="$(openssl rand -hex 32)"
info "Generated JWT_SECRET, JWT_REFRESH_SECRET, CREDS_KEY, CREDS_IV, MEILI_MASTER_KEY"

# --- 4. Terraform remote state backend (OCI Object Storage, S3-compatible) ---
bold "[4/6] Setting up the Terraform remote state backend"
TF_STATE_NAMESPACE="$(oci os ns get --query 'data' --raw-output)"
info "Object Storage namespace: $TF_STATE_NAMESPACE"

if oci os bucket get --bucket-name "$STATE_BUCKET_NAME" --namespace "$TF_STATE_NAMESPACE" >/dev/null 2>&1; then
  info "Bucket '$STATE_BUCKET_NAME' already exists, reusing it"
else
  oci os bucket create \
    --compartment-id "$OCI_COMPARTMENT_OCID" \
    --namespace "$TF_STATE_NAMESPACE" \
    --name "$STATE_BUCKET_NAME" \
    --versioning Enabled >/dev/null
  info "Created bucket '$STATE_BUCKET_NAME' (versioning enabled)"
fi

EXISTING_KEY_ID="$(oci iam customer-secret-key list --user-id "$OCI_USER_OCID" \
  --query "data[?\"display-name\"=='$CUSTOMER_KEY_DISPLAY_NAME'].id | [0]" --raw-output 2>/dev/null || true)"

TF_STATE_ACCESS_KEY=""
TF_STATE_SECRET_KEY=""
if [ -n "$EXISTING_KEY_ID" ] && [ "$EXISTING_KEY_ID" != "null" ]; then
  warn "A customer secret key named '$CUSTOMER_KEY_DISPLAY_NAME' already exists."
  warn "OCI never re-displays a secret key's value, so it can't be fetched again here."
  warn "If TF_STATE_ACCESS_KEY / TF_STATE_SECRET_KEY are already set on $REPO,"
  warn "this is expected — leave them as-is. Otherwise, delete this key under"
  warn "OCI Console -> Identity -> Users -> <you> -> Customer Secret Keys and re-run."
else
  CSK_JSON="$(oci iam customer-secret-key create --user-id "$OCI_USER_OCID" --display-name "$CUSTOMER_KEY_DISPLAY_NAME")"
  TF_STATE_ACCESS_KEY="$(printf '%s' "$CSK_JSON" | jq -r '.data.id')"
  TF_STATE_SECRET_KEY="$(printf '%s' "$CSK_JSON" | jq -r '.data.key')"
  info "Created a new Customer Secret Key for Terraform state access"
fi

# --- 5. Push everything to GitHub Actions secrets -----------------------------
bold "[5/6] Writing GitHub Actions secrets on $REPO"
set_secret OCI_TENANCY_OCID "$OCI_TENANCY_OCID"
set_secret OCI_USER_OCID "$OCI_USER_OCID"
set_secret OCI_FINGERPRINT "$OCI_FINGERPRINT"
set_secret OCI_PRIVATE_KEY "$OCI_PRIVATE_KEY"
set_secret OCI_REGION "$OCI_REGION"
set_secret OCI_COMPARTMENT_OCID "$OCI_COMPARTMENT_OCID"
set_secret SSH_PRIVATE_KEY "$SSH_PRIVATE_KEY"
set_secret SSH_PUBLIC_KEY "$SSH_PUBLIC_KEY"
set_secret SSH_ALLOWED_CIDR "$SSH_ALLOWED_CIDR"
set_secret LIBRECHAT_JWT_SECRET "$LIBRECHAT_JWT_SECRET"
set_secret LIBRECHAT_JWT_REFRESH_SECRET "$LIBRECHAT_JWT_REFRESH_SECRET"
set_secret LIBRECHAT_CREDS_KEY "$LIBRECHAT_CREDS_KEY"
set_secret LIBRECHAT_CREDS_IV "$LIBRECHAT_CREDS_IV"
set_secret LIBRECHAT_MEILI_MASTER_KEY "$LIBRECHAT_MEILI_MASTER_KEY"
set_secret TF_STATE_BUCKET "$STATE_BUCKET_NAME"
set_secret TF_STATE_NAMESPACE "$TF_STATE_NAMESPACE"
[ -n "$TF_STATE_ACCESS_KEY" ] && set_secret TF_STATE_ACCESS_KEY "$TF_STATE_ACCESS_KEY"
[ -n "$TF_STATE_SECRET_KEY" ] && set_secret TF_STATE_SECRET_KEY "$TF_STATE_SECRET_KEY"
[ -n "$DOMAIN_NAME" ] && set_secret DOMAIN_NAME "$DOMAIN_NAME"

# --- 6. Summary ----------------------------------------------------------------
bold "[6/6] Done"
cat <<SUMMARY

Secrets configured on $REPO.

Still manual, by design:
  - This script's own inputs (your 'gh' login + local 'oci setup config').
    Nothing can write GitHub secrets without a credential granting that
    permission in the first place.
  - Optional LLM provider keys, if you want the server itself (rather than
    each signed-in user) to supply them:
      gh secret set ANTHROPIC_API_KEY --repo $REPO
      gh secret set OPENAI_API_KEY    --repo $REPO
      gh secret set GOOGLE_KEY        --repo $REPO
    Leave them unset and users paste their own key into the LibreChat UI.
  - SSH_ALLOWED_CIDR is currently '$SSH_ALLOWED_CIDR'. Narrow it to your own
    IP (curl ifconfig.me) for anything beyond quick testing.

Next: commit and push terraform/, .github/workflows/, and scripts/ to
$REPO, then trigger "Deploy LibreChat to OCI (Terraform)" from the Actions
tab (or just push to main).
SUMMARY
