# Why each step exists

A purpose-by-purpose reference for the hands-on, so each click/command has a clear reason behind it.

---

## Phase 1 — Infrastructure foundation

| Step | Purpose |
|---|---|
| Launch EC2 for Jenkins | Jenkins needs a server. EC2 is the simplest way to get one in AWS. |
| Pick Ubuntu 22.04 AMI | Most-documented Linux base for Jenkins. Free, common in real-world setups. |
| Pick `m7i-flex.large` (8 GiB RAM) | Jenkins (Java) + Go compile + golangci-lint are memory-hungry. Anything smaller OOMs during build. |
| SG rule: SSH/22 from My IP | So you can SSH in. Restricted to your IP so the world can't brute-force it. |
| SG rule: 8080 from My IP | Jenkins web UI port. Restricted so randoms can't try to exploit Jenkins. |
| SG rule: 50000 from My IP | If you ever add separate Jenkins build agents, they connect to the controller on 50000. Pre-opening saves a step later. |
| 30 GiB gp3 storage | Jenkins workspace + Docker image layers + Go module cache add up; 8 GiB default fills fast. |
| Userdata script | Auto-installs Jenkins/Docker/Go/linters/Trivy/AWS CLI on boot — saves manually running ten `apt install` lines. |
| Initial admin password | Jenkins's anti-hijack mechanism — proves you have shell access on the box before you can configure Jenkins. |

## Phase 2 — Jenkins setup

| Step | Purpose |
|---|---|
| "Install suggested plugins" | Gives you Pipeline, Git, Credentials Binding, Timestamper — basic plumbing every pipeline needs. |
| Create admin user | Replaces the throwaway bootstrap password with a real login you'll use going forward. |
| Add "AWS Credentials" plugin | Our Jenkinsfile uses `withCredentials([$class: 'AmazonWebServicesCredentialsBinding', ...])` — that exact step only exists if this plugin is installed. |
| Add "Docker Pipeline" plugin | Lets the pipeline interact with Docker (we use plain `sh docker build` so it's not strictly required, but useful and standard). |

## Phase 3 — AWS resources for the pipeline

| Step | Purpose |
|---|---|
| Create ECR repo `cosmos/nobled` | The Docker image we build needs somewhere to live. ECR is AWS's container registry — equivalent to Docker Hub but private and IAM-controlled. |
| Create IAM user `jenkins` | Jenkins needs AWS credentials to push to ECR. Best practice: a dedicated user with *only* the perms it needs — never use your root account's keys. |
| Attach `AmazonEC2ContainerRegistryFullAccess` | Minimum permissions for that user to create/pull/push to any ECR repo in this account. (In real prod you'd scope it tighter to one repo.) |
| Generate access key + secret | Programmatic credentials — the equivalent of a username+password but for API/CLI use. Jenkins uses these to call AWS. |

## Phase 4 — Wire AWS into Jenkins

| Credential | Purpose |
|---|---|
| `aws-account-id` (Secret text) | The Jenkinsfile composes the ECR URI as `${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/...`. Storing the account ID as a credential keeps it out of the Jenkinsfile so the Jenkinsfile can be committed to a public repo without leaking your account. |
| `aws-ecr` (AWS Credentials) | The access key + secret that Jenkins injects into the `ECR Push` stage via `aws ecr get-login-password`. |

**Pattern:** secrets stay in Jenkins; the Jenkinsfile only references them by ID. Never hardcode keys.

## Phase 5 — Pipeline

| Step | Purpose |
|---|---|
| Create Pipeline job | A job in Jenkins is a configurable thing-to-run. We pick the "Pipeline" type so Jenkins runs our Jenkinsfile (not a freestyle GUI-configured job). |
| Paste Jenkinsfile into the job | The Jenkinsfile *is* the pipeline — code defining stages: Checkout → Build → Test → Lint → gosec → Docker Build → Trivy Scan → ECR Push. |
| Build Now | First execution. Validates everything we've set up: AWS creds work, build tools work, ECR push works, image scan works. If something's misconfigured, this is where it surfaces. |

---

## Each Jenkinsfile stage — what it does + why

| Stage | What it does | Why we keep it |
|---|---|---|
| **Checkout** | `git clone --depth 1 --branch v11.1.0-rc.1` of `strangelove-ventures/noble` | Pipeline needs source code to build from. Pinned to a specific tag so builds are reproducible. |
| **Build** | `make install` — compiles `nobled` binary | Catches build breakage early (faster feedback than discovering it during deploy). |
| **Test** | `go test ./...` | Runs upstream Cosmos SDK unit tests. If they fail in your build env, something's off with your toolchain or deps. |
| **Lint** | `golangci-lint run` | Static analysis: catches unused vars, dead code, ineffective assignments — code smells that pile up over time. |
| **Security (gosec)** | `gosec ./...` | Go-specific security scanner: catches hardcoded creds, weak crypto, unsafe SQL builders, etc. |
| **Docker Build** | `docker build` using multistage Dockerfile | Packages the `nobled` binary into a minimal runtime image (debian-slim) suitable for deployment. |
| **Trivy Scan** | `trivy image --severity HIGH,CRITICAL --exit-code 1` | Scans the built image for known CVEs in the base image or installed packages. Fails the build if any are HIGH/CRITICAL. |
| **ECR Push** | `aws ecr get-login-password` → `docker push` | Delivers the validated image to ECR so other things (ECS, EKS, plain `docker pull`) can use it. |
| **post { success/failure }** | Posts to Slack via curl | Notifies on outcome. Optional — silently no-ops if `slack-webhook` cred isn't configured. |

---

## Tools installed by `jenkins-setup.sh` — why each

| Tool | Why |
|---|---|
| `openjdk-21-jdk` | Current Jenkins LTS requires Java 21+ to run. |
| `jenkins` (Debian repo) | The CI server itself. |
| Docker | Needed to build and push Docker images from the pipeline. Daemon must be on the host — Jenkins can't install it via Tool Configuration. |
| Go 1.24.13 | Required to build `nobled` (its `go.mod` specifies `go 1.24`). Matches Noble's go.mod. |
| golangci-lint v1.62.2 | Industry-standard Go linter. Used by the `Lint` stage. |
| gosec v2.21.4 | Go security scanner. Used by the `Security` stage. |
| Trivy 0.70.0 | Container CVE scanner. Used by the `Trivy Scan` stage. |
| AWS CLI v2 | Needed to call `aws ecr get-login-password` for ECR push. |

---

## The Dockerfile — why multistage

```
Stage 1 (builder):  golang:1.24.13-bookworm
   - Install build deps (git, make, gcc)
   - Clone noble at v11.1.0-rc.1
   - Run `make install`
   - Produces binary in /go/bin/nobled

Stage 2 (runtime):  debian:bookworm-slim
   - COPY the binary from stage 1
   - Add minimal runtime deps (ca-certificates, curl, jq, lz4)
   - Run as non-root user `cosmos`
   - Expose Cosmos node ports (26656, 26657, 1317, 9090)
```

**Why multistage:** the final image doesn't need the Go toolchain, only the binary. Stage 1 pulls hundreds of MB of build tooling and Go modules; Stage 2 only ships ~80 MB of runtime. Smaller image = faster pulls, smaller attack surface, fewer CVEs to scan.

---

## Why two parallel artifacts (Docker image + bare-metal node)

The pipeline produces a **Docker image in ECR**. The bare-metal EC2 (separate, runs the userdata script we already have) runs **`nobled` as a systemd service** from source.

These aren't connected on purpose — yet. The "spin up a real node and watch it sync" part stays bare-metal for now because:
1. The course hasn't yet taught deploying to ECS (that's the next section).
2. The bare-metal pattern matches what's in your day-job's template script.
3. We get to see the pipeline produce an image AND see a node actually run — without coupling them prematurely.

When the course gets to AWS ECS, we'll wire the ECR image to an ECS task and drop the bare-metal node. The pipeline doesn't change — only the deploy target.
