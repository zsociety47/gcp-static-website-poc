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

WEB_URL="http://${BUCKET_NAME}.storage.googleapis.com/"
HOME_BODY="$(mktemp)"
MISS_BODY="$(mktemp)"
trap 'rm -f "$HOME_BODY" "$MISS_BODY"' EXIT

echo "Checking $WEB_URL"
echo

home_code="$(curl -sS -o "$HOME_BODY" -w '%{http_code}' "$WEB_URL" || true)"
check "home page returns HTTP 200" "$(yes_no "$home_code" "200")"
if grep -q "Cloud Build Tracker" "$HOME_BODY"; then
  check "home page contains the tracker title" "yes"
else
  check "home page contains the tracker title" "no"
fi

miss_code="$(curl -sS -o "$MISS_BODY" -w '%{http_code}' "${WEB_URL}does-not-exist" || true)"
check "a missing page returns HTTP 404" "$(yes_no "$miss_code" "404")"
if grep -q "drifted off into the cloud" "$MISS_BODY"; then
  check "the 404 body is the custom page" "yes"
else
  check "the 404 body is the custom page" "no"
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
    --format="csv[no-heading](website.mainPageSuffix,website.notFoundPage,labels.lifetime,labels.owner,labels.project,labels.created)")"
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
