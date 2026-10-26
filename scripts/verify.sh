#!/usr/bin/env bash
#
# Proves the public website responds, and that the project and bucket carry
# the four labels the nightly sweep looks for. Prints a pass/fail line per
# check. Does not create or change anything.
#
# Usage: ./scripts/verify.sh
# Reads the same .env as deploy.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"

load_env
require_gcloud
require_login
require_project_settings

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required for the HTTP checks." >&2
  exit 1
fi

PASS=0
FAIL=0

check() {
  local name="$1"
  local ok="$2"
  if [[ "$ok" == "yes" ]]; then
    printf 'PASS  %s\n' "$name"
    PASS=$((PASS + 1))
  else
    printf 'FAIL  %s\n' "$name"
    FAIL=$((FAIL + 1))
  fi
}

yes_no() {
  if [[ "$1" == "$2" ]]; then
    echo yes
  else
    echo no
  fi
}

# Specialty pages (index and the custom 404) are only applied when a custom
# domain points at the bucket. On storage.googleapis.com the root URL lists
# objects, and a missing name returns the API's own 404. The pages themselves
# are still public at their object addresses.
OBJECT_ROOT="https://storage.googleapis.com/${BUCKET_NAME}"
API_ROOT="http://${BUCKET_NAME}.storage.googleapis.com/"
HOME_BODY="$(mktemp)"
PAGE_404_BODY="$(mktemp)"
MISS_BODY="$(mktemp)"
ROOT_BODY="$(mktemp)"
trap 'rm -f "$HOME_BODY" "$PAGE_404_BODY" "$MISS_BODY" "$ROOT_BODY"' EXIT

echo "Checking ${OBJECT_ROOT}/index.html"
echo

home_code="$(curl -sS -o "$HOME_BODY" -w '%{http_code}' "${OBJECT_ROOT}/index.html" || true)"
check "index.html returns HTTP 200" "$(yes_no "$home_code" "200")"
if grep -q "Cloud Build Tracker" "$HOME_BODY"; then
  check "index.html contains the tracker title" "yes"
else
  check "index.html contains the tracker title" "no"
fi

page_404_code="$(curl -sS -o "$PAGE_404_BODY" -w '%{http_code}' "${OBJECT_ROOT}/404.html" || true)"
check "404.html returns HTTP 200" "$(yes_no "$page_404_code" "200")"
if grep -q "drifted off into the cloud" "$PAGE_404_BODY"; then
  check "404.html is the custom page" "yes"
else
  check "404.html is the custom page" "no"
fi

miss_code="$(curl -sS -o "$MISS_BODY" -w '%{http_code}' "${OBJECT_ROOT}/does-not-exist" || true)"
check "a missing object returns HTTP 404" "$(yes_no "$miss_code" "404")"

root_code="$(curl -sS -o "$ROOT_BODY" -w '%{http_code}' "$API_ROOT" || true)"
if [[ "$root_code" == "200" ]] && grep -q "ListBucketResult" "$ROOT_BODY"; then
  check "bucket root lists objects (index page needs a custom domain)" "yes"
else
  check "bucket root lists objects (index page needs a custom domain)" "no"
fi

if project_exists; then
  project_lifetime="$(gcloud projects describe "$GCP_PROJECT_ID" --format="value(labels.lifetime)")"
  project_owner="$(gcloud projects describe "$GCP_PROJECT_ID" --format="value(labels.owner)")"
  project_name="$(gcloud projects describe "$GCP_PROJECT_ID" --format="value(labels.project)")"
  project_created="$(gcloud projects describe "$GCP_PROJECT_ID" --format="value(labels.created)")"
else
  project_lifetime=""
  project_owner=""
  project_name=""
  project_created=""
fi
check "project label lifetime=1d" "$(yes_no "$project_lifetime" "$LIFETIME_LABEL")"
check "project label owner=zeon" "$(yes_no "$project_owner" "$OWNER_LABEL")"
check "project label project=${PROJECT_LABEL}" "$(yes_no "$project_name" "$PROJECT_LABEL")"
check "project label created is set" "$([[ -n "$project_created" ]] && echo yes || echo no)"

if gcloud storage buckets describe "gs://${BUCKET_NAME}" --project="$GCP_PROJECT_ID" >/dev/null 2>&1; then
  bucket_row="$(gcloud storage buckets describe "gs://${BUCKET_NAME}" --project="$GCP_PROJECT_ID" \
    --format="csv[no-heading](website_config.mainPageSuffix,website_config.notFoundPage,labels.lifetime,labels.owner,labels.project,labels.created)")"
  IFS=',' read -r main_page error_page bucket_lifetime bucket_owner bucket_project bucket_created <<<"$bucket_row"
else
  main_page=""
  error_page=""
  bucket_lifetime=""
  bucket_owner=""
  bucket_project=""
  bucket_created=""
fi
check "bucket website index is index.html" "$(yes_no "$main_page" "index.html")"
check "bucket website error page is 404.html" "$(yes_no "$error_page" "404.html")"
check "bucket label lifetime=1d" "$(yes_no "$bucket_lifetime" "$LIFETIME_LABEL")"
check "bucket label owner=zeon" "$(yes_no "$bucket_owner" "$OWNER_LABEL")"
check "bucket label project=${PROJECT_LABEL}" "$(yes_no "$bucket_project" "$PROJECT_LABEL")"
check "bucket label created is set" "$([[ -n "$bucket_created" ]] && echo yes || echo no)"

echo
echo "$PASS passed, $FAIL failed"
if [[ "$FAIL" != "0" ]]; then
  exit 1
fi
