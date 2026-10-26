#!/usr/bin/env bash
#
# Creates a Google Cloud project and a Cloud Storage bucket that serves a
# static website, then uploads site/. Safe to re-run: an existing project is
# reused only if it already carries this proof's labels.
#
# Usage: ./scripts/deploy.sh
# Reads GCP_PROJECT_ID, GCP_BILLING_ACCOUNT, GCP_REGION, and BUCKET_NAME
# from .env in the repo root. Does not create a load balancer or Cloud CDN
# (content delivery network). The website address is HTTP, not HTTPS.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"

load_env
require_gcloud
require_login
require_project_settings
require_billing_account

SITE_DIR="$REPO_ROOT/site"
if [[ ! -f "$SITE_DIR/index.html" || ! -f "$SITE_DIR/404.html" ]]; then
  echo "site/ needs index.html and 404.html before this can upload anything." >&2
  exit 1
fi

WEB_URL="http://${BUCKET_NAME}.storage.googleapis.com/"

echo "Project:  $GCP_PROJECT_ID"
echo "Bucket:   $BUCKET_NAME"
echo "Region:   $GCP_REGION"
echo "Site URL: $WEB_URL"
echo
echo "Cost: a site this size in $GCP_REGION should stay at \$0 inside the Cloud Storage free tier"
echo "(5 GB of Standard storage, plus a small allowance of operations and outbound traffic)."
echo "Linking a billing account makes charges possible if usage leaves that tier."
echo "This script does not create a load balancer or Cloud CDN. Those are the parts that cost money while idle."
echo

if project_exists; then
  echo "==> Project already exists. Checking its labels."
  assert_our_project
else
  echo "==> Creating project"
  created="$(date -u +%Y-%m-%dt%H-%M-%Sz)"
  gcloud projects create "$GCP_PROJECT_ID" \
    --name="static website poc" \
    --labels="$(label_csv "$created")"
fi

echo "==> Linking billing, if it is not linked yet"
billing_enabled="$(gcloud billing projects describe "$GCP_PROJECT_ID" --format="value(billingEnabled)" 2>/dev/null || true)"
billing_enabled="$(printf '%s' "$billing_enabled" | tr '[:upper:]' '[:lower:]')"
if [[ "$billing_enabled" == "true" ]]; then
  echo "    Already linked."
else
  gcloud billing projects link "$GCP_PROJECT_ID" \
    --billing-account="$GCP_BILLING_ACCOUNT" >/dev/null
  echo "    Linked."
fi

echo "==> Enabling the Cloud Storage API"
run_until_ready gcloud services enable storage.googleapis.com --project="$GCP_PROJECT_ID"

echo "==> Creating bucket"
if gcloud storage buckets describe "gs://${BUCKET_NAME}" --project="$GCP_PROJECT_ID" >/dev/null 2>&1; then
  echo "    Already exists, reusing it."
  assert_our_bucket
else
  run_until_ready gcloud storage buckets create "gs://${BUCKET_NAME}" \
    --project="$GCP_PROJECT_ID" \
    --location="$GCP_REGION" \
    --default-storage-class=STANDARD \
    --uniform-bucket-level-access \
    --no-public-access-prevention \
    --soft-delete-duration=0
fi

bucket_created="$(gcloud storage buckets describe "gs://${BUCKET_NAME}" --project="$GCP_PROJECT_ID" --format="value(labels.created)" 2>/dev/null || true)"
if [[ -z "$bucket_created" ]]; then
  bucket_created="$(date -u +%Y-%m-%dt%H-%M-%Sz)"
  echo "==> Labeling the bucket"
  gcloud storage buckets update "gs://${BUCKET_NAME}" \
    --project="$GCP_PROJECT_ID" \
    --update-labels="$(label_csv "$bucket_created")"
fi

echo "==> Setting the index page and the missing-page file"
gcloud storage buckets update "gs://${BUCKET_NAME}" \
  --project="$GCP_PROJECT_ID" \
  --web-main-page-suffix=index.html \
  --web-error-page=404.html

echo "==> Letting anyone on the internet read objects"
gcloud storage buckets add-iam-policy-binding "gs://${BUCKET_NAME}" \
  --project="$GCP_PROJECT_ID" \
  --member=allUsers \
  --role=roles/storage.objectViewer >/dev/null

echo "==> Uploading site files"
gcloud storage rsync "$SITE_DIR" "gs://${BUCKET_NAME}" \
  --project="$GCP_PROJECT_ID" \
  --recursive \
  --delete-unmatched-destination-objects \
  --exclude='\.DS_Store$'

echo
echo "Done. Open the home page at:"
echo "  https://storage.googleapis.com/${BUCKET_NAME}/index.html"
echo
echo "The bucket root (${WEB_URL}) lists object names. Google applies index.html and 404.html"
echo "only when a custom domain points at the bucket, not on storage.googleapis.com."
echo "Check it with: ./scripts/verify.sh"
