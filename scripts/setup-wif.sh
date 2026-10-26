#!/usr/bin/env bash
#
# Lets GitHub Actions upload site/ with no key file.
# The trust rule uses the subject GitHub actually sends for this repository.
# The workflow identity can write and delete objects in this one bucket.
# It cannot delete the bucket, change who can read it, or touch the project.
#
# Does not upload the site and does not create a key. Run deploy.sh first.
#
# Usage: ./scripts/setup-wif.sh [github-owner/repo]
#   repo  defaults to the GitHub repository in this folder

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"

load_env
require_gcloud
require_login
require_project_settings

if ! command -v gh >/dev/null 2>&1 || ! gh auth status >/dev/null 2>&1; then
  echo "The GitHub CLI (gh) must be installed and signed in. The trust rule is copied from GitHub, not typed from a guide." >&2
  exit 1
fi

REPO="${1:-}"
if [[ -z "$REPO" ]]; then
  REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
fi
if [[ ! "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  echo "Usage: $0 [github-owner/repo]" >&2
  exit 1
fi

if ! project_exists; then
  echo "Project $GCP_PROJECT_ID does not exist. Run ./scripts/deploy.sh first." >&2
  exit 1
fi
assert_our_project

if ! gcloud storage buckets describe "gs://${BUCKET_NAME}" --project="$GCP_PROJECT_ID" >/dev/null 2>&1; then
  echo "Bucket $BUCKET_NAME does not exist. Run ./scripts/deploy.sh first." >&2
  exit 1
fi
assert_our_bucket

# GitHub's default subject for a new repository includes permanent owner and
# repository ids. A name-only rule (repo:owner/name:...) does not match.
SUBJECT_PREFIX="$(gh api "repos/${REPO}/actions/oidc/customization/sub" --jq '.sub_claim_prefix // empty')"
if [[ ! "$SUBJECT_PREFIX" =~ ^repo: ]]; then
  echo "GitHub did not return a subject prefix for $REPO. Nothing was created." >&2
  exit 1
fi
ENVIRONMENT="production"
SUBJECT="${SUBJECT_PREFIX}:environment:${ENVIRONMENT}"

# A service account id is limited to 30 characters, so it cannot repeat the
# repository name. The display name still does.
POOL_ID="gh-staticweb"
PROVIDER_ID="github-production"
SA_ID="gh-staticweb-poc"
SA_EMAIL="${SA_ID}@${GCP_PROJECT_ID}.iam.gserviceaccount.com"
ATTRIBUTE_MAPPING="google.subject=assertion.sub,attribute.repository=assertion.repository"
ATTRIBUTE_CONDITION="assertion.repository=='${REPO}' && assertion.sub=='${SUBJECT}'"

echo "Repository: $REPO"
echo "Subject:    $SUBJECT"
echo "Identity:   $SA_EMAIL"
echo
echo "This creates a free identity. It does not create a key, a load balancer, or another bucket."
echo

echo "==> Enabling the identity APIs"
run_until_ready gcloud services enable \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  sts.googleapis.com \
  --project="$GCP_PROJECT_ID"

echo "==> Creating the workload identity pool"
if gcloud iam workload-identity-pools describe "$POOL_ID" \
    --project="$GCP_PROJECT_ID" --location=global >/dev/null 2>&1; then
  echo "    Already exists, reusing it."
else
  gcloud iam workload-identity-pools create "$POOL_ID" \
    --project="$GCP_PROJECT_ID" \
    --location=global \
    --display-name="GitHub static website" \
    --description="GitHub Actions for gcp-static-website-poc"
fi

echo "==> Setting the trust rule to GitHub's subject"
if gcloud iam workload-identity-pools providers describe "$PROVIDER_ID" \
    --project="$GCP_PROJECT_ID" --location=global \
    --workload-identity-pool="$POOL_ID" >/dev/null 2>&1; then
  gcloud iam workload-identity-pools providers update-oidc "$PROVIDER_ID" \
    --project="$GCP_PROJECT_ID" \
    --location=global \
    --workload-identity-pool="$POOL_ID" \
    --issuer-uri="https://token.actions.githubusercontent.com" \
    --attribute-mapping="$ATTRIBUTE_MAPPING" \
    --attribute-condition="$ATTRIBUTE_CONDITION"
  echo "    Updated."
else
  gcloud iam workload-identity-pools providers create-oidc "$PROVIDER_ID" \
    --project="$GCP_PROJECT_ID" \
    --location=global \
    --workload-identity-pool="$POOL_ID" \
    --display-name="GitHub production" \
    --issuer-uri="https://token.actions.githubusercontent.com" \
    --attribute-mapping="$ATTRIBUTE_MAPPING" \
    --attribute-condition="$ATTRIBUTE_CONDITION"
fi

echo "==> Creating the service account"
if gcloud iam service-accounts describe "$SA_EMAIL" --project="$GCP_PROJECT_ID" >/dev/null 2>&1; then
  echo "    Already exists, reusing it."
else
  gcloud iam service-accounts create "$SA_ID" \
    --project="$GCP_PROJECT_ID" \
    --display-name="github-actions-gcp-static-website-poc"
fi

echo "==> Letting that account write objects in this bucket only"
gcloud storage buckets add-iam-policy-binding "gs://${BUCKET_NAME}" \
  --project="$GCP_PROJECT_ID" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/storage.objectAdmin" >/dev/null

PROJECT_NUMBER="$(gcloud projects describe "$GCP_PROJECT_ID" --format="value(projectNumber)")"
MEMBER="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_ID}/attribute.repository/${REPO}"

echo "==> Letting GitHub act as that account"
gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
  --project="$GCP_PROJECT_ID" \
  --role="roles/iam.workloadIdentityUser" \
  --member="$MEMBER" >/dev/null

PROVIDER_RESOURCE="projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_ID}/providers/${PROVIDER_ID}"
SITE_URL="https://storage.googleapis.com/${BUCKET_NAME}/index.html"

echo
echo "==> Saving values in GitHub repository $REPO"
SAVED_TO_GITHUB=false
read -r -p "    Save them in $REPO now? [Y/n] " ANSWER || ANSWER=n
if [[ ! "$ANSWER" =~ ^[Nn] ]]; then
  printf '%s' "$PROVIDER_RESOURCE" | gh secret set GCP_WORKLOAD_IDENTITY_PROVIDER --repo "$REPO"
  gh variable set GCP_SERVICE_ACCOUNT --repo "$REPO" --body "$SA_EMAIL"
  gh variable set GCP_PROJECT_ID --repo "$REPO" --body "$GCP_PROJECT_ID"
  gh variable set BUCKET_NAME --repo "$REPO" --body "$BUCKET_NAME"
  gh variable set SITE_URL --repo "$REPO" --body "$SITE_URL"
  SAVED_TO_GITHUB=true
fi

echo
if [[ "$SAVED_TO_GITHUB" == true ]]; then
  echo "Done. Saved in GitHub. The provider name is a secret and is not printed."
  echo "  Secret:    GCP_WORKLOAD_IDENTITY_PROVIDER"
  echo "  Variables: GCP_SERVICE_ACCOUNT=$SA_EMAIL"
  echo "             GCP_PROJECT_ID=$GCP_PROJECT_ID"
  echo "             BUCKET_NAME=$BUCKET_NAME"
  echo "             SITE_URL=$SITE_URL"
else
  echo "Done. Add these at https://github.com/${REPO}/settings/secrets/actions"
  echo "Do not commit the provider value. It contains the project number."
  echo "  Secret: GCP_WORKLOAD_IDENTITY_PROVIDER"
  echo "          $PROVIDER_RESOURCE"
  echo "  Variables:"
  echo "    GCP_SERVICE_ACCOUNT  $SA_EMAIL"
  echo "    GCP_PROJECT_ID       $GCP_PROJECT_ID"
  echo "    BUCKET_NAME          $BUCKET_NAME"
  echo "    SITE_URL             $SITE_URL"
fi
echo
echo "No key file was created."
echo "A push to main runs .github/workflows/deploy.yml, which uploads site/."
