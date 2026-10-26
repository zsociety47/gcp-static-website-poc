#!/usr/bin/env bash
#
# Shared checks for deploy.sh, verify.sh, and teardown.sh.
# Loads .env, checks names, and refuses to touch a Google Cloud project
# that this proof did not label.

# Repo root is two levels up from scripts/lib/.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

PROJECT_LABEL="01-gcp-static-website-poc"
OWNER_LABEL="zeon"
LIFETIME_LABEL="1d"

load_env() {
  if [[ -f "$REPO_ROOT/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "$REPO_ROOT/.env"
    set +a
  fi
}

require_gcloud() {
  if ! command -v gcloud >/dev/null 2>&1; then
    echo "gcloud is not installed. Install the Google Cloud command-line interface (CLI), then run this again." >&2
    exit 1
  fi
}

require_login() {
  if ! gcloud auth list --filter="status:ACTIVE" --format="value(account)" 2>/dev/null | grep -q .; then
    echo "You are not signed in to Google Cloud. Run 'gcloud auth login' first." >&2
    exit 1
  fi
}

require_project_settings() {
  : "${GCP_PROJECT_ID:=}"
  : "${GCP_REGION:=}"
  : "${BUCKET_NAME:=}"

  if [[ -z "$GCP_PROJECT_ID" || -z "$GCP_REGION" || -z "$BUCKET_NAME" ]]; then
    echo "Copy .env.example to .env and set GCP_PROJECT_ID, GCP_REGION, and BUCKET_NAME." >&2
    exit 1
  fi

  if [[ ! "$GCP_PROJECT_ID" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]]; then
    echo "GCP_PROJECT_ID must be 6 to 30 characters, start with a letter, and use only lowercase letters, digits, and hyphens." >&2
    exit 1
  fi

  if [[ ! "$BUCKET_NAME" =~ ^[a-z0-9][a-z0-9_-]{1,61}[a-z0-9]$ ]]; then
    echo "BUCKET_NAME must be 3 to 63 characters and use only lowercase letters, digits, hyphens, and underscores." >&2
    exit 1
  fi

  if [[ ! "$GCP_REGION" =~ ^[a-z]+(-[a-z0-9]+)+$ ]]; then
    echo "GCP_REGION should look like us-east1. That region is in the Cloud Storage free tier. us-east4 is not." >&2
    exit 1
  fi
}

require_billing_account() {
  : "${GCP_BILLING_ACCOUNT:=}"
  if [[ ! "$GCP_BILLING_ACCOUNT" =~ ^[0-9A-Fa-f]{6}-[0-9A-Fa-f]{6}-[0-9A-Fa-f]{6}$ ]]; then
    echo "Set GCP_BILLING_ACCOUNT in .env to your billing account id. Do not commit that file." >&2
    exit 1
  fi
}

project_exists() {
  gcloud projects describe "$GCP_PROJECT_ID" --format="value(projectId)" >/dev/null 2>&1
}

# Returns 0 only when the bucket is in this project. An empty project label is
# allowed so a bucket can be removed if labeling failed halfway through.
# buckets describe does not include a project number, so membership is
# "this project lists this bucket".
assert_our_bucket() {
  local listed bucket_label
  listed="$(gcloud storage buckets list \
    --project="$GCP_PROJECT_ID" \
    --filter="name=${BUCKET_NAME}" \
    --format="value(name)")"
  bucket_label="$(gcloud storage buckets describe "gs://${BUCKET_NAME}" --format="value(labels.project)")"

  if [[ "$listed" != "$BUCKET_NAME" ]]; then
    echo "Refusing to touch gs://${BUCKET_NAME}: it is not in project ${GCP_PROJECT_ID}." >&2
    exit 1
  fi
  if [[ -n "$bucket_label" && "$bucket_label" != "$PROJECT_LABEL" ]]; then
    echo "Refusing to touch gs://${BUCKET_NAME}: its project label is not ${PROJECT_LABEL}." >&2
    exit 1
  fi
}

# Returns 0 only when the project carries this proof's three identity labels.
assert_our_project() {
  local project_label owner_label lifetime_label
  project_label="$(gcloud projects describe "$GCP_PROJECT_ID" --format="value(labels.project)")"
  owner_label="$(gcloud projects describe "$GCP_PROJECT_ID" --format="value(labels.owner)")"
  lifetime_label="$(gcloud projects describe "$GCP_PROJECT_ID" --format="value(labels.lifetime)")"

  if [[ "$project_label" != "$PROJECT_LABEL" || "$owner_label" != "$OWNER_LABEL" || "$lifetime_label" != "$LIFETIME_LABEL" ]]; then
    echo "Refusing to touch project $GCP_PROJECT_ID." >&2
    echo "It does not carry project=$PROJECT_LABEL, owner=$OWNER_LABEL, and lifetime=$LIFETIME_LABEL." >&2
    echo "Pick a different GCP_PROJECT_ID in .env, or delete that project yourself if it is an empty one you just made." >&2
    exit 1
  fi
}

label_csv() {
  local created="$1"
  printf 'lifetime=%s,owner=%s,project=%s,created=%s' \
    "$LIFETIME_LABEL" "$OWNER_LABEL" "$PROJECT_LABEL" "$created"
}

# New projects often reject the next call for a minute. Retry only the errors
# that mean "not ready yet". Anything else is printed and stops the script.
run_until_ready() {
  local waited=0
  local err=""
  until err="$("$@" 2>&1)"; do
    if ! printf '%s' "$err" | grep -Eiq 'not ready|being created|failed precondition|try again|backend error'; then
      printf '%s\n' "$err" >&2
      return 1
    fi
    if (( waited >= 180 )); then
      printf '%s\n' "$err" >&2
      echo "The project was still not ready after 3 minutes. Wait a minute and run this script again." >&2
      return 1
    fi
    printf '    Waiting for the project to become ready... (%ds)\n' "$waited"
    sleep 15
    waited=$((waited + 15))
  done
}
