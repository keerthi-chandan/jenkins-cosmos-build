# jenkins-cosmos-build

End-to-end **CI + CD** for the Noble Cosmos chain. Jenkins on EC2 builds `nobled` from source, tests it, packages it into a Docker image, scans it, pushes to AWS ECR, then rolls out to an ECS Fargate service.

## Chain

Noble testnet — `nobled` (`v11.1.0-rc.1`).

## Setup

Two EC2s — a Jenkins controller and an SSH-attached build agent labelled `cosmos-builder`. The Jenkinsfile is `agent none` with every stage pinned to that label, so the agent must be online before the first build.

1. Launch the **controller** EC2 with [`scripts/userdata/jenkins-setup.sh`](scripts/userdata/jenkins-setup.sh) as user data (installs JDK 21 + Jenkins LTS).
2. Launch the **agent** EC2 with [`scripts/userdata/jenkins-agent-setup.sh`](scripts/userdata/jenkins-agent-setup.sh) as user data (installs Go, Docker, golangci-lint, gosec, Trivy, AWS CLI).
3. SSH-key the controller into the agent (controller's `jenkins` user → agent's `jenkins` user via `authorized_keys`).
4. In Jenkins: install AWS Credentials plugin, add `aws-account-id` + `aws-ecr` + `ssh-agent-key` credentials, register the agent as a node with label `cosmos-builder`.
5. Create a Pipeline job pointing at this repo's `jenkins/Jenkinsfile` on branch `main`, then Build.

Verify scripts: [`verify-jenkins-host.sh`](scripts/userdata/verify-jenkins-host.sh) on the controller, [`verify-jenkins-agent.sh`](scripts/userdata/verify-jenkins-agent.sh) on the agent.

## How the pipeline works

Jenkins controller dispatches each stage to an SSH agent labelled `cosmos-builder`. Slack post-actions run on the controller so notifications still fire if the agent dies.

**CI stages:**

1. **Checkout** — shallow clone of Noble at the pinned `NOBLE_VERSION`.
2. **Build** — `make install` produces `nobled` into `$GOPATH/bin`.
3. **Test** — `go test ./... -timeout 15m`.
4. **Lint** — `golangci-lint` (report-only on upstream code).
5. **Security (gosec)** — static analysis (report-only).
6. **Docker Build** — builds image from `jenkins/Dockerfile`, tagged with `BUILD_NUMBER`.
7. **Trivy Scan** — HIGH/CRITICAL CVE report (report-only on upstream base + deps).
8. **ECR Push** — pushes the image to `cosmos/nobled:<build#>` in AWS ECR.

**CD stage:**

9. **ECS Deploy** — reads the current `nobled-smoke` task definition, patches in the new image tag, registers a new revision, calls `update-service` on `nobled-smoke-service` in `nobled-cluster`, and `aws ecs wait services-stable` blocks until the rollout succeeds (build fails otherwise).

The ECS service is intentionally a **smoke deploy** — it proves the freshly-built image actually boots on AWS. Real stateful node deployment (snapshot restore, persistent peers, persistent volumes) is out of scope for this repo and a better fit for Kubernetes StatefulSets.

## AWS resources

- **ECR repo:** `cosmos/nobled` — stores tagged images.
- **ECS cluster:** `nobled-cluster` (Fargate).
- **ECS service:** `nobled-smoke-service` — keeps 1 task of `nobled-smoke` running.
- **IAM user:** `jenkins` — scoped to `RegisterTaskDefinition`, `UpdateService` on the one service, and `PassRole` for `ecsTaskExecutionRole` only. Bootstrap/listing is done with a separate admin identity (deploy bots get least privilege).

## Stack

Jenkins LTS (JDK 21), Go 1.24, Docker, Trivy, golangci-lint, gosec, AWS CLI v2 — on Ubuntu 24.04 LTS EC2s. Targets AWS EC2 + ECR + ECS Fargate + CloudWatch Logs.
