# Google Cloud Static Website Proof of Concept

## Watch the build

Video not recorded yet. The thumbnail and the link go here after the recording.

<!-- [![Watch the video](docs/images/loom-thumbnail.gif)](LOOM_LINK) -->

**Live page:** [index.html](https://storage.googleapis.com/staticweb-poc-zeon01/index.html) · **Author:** Zeon Stewart, [LinkedIn](LINKEDIN_LINK_HERE)

## At a glance

- **What it is:** a website that runs directly from Google Cloud Storage, with no server to rent, patch, or keep running.
- **Business problem:** a small business needs a public website that is fast, cheap, and has nothing to maintain.
- **What's automated:** scripts create the project and the bucket, check the public address, and delete the project. A push to `main` uploads the pages.
- **Why it's secure:** no key file is stored in this repository. GitHub signs in with Workload Identity Federation. Visitors can read the pages. They cannot change the bucket.
- **Result:** `verify.sh` printed `16 passed, 0 failed` on October 26, 2026. The home page is the object address above. The bucket root lists file names instead of serving `index.html`, because Google applies the index and 404 pages only on a custom domain.

Part of [Cloud Projects](https://github.com/zsociety47/cloud-projects). Technical details are in [Technical findings](#technical-findings) at the bottom.

---

## Project Steps

These steps build the site by hand in the [Google Cloud console](https://console.cloud.google.com). Doing it by hand once shows what each piece is. The [automated setup](#automated-setup) then does the same thing with scripts. Each step names the script line that automates it.

Copy `.env.example` to `.env` first and pick a project id and a bucket name. Both have to be unique across Google Cloud, not just in your account. Use those names wherever this page says `<project-id>` and `<bucket-name>`.

Opening `https://storage.googleapis.com/<bucket-name>/index.html` returns the page over HTTPS (Hypertext Transfer Protocol Secure). Opening the bucket root, `http://<bucket-name>.storage.googleapis.com/`, returns an XML list of file names. Google applies `index.html` and `404.html` only when a custom domain points at the bucket. This proof does not add that domain, and it does not add a load balancer. A load balancer costs money while it sits idle.

Screenshots are not taken yet. Each image line stays commented out until the file exists. The shot list is in the private notes.

### Step 1: Create a project

*Automated by `gcloud projects create` in `scripts/deploy.sh`.*

1. Open the project picker and select **New project**.
2. **Project name:** `static website poc`
3. **Project ID:** `<project-id>` (the value of `GCP_PROJECT_ID` in `.env`)
4. Select **Create**.
5. Add these four labels. A label value cannot contain a colon, so the time uses hyphens: `2026-10-26t17-30-00z`.
   - `lifetime` = `1d`
   - `owner` = `zeon`
   - `project` = `01-gcp-static-website-poc`
   - `created` = the time you created it, in that hyphen form

<!-- ![Project page with the four labels](docs/images/step-01-project.png) -->

### Step 2: Link billing

*Automated by `gcloud billing projects link` in `scripts/deploy.sh`.*

Cloud Storage will not turn on until a billing account is linked. Linking it makes charges possible if usage leaves the free tier. A site this size, in `us-east1`, should stay at $0.

1. Open **Billing** and link your billing account to `<project-id>`.
2. Do not copy the billing account id into the repository, a screenshot, or a commit.

<!-- ![Billing linked, with the account id cropped out](docs/images/step-02-billing.png) -->

### Step 3: Create the bucket

*Automated by `gcloud storage buckets create` in `scripts/deploy.sh`.*

1. Search for **Cloud Storage** and select **Buckets**, then **Create**.
2. **Name:** `<bucket-name>`
3. **Location:** `us-east1` (Region). This region is in the Cloud Storage free tier. `us-east4` is not.
4. **Storage class:** Standard
5. **Access control:** Uniform. This means one identity and access management (IAM) policy for the whole bucket, not a separate list on each file.
6. **Public access prevention:** off. The site has to be readable by people who are not signed in.
7. **Soft delete:** off (duration 0). Deleted files are not kept, so they cannot add a storage charge.
8. Add the same four labels as the project.

<!-- ![Bucket details: us-east1, Standard, uniform access, public access prevention off](docs/images/step-03-bucket.png) -->

### Step 4: Set the index page and the missing-page file

*Automated by `gcloud storage buckets update --web-main-page-suffix --web-error-page` in `scripts/deploy.sh`.*

1. Open the bucket and find **Website configuration**.
2. **Index page:** `index.html`
3. **Error page:** `404.html`
4. Save.

<!-- ![Website configuration with index.html and 404.html](docs/images/step-04-website.png) -->

### Step 5: Let anyone read the objects

*Automated by `gcloud storage buckets add-iam-policy-binding` in `scripts/deploy.sh`.*

1. Open the bucket's **Permissions** tab and select **Grant access**.
2. **Principal:** `allUsers`
3. **Role:** Storage Object Viewer (`roles/storage.objectViewer`)
4. Confirm the public-access warning.

This role lets a visitor open a file. It also lets a visitor list the file names in the bucket. The Azure site does not list names from its website address. That difference is recorded in [Google Cloud and Azure](#google-cloud-and-azure).

<!-- ![Permissions tab: allUsers has Storage Object Viewer](docs/images/step-05-public-read.png) -->

### Step 6: Upload the site files

*Automated by `gcloud storage rsync --delete-unmatched-destination-objects` in `scripts/deploy.sh`.*

1. Open the bucket's **Objects** tab and upload the files in `site/`.
2. `index.html` and `404.html` have to be at the top of the bucket, not inside a folder.

The script also deletes a cloud file when that file is gone from `site/`. A plain upload does not.

<!-- ![Objects list with index.html and 404.html](docs/images/step-06-upload.png) -->

### Step 7: Open the site

1. Open `https://storage.googleapis.com/<bucket-name>/index.html`. The home page loads.
2. Open `https://storage.googleapis.com/<bucket-name>/404.html`. The custom missing-page file loads.
3. Open `http://<bucket-name>.storage.googleapis.com/`. The response is an XML list of the file names, not the home page. That is the documented behavior on this host.

<!-- ![The live home page over HTTP](docs/images/step-07-live-site.png) -->
<!-- ![The custom 404 page](docs/images/step-07-404.png) -->

### Step 8: Run the check

*This is `scripts/verify.sh`.*

```bash
./scripts/verify.sh
```

The last line should be `16 passed, 0 failed`.

<!-- ![verify.sh printing 16 passed, 0 failed](docs/images/step-08-verify.png) -->

### Step 9: Clean up when you're done

```bash
./scripts/teardown.sh
```

Type the project id when it asks. That deletes the bucket and the project. Nothing is deleted if the name you type does not match.

The nightly sweep is a different file, `cloud-projects/environment-control/envctl-gcp.sh`. It deletes Google Cloud projects labeled `lifetime=1d` that are at least an hour old. It does not ask you to type the name. This project's teardown script is the one that asks.

A deleted project id cannot be reused until Google finishes the delete, which can take 30 days. Pick a new `GCP_PROJECT_ID` in `.env` for the next build.

<!-- ![Teardown script listing the project and the bucket, and asking for the project id](docs/images/step-09-teardown.png) -->

### Screenshots still to take

- `docs/images/step-01-project.png`
- `docs/images/step-02-billing.png` (crop the billing account id)
- `docs/images/step-03-bucket.png`
- `docs/images/step-04-website.png`
- `docs/images/step-05-public-read.png`
- `docs/images/step-06-upload.png`
- `docs/images/step-07-live-site.png`
- `docs/images/step-07-404.png`
- `docs/images/step-08-verify.png`
- `docs/images/step-09-teardown.png`

---

## Automated setup

The same build as the Project Steps. Nothing here creates a resource until you run `deploy.sh`.

**Prerequisites:** the Google Cloud command-line interface (CLI), signed in with `gcloud auth login`, and a billing account you are allowed to link. `curl` is used by the check.

**1. Save the names locally**

```bash
cp .env.example .env
```

Fill in `GCP_BILLING_ACCOUNT`. Leave the other three values unless the project id or the bucket name is already taken. Do not commit `.env`.

**2. Create the project, the bucket, and the site** (steps 1-7)

```bash
./scripts/deploy.sh
```

The script prints the site address. Re-running it reuses the project only if that project already has this proof's labels.

**3. Check it** (step 8)

```bash
./scripts/verify.sh
```

**4. Let GitHub upload on push**

```bash
./scripts/setup-wif.sh
```

This creates a free identity for this repository. It does not create a key. After it saves the GitHub values, a push to `main` runs `.github/workflows/deploy.yml`, which signs in and uploads `site/`. The first push is the check that this works.

**5. Tear it down** (step 9)

```bash
./scripts/teardown.sh
```

The prompt names the bucket, the identity pool, the service account, and the GitHub values. Deleting the project removes the pool and the service account. The script removes the GitHub values by name.

---

## Architecture

The design picture is not drawn yet. When this build is finished, redraw it on the design canvas and export `docs/architecture/architecture.png` and `docs/architecture/architecture.pdf`. That picture is the reference. The diagram below is the live map, and it changes with the scripts.

```mermaid
flowchart TD
    user["Visitor's browser"]
    dev["deploy.sh<br/>on your laptop"]
    gha["GitHub Actions<br/>push to main"]

    subgraph proj["staticweb-poc-zeon01 · Google Cloud project"]
        bucket["staticweb-poc-zeon01<br/>Cloud Storage bucket"]
        web["index.html · 404.html"]
    end

    user -- "HTTPS" --> web
    dev -. "gcloud storage rsync" .-> bucket
    gha -. "Workload Identity Federation" .-> bucket
    bucket --> web

    classDef gcp fill:#1a73e8,stroke:#174ea6,color:#fff
    classDef external fill:#6e7681,stroke:#484f58,color:#fff

    class bucket,web gcp
    class user,dev,gha external
```

**How to read this diagram**

- **Solid arrow:** how a visitor reaches the site.
- **Dashed arrow:** how the files get there.
- **Blue:** Google Cloud resources. The shared diagram standard uses Azure blue for Azure resources. This cloud uses Google blue (`#1a73e8`) for its own resources. **Gray:** outside the cloud (the visitor and the laptop).

*A visitor reads a page over HTTPS at its object address. `deploy.sh` and a push to `main` both upload `site/` with `gcloud storage rsync`. There is no key file in the repository.*

The names in the diagram are the examples in `.env.example`. If you change `.env`, change this diagram in the same commit.

*Diagram follows the [shared diagram standard](https://github.com/zsociety47/cloud-projects/blob/main/standards/DIAGRAM-STANDARD.md), with the resource color changed for this cloud.*

---

## Google Cloud and Azure

Same idea, different names. The Azure proof is [azure-static-website-poc](https://github.com/zsociety47/azure-static-website-poc).

| Idea | Azure | Google Cloud |
|---|---|---|
| Where the files live | Storage account `ststaticwebpoczeon01` | Bucket `staticweb-poc-zeon01` |
| What groups the resources | Resource group `rg-staticweb-poc-zeon01` | Project `<project-id>`. Deleting the project deletes what is inside it |
| How the site is turned on | Static website on the `$web` container | Website configuration: index suffix and error page |
| Public address | `https://<account>.z13.web.core.windows.net` serves the index page | `https://storage.googleapis.com/<bucket>/index.html` serves the file. The bucket root lists names |
| HTTPS on that address | Yes, on the website address | Yes, on the object address. The index and 404 settings still need a custom domain |
| Who can read | The website endpoint serves the pages. Anonymous listing of the container stays off | `allUsers` with Storage Object Viewer. That role can also list object names |
| Who can upload | Storage Blob Data Contributor, separate from Owner | The signed-in user, for the scripts. The workflow uses service account `gh-staticweb-poc` with Storage Object Admin on this bucket only |
| Upload command | `az storage blob upload-batch` adds and overwrites. A deleted page stays live | `gcloud storage rsync --delete-unmatched-destination-objects` removes a cloud file when the local file is gone |
| Marks for cleanup | Tags. `created` can contain a colon | Labels. `created` uses `2026-10-26t17-30-00z` because a colon is not allowed |
| Name after delete | The resource group name can be reused | The project id cannot be reused until the delete finishes, which can take 30 days |
| Region | East US | `us-east1`, because that region is in the storage free tier |
| Deploy from GitHub with no stored password | OpenID Connect (OIDC) and a federated credential | Workload Identity Federation. A push to `main` uploads `site/`. No key file |

---

## Hypothesis

A small public website can be hosted from a Google Cloud Storage bucket, with an index page and a missing-page file set on the bucket. A push to `main` can upload the pages with no stored key, and a script can remove the project.

## Success criteria

| # | Criterion | How it is checked | Result |
|---|-----------|-------------------|--------|
| 1 | `index.html` loads over HTTPS from its object address | `verify.sh` on October 26, 2026 | ✅ |
| 2 | The home page is the tracker page | `verify.sh` found `Cloud Build Tracker` | ✅ |
| 3 | `404.html` is public, and a missing object returns HTTP 404 | `verify.sh` | ✅ |
| 4 | The bucket's website settings name `index.html` and `404.html` | `verify.sh` read `website_config` | ✅ |
| 5 | The project and the bucket carry `lifetime`, `owner`, `project`, and `created` | `verify.sh` read the labels | ✅ |
| 6 | No key file or billing account id is stored in the repository | `.env` is gitignored. `git status` does not list it | ✅ |
| 7 | The bucket root lists object names instead of serving the index page | `verify.sh` found `ListBucketResult` | ✅ |
| 8 | The project and the bucket are removed by `teardown.sh`, and only if the labels match | Run teardown and type the project id | not checked yet |
| 9 | A push to `main` uploads `site/` with no key file | The GitHub Actions run for that push | not checked yet |
| 10 | The deploy identity can write objects in this bucket only | Bucket policy lists Storage Object Admin for `gh-staticweb-poc`. The project policy lists no role for that account. Checked October 26, 2026 | ✅ |

## What's in this repository

```
.
├── site/                 The pages. Copied from the Azure proof so the two hosts can be compared
├── scripts/
│   ├── deploy.sh         Creates the project and the bucket, sets the website, uploads site/
│   ├── setup-wif.sh      Lets GitHub Actions upload with no key file
│   ├── verify.sh         Prints a pass or fail line for each check
│   ├── teardown.sh       Lists the bucket, the identity, and the GitHub values, then deletes them after you type the project id
│   └── lib/
│       └── config.sh     Loads .env and refuses to touch a project this proof did not label
├── .github/
│   ├── workflows/
│   │   └── deploy.yml    Uploads site/ on a push to main
│   └── dependabot.yml    Weekly check for new GitHub Action versions
├── .env.example          The names. Copy to .env. Never commit .env
└── docs/
    └── images/           Screenshots, added after they are taken
```

## Security choices

- **No key file.** The scripts use `gcloud auth login`. The workflow uses Workload Identity Federation. `.env` holds the project id and the billing account id, and `.gitignore` keeps that file out of git. The provider resource name is a GitHub secret because it contains the project number.
- **One bucket policy.** Uniform bucket-level access is on, so a file cannot carry a different access list than the bucket.
- **Public read is deliberate.** `allUsers` has Storage Object Viewer because a public website has to be readable without a sign-in. That role can also list object names. Say that out loud when you show the permissions page.
- **The scripts will not touch a stranger's project.** If the project id already exists and it does not have this proof's labels, `deploy.sh` stops. `teardown.sh` does the same before it deletes anything.

## Cost

The project itself is free. Linking a billing account is what makes charges possible.

Cloud Storage has a free monthly allowance in `us-east1`, `us-central1`, and `us-west1`: 5 GB of Standard storage, 5,000 class A operations, 50,000 class B operations, and about 1 GB of outbound traffic from North America. A site this size should stay inside that allowance. Confirm the current free-tier page before you leave the bucket up for a long time.

Soft delete is off, so a removed file is not kept and billed.

This proof does not create Cloud CDN (content delivery network) or an HTTPS load balancer. A global external Application Load Balancer charges for a forwarding rule all month, on the order of $18, even with no visitors. Do not turn that on for this proof.

`teardown.sh` removes the bucket and asks Google to delete the project. The nightly sweep `envctl-gcp.sh` does the same for any project labeled `lifetime=1d` that is at least an hour old, without asking you to type the name.

## Going further

- **HTTPS on a custom domain.** Put a load balancer and a certificate in front of the bucket. Do it only when the monthly forwarding-rule charge is acceptable. The object address is already HTTPS.
- **List names or not.** A custom role with only `storage.objects.get` would let visitors open a page without listing every file name.

---

## Technical findings

*Known before the first create. Errors from the real run get appended here with the exact text.*

- **The index and 404 settings do not apply on `storage.googleapis.com`.** After the first deploy, `http://staticweb-poc-zeon01.storage.googleapis.com/` returned HTTP 200 with `Content-Type: application/xml` and a `ListBucketResult` body. `does-not-exist` returned `NoSuchKey`. `gcloud storage buckets describe` still showed `website_config.mainPageSuffix=index.html` and `notFoundPage=404.html`. Google's documentation says those two settings are used only for requests that arrive through a CNAME or an A record. The pages themselves are public at `https://storage.googleapis.com/staticweb-poc-zeon01/index.html` and `404.html`. `verify.sh` checks those object addresses, and it also checks that the bucket root is still the object list.
- **The first verify looked at the wrong field name.** `gcloud storage buckets describe --format=json` calls the website block `website_config`, not `website`. The check now reads `website_config`.
- **A project id is single-use for a long time.** `gcloud projects delete` starts a shutdown. Google's docs say the id cannot be reused until that shutdown finishes, and shutdown can take 30 days. The Azure resource group name can be reused as soon as the delete completes. `.env` is where the id lives so the next build can use a new one without editing the scripts.
- **Label values cannot contain a colon.** The nightly sweep already accepts `2026-10-26t17-30-00z` for that reason. The scripts write `created` in that form.
- **`roles/storage.objectViewer` includes list.** Granting it to `allUsers` makes the site public and also makes the object names public. The scripts use it because that is the role Google's website guide names. The tighter role is listed under Going further.
- **Upload removes stale files on purpose.** The Azure upload command only adds and overwrites, and a deleted page stayed live. This pass uses `gcloud storage rsync` with `--delete-unmatched-destination-objects` from the start.
- **The scripts do not use the gcloud default project.** A default project was already set on this machine. Every command passes `--project`, and a missing `.env` stops the script.
