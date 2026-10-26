#!/usr/bin/env bash
#
# Deletes the bucket and the Google Cloud project this proof created.
# Lists them first and continues only if you type the project id.
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

HAS_PROJECT=false
HAS_BUCKET=false

if project_exists; then
  HAS_PROJECT=true
  assert_our_project
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

if [[ "$HAS_PROJECT" != true && "$HAS_BUCKET" != true ]]; then
  echo "Nothing to delete: project $GCP_PROJECT_ID and bucket $BUCKET_NAME are not there."
  exit 0
fi

echo "This will permanently delete:"
if [[ "$HAS_BUCKET" == true ]]; then
  echo "  - Bucket gs://${BUCKET_NAME} and the public site"
fi
if [[ "$HAS_PROJECT" == true ]]; then
  echo "  - Google Cloud project $GCP_PROJECT_ID"
  echo "    The project id cannot be reused until Google finishes deleting it, which can take 30 days."
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
  gcloud projects delete "$GCP_PROJECT_ID" --quiet
fi

echo
echo "Delete requested. The site should stop serving within a few minutes."
echo "The project stays in a pending-delete state until Google removes it."
