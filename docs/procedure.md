# Hands-on procedure — Noble testnet Jenkins CI

Chronological walkthrough of the steps to get a working Docker-build → ECR-push pipeline for `nobled` (Noble testnet `grand-1`). Includes the gotchas we hit and how they were resolved, so a future-you (or anyone repeating this) can avoid the same dead ends.

Paired references: see [architecture.md](architecture.md) for the topology + pipeline flow, and [purposes.md](purposes.md) for "why each step exists."

---

## 1. AWS prerequisites

1. AWS account with admin access (used in `us-east-1` here).
2. Note your **12-digit Account ID** — top-right of console, under your username.
3. **Create the ECR repo** (Elastic Container Registry → Private registry → Repositories → Create):
   - Visibility: Private
   - Namespace: `cosmos`, repo name: `nobled` → full URI becomes `<acct>.dkr.ecr.us-east-1.amazonaws.com/cosmos/nobled`
   - Image tag mutability: Mutable
4. **Create an IAM user** (IAM → Users → Create user):
   - Name: `jenkins` (anything works)
   - Uncheck "Provide user access to the AWS Management Console" — programmatic only
   - Permissions: Attach `AmazonEC2ContainerRegistryFullAccess` directly
5. **Generate access key** for that user (Security credentials tab → Create access key → "Application running outside AWS"). **Download the CSV or copy both values immediately** — the secret is shown once.

---

## 2. Launch the Jenkins EC2

EC2 → Launch instance:

- **Name**: `jenkins-controller`
- **AMI**: Ubuntu Server 22.04 LTS, **64-bit (x86)**
- **Instance type**: `m7i-flex.large` (2 vCPU / 8 GiB RAM). The 8 GiB is non-negotiable — `make install` + `golangci-lint` + Docker build all spike RAM.
- **Key pair**: create or reuse one (`cosmos.pem` in our case). After download, `chmod 400 ~/.ssh/cosmos.pem`.
- **Network settings → Edit**:
  - VPC: default; auto-assign public IP: **Enable**
  - Create security group `jenkins-sg` with inbound rules **from My IP only**:
    - SSH (22)
    - Custom TCP 8080 (Jenkins web UI)
    - Custom TCP 50000 (future Jenkins agents)
- **Storage**: 1× 30 GiB gp3 root volume (the 8 GiB default fills up immediately with Docker layers + Go module cache).
- **Advanced details → User data**: paste **all** of `scripts/userdata/jenkins-setup.sh` (verified URLs/versions as of 2026-05).
- Launch.

Boot + userdata install takes ~8-10 min.

---

## 3. Connect to Jenkins

SSH:
```
ssh -i ~/.ssh/cosmos.pem ubuntu@<jenkins-ec2-public-ip>
```

Verify userdata finished and tools are present:
```
bash scripts/userdata/verify-jenkins-host.sh
```
Expect `cloud-init status: done`, Jenkins + Docker `active (running)`, version strings for JDK 21, Go 1.24.x, golangci-lint, gosec, Trivy, AWS CLI v2.

Get the initial admin password:
```
sudo cat /var/lib/jenkins/secrets/initialAdminPassword
```

Open `http://<public-ip>:8080`, paste it.

---

## 4. Initial Jenkins setup

1. "Customize Jenkins" → **Install suggested plugins**. Wait ~3-5 min.
2. Create first admin user (username/password/email of your choice).
3. Instance Configuration → leave default Jenkins URL → Save and Finish.

### Add AWS-specific plugins
Manage Jenkins → Plugins → Available plugins. Search and install:
- **AWS Credentials** (required — pipeline uses `AmazonWebServicesCredentialsBinding`)
- **Docker Pipeline** (recommended)

---

## 5. Add Jenkins credentials

Manage Jenkins → Credentials → System → Global credentials → Add Credentials.

**Credential 1: AWS Account ID** (Secret text)
- ID: `aws-account-id`
- Secret: 12-digit account ID (no spaces/dashes)

**Credential 2: AWS access key** (AWS Credentials kind — the option appears because we installed the AWS Credentials plugin)
- ID: `aws-ecr`
- Access Key ID + Secret Access Key from Step 1.5

(Slack webhook is optional and intentionally not configured — the Jenkinsfile's post-actions handle its absence gracefully.)

---

## 6. Pipeline job

Dashboard → New Item → name `nobled-ci`, type **Pipeline** → OK.

### First run: inline script (to debug fast)
- Definition: **Pipeline script**
- Paste contents of `jenkins/Jenkinsfile`
- Save → Build Now

### Once pipeline succeeds: switch to SCM
After everything works end-to-end, flip to SCM-based so the Jenkinsfile + Dockerfile + scripts are all version-controlled together:

- Definition: **Pipeline script from SCM**
- SCM: Git
- Repository URL: `https://github.com/keerthi-chandan/jenkins-cosmos-build.git`
- Credentials: (none — public repo)
- **Branches to build: `*/main`** (NOT `*/master` — see gotcha below)
- **Script Path: `jenkins/Jenkinsfile`**
- Save → Build Now

---

## 7. Gotchas we hit (and how we fixed each)

These are why the first few builds failed. Worth remembering for next time / future portfolio repos.

### G1 — Jenkins signing key URL is stale in the course materials
**Symptom**: `Package 'jenkins' has no installation candidate`, preceded by `NO_PUBKEY 7198F4B714ABFC68`.

**Cause**: course userdata fetches `jenkins.io-2023.key`. The 2023 key file still exists on the server (returns 200) but holds stale content that no longer matches the repo's current signing key.

**Fix**: use `jenkins.io-2026.key` (per current official docs at `jenkins.io/doc/book/installing/linux/`). Our `scripts/userdata/jenkins-setup.sh` does this and also falls back to a keyserver lookup if the URL ever serves a non-PGP file.

### G2 — Jenkins LTS now requires JDK 21, not 17
**Symptom**: Jenkins package available but won't start, or refuses install with Java version error.

**Cause**: current Jenkins LTS dropped JDK 17 support.

**Fix**: install `openjdk-21-jdk` in userdata (already in our script). Course material's JDK 17 line is outdated.

### G3 — `make: not found` in Build stage
**Symptom**: `script.sh.copy: 1: make: not found` at the Build stage.

**Cause**: my first version of `jenkins-setup.sh` didn't install `build-essential` (just curl/wget/git/jq), so `make`/`gcc` weren't on the host.

**Fix**: add `build-essential` to the apt install list (already patched in our script).

### G4 — `golangci-lint v1.x` rejects projects with `go 1.24` in `go.mod`
**Symptom**: `Error: can't load config: the Go language version (go1.23) used to build golangci-lint is lower than the targeted Go version (1.24)`.

**Cause**: golangci-lint refuses to lint Go code targeting a newer version than the linter's own build toolchain. v1.62.x was built with Go 1.23. nobled requires `go 1.24`.

**Fix**: upgrade to v2.x (we used v2.12.2 built with Go 1.26). v2.x has a new config format but no `.golangci.yml` in nobled to break against, so the upgrade was clean.

### G5 — `golangci-lint` `install.sh` has stale checksums for recent v2.x
**Symptom**: `hash_sha256_verify checksum for ... did not verify`, install aborts, old version stays.

**Cause**: the `install.sh` helper in master hadn't been updated with the v2.12.2 hash yet.

**Fix**: bypass the helper. Download the tarball directly from the GitHub releases page, untar, `install -m 0755 ... /usr/local/bin/`. Our `jenkins-setup.sh` now does this for all versions.

### G6 — Lint, gosec, and Trivy find real issues in *upstream* code
**Symptom**: Lint reports 5 errcheck/staticcheck findings; Trivy reports 25 + 21 HIGH/CRITICAL CVEs.

**Cause**: we're scanning upstream code (Noble + Cosmos SDK transitive deps + debian base image) that we don't own. The findings are real but we can't fix them.

**Fix**: make all three stages **report-only** so the output is visible but doesn't block the pipeline. For Lint: `--issues-exit-code 0`. For gosec: `-no-fail`. For Trivy: `--exit-code 0`. For real-prod remediation later: bump base image, bump Go toolchain, use `.trivyignore` for reviewed CVEs.

### G7 — Slack post-actions fail when `slack-webhook` credential isn't configured
**Symptom**: `CredentialNotFoundException: Could not find credentials entry with ID 'slack-webhook'`, post-action errors after the pipeline otherwise finishes.

**Cause**: `withCredentials` throws if the named credential doesn't exist, even inside a post-action.

**Fix**: wrap the Slack lookup in a Groovy `try { withCredentials(...) { ... } } catch (Exception e) { echo "Slack notify skipped" }`. The pipeline now degrades gracefully — Slack works if the cred is configured, silently skipped otherwise.

### G8 — `Dockerfile not found` when `docker build .` runs in pipeline
**Symptom**: `failed to read dockerfile: open Dockerfile: no such file or directory`.

**Cause**: with the **inline-script** pipeline mode, the workspace only contains what the Checkout stage `git clone`s (i.e. the noble repo). The Dockerfile lived on the Mac, not on the Jenkins host.

**Fix (intermediate)**: scp the Dockerfile to `/var/lib/jenkins/Dockerfile`, `cp` it into workspace at the start of the Docker Build stage.

**Fix (final)**: switch to "Pipeline script from SCM" — Jenkins clones this repo before running the Jenkinsfile, so both Jenkinsfile **and** Dockerfile end up in the workspace naturally. We then point `docker build -f jenkins/Dockerfile`.

### G9 — SCM-based job tries to fetch `*/master`
**Symptom**: `fatal: couldn't find remote ref refs/heads/master` when Jenkins tries to clone the SCM repo.

**Cause**: Jenkins's Git plugin defaults branches to `*/master`. Our repo's default branch is `main`.

**Fix**: in the job config, change "Branches to build" to `*/main`.

---

## 8. Verify success

After the pipeline succeeds (10 green stages, ~20 sec with caches warmed):

```
aws ecr list-images --repository-name cosmos/nobled --region us-east-1
```
Or AWS console → ECR → `cosmos/nobled` → Images tab.

Pull and run from anywhere:
```
aws ecr get-login-password --region us-east-1 \
  | docker login --username AWS --password-stdin <acct>.dkr.ecr.us-east-1.amazonaws.com
docker pull <acct>.dkr.ecr.us-east-1.amazonaws.com/cosmos/nobled:<build-number>
docker run --rm <acct>.dkr.ecr.us-east-1.amazonaws.com/cosmos/nobled:<build-number> version
```

---

## 9. Teardown

End of session:

```
# Stop (preserve disk + caches for next time, ~$2.50/mo for the 30 GB EBS)
AWS console → EC2 → select jenkins-controller → Actions → Instance state → Stop instance

# Or fully terminate (no recurring cost, lose Jenkins config + caches)
AWS console → EC2 → select jenkins-controller → Actions → Instance state → Terminate instance
```

When restarting later (if stopped):
- Public IP changes — use the new one to SSH / open the Jenkins UI
- Everything else (Jenkins config, credentials, plugins, job, Go module cache, Docker layers) persists on the EBS volume
- `Build Now` works first try

If terminated, redo from Step 2 — userdata + Jenkins setup + credentials + job. ~20 min from cold to green build.

---

## 10. What this pipeline does NOT do (yet)

- **Deploy the image** anywhere. The image sits in ECR. The course's next section (AWS ECS) wires this up.
- **Lint blocking** on issues in our own code. We made it report-only for upstream-code reasons; flip to blocking for code we own.
- **Run a real Noble node**. The separate `scripts/userdata/noble-node-setup.sh` bare-metal flow does that — independent of the pipeline. The pipeline → bare-metal connection is what ECS replaces.
