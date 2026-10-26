#!/usr/bin/env bash
#
# Deletes the bucket and the Google Cloud project this proof created.
# The identity pool and the service account live in that project, so the
# project delete removes them. The GitHub values do not, so this script
# removes those by name. It never prints the secret's value.
#
# Lists everything first and continues only if you type the project id.
# Refuses to delete a project that does not carry this proof's labels.
#
# Usage: ./scripts/teardown.sh
#
# The nightly sweep is a different script:
#   cloud-projects/environment-control/envctl-gcp.sh
# It deletes projects labeled lifetime=1d that are at least an hour old.
# Run this script when you want the delete now, and you want the prompt.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"

load_env
require_gcloud
require_login
require_project_settings

# Keep these ids the same as scripts/setup-wif.sh.
POOL_ID="gh-staticweb"
PROVIDER_ID="github-production"
SA_ID="gh-staticweb-poc"
SA_EMAIL="${SA_ID}@${GCP_PROJECT_ID}.iam.gserviceaccount.com"
GITHUB_SECRET="GCP_WORKLOAD_IDENTITY_PROVIDER"

HAS_PROJECT=false
HAS_BUCKET=false
HAS_POOL=false
HAS_PROVIDER=false
HAS_SA=false
REPO=""
GITHUB_FOUND=""
GH_READY=false

if project_exists; then
  HAS_PROJECT=true
  assert_our_project

  if gcloud iam workload-identity-pools describe "$POOL_ID" \
      --project="$GCP_PROJECT_ID" --location=global >/dev/null 2>&1; then
    HAS_POOL=true
  fi
  if gcloud iam workload-identity-pools providers describe "$PROVIDER_ID" \
      --project="$GCP_PROJECT_ID" --location=global \
      --workload-identity-pool="$POOL_ID" >/dev/null 2>&1; then
    HAS_PROVIDER=true
  fi
  if gcloud iam service-accounts describe "$SA_EMAIL" --project="$GCP_PROJECT_ID" >/dev/null 2>&1; then
    HAS_SA=true
  fi
fi

if gcloud storage buckets describe "gs://${BUCKET_NAME}" --project="$GCP_PROJECT_ID" >/dev/null 2>&1; then
  HAS_BUCKET=true
  if [[ "$HAS_PROJECT" == true ]]; then
    assert_our_bucket
  else
    bucket_project="$(gcloud storage buckets describe "gs://${BUCKET_NAME}" --format="value(labels.project)")"
    if [[ "$bucket_project" != "$PROJECT_LABEL" ]]; then
      echo "Refusing to delete gs://${BUCKET_NAME}." >&2
      echo "Its project label is not $PROJECT_LABEL, so this proof did not create it." >&2
      exit 1
    fi
  fi
fi

if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  GH_READY=true
  REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)"
fi

if [[ "$GH_READY" == true && "$REPO" == */* ]]; then
  secrets="$(gh secret list --repo "$REPO" --json name --jq '.[].name' 2>/dev/null || true)"
  variables="$(gh variable list --repo "$REPO" --json name --jq '.[].name' 2>/dev/null || true)"
  if grep -qx "$GITHUB_SECRET" <<<"$secrets"; then
    GITHUB_FOUND="$GITHUB_SECRET"
  fi
  for name in GCP_SERVICE_ACCOUNT GCP_PROJECT_ID BUCKET_NAME SITE_URL; do
    if grep -qx "$name" <<<"$variables"; then
      GITHUB_FOUND="${GITHUB_FOUND:+$GITHUB_FOUND }$name"
    fi
  done
fi

if [[ "$HAS_PROJECT" != true && "$HAS_BUCKET" != true && -z "$GITHUB_FOUND" ]]; then
  echo "Nothing to delete: project $GCP_PROJECT_ID, bucket $BUCKET_NAME, and the GitHub values are not there."
  exit 0
fi

echo "This will permanently delete:"
if [[ "$HAS_BUCKET" == true ]]; then
  echo "  - Bucket gs://${BUCKET_NAME} and the public site"
fi
if [[ "$HAS_POOL" == true || "$HAS_PROVIDER" == true || "$HAS_SA" == true ]]; then
  if [[ "$HAS_POOL" == true ]]; then
    echo "  - Workload identity pool $POOL_ID"
  fi
  if [[ "$HAS_PROVIDER" == true ]]; then
    echo "    Provider $PROVIDER_ID"
  fi
  if [[ "$HAS_SA" == true ]]; then
    echo "  - Service account $SA_EMAIL"
  fi
  echo "    These live in the project, so deleting the project removes them."
fi
if [[ "$HAS_PROJECT" == true ]]; then
  echo "  - Google Cloud project $GCP_PROJECT_ID"
  echo "    The project id cannot be reused until Google finishes deleting it, which can take 30 days."
fi
if [[ -n "$GITHUB_FOUND" ]]; then
  echo "  - GitHub values in ${REPO}: ${GITHUB_FOUND}"
elif [[ "$GH_READY" != true ]]; then
  echo "  GitHub values will be left in place. The GitHub CLI (gh) is not signed in."
fi
echo
read -r -p "Type the project id ($GCP_PROJECT_ID) to confirm: " CONFIRM
if [[ "$CONFIRM" != "$GCP_PROJECT_ID" ]]; then
  echo "Names did not match. Nothing was deleted."
  exit 1
fi

if [[ "$HAS_BUCKET" == true ]]; then
  echo "==> Deleting bucket gs://${BUCKET_NAME}"
  gcloud storage rm --recursive "gs://${BUCKET_NAME}/" --project="$GCP_PROJECT_ID"
fi

if [[ "$HAS_PROJECT" == true ]]; then
  echo "==> Deleting project $GCP_PROJECT_ID"
  echo "    This also removes the identity pool and the service account."
  gcloud projects delete "$GCP_PROJECT_ID" --quiet
fi

if [[ -n "$GITHUB_FOUND" ]]; then
  echo "==> Removing GitHub values from $REPO"
  for name in $GITHUB_FOUND; do
    if [[ "$name" == "$GITHUB_SECRET" ]]; then
      gh secret delete "$name" --repo "$REPO"
    else
      gh variable delete "$name" --repo "$REPO"
    fi
  done
fi

echo
echo "Delete requested. The site should stop serving within a few minutes."
echo "The project stays in a pending-delete state until Google removes it."
echo "The GitHub repository itself is untouched. Its deploy workflow will fail until you run deploy.sh and setup-wif.sh again."
