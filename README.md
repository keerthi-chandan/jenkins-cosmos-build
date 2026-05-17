# jenkins-cosmos-build

Jenkins on EC2 builds Cosmos SDK chain binaries from source.

## Chains

- Babylon testnet — `babylond`
- Celestia Mocha testnet — `celestia-appd`
- Noble testnet — `nobled`

## Setup

1. Launch a t3.micro EC2 with [`scripts/ec2-userdata.sh`](scripts/ec2-userdata.sh) as user data — see [docs/ec2-setup.md](docs/ec2-setup.md).
2. Unlock Jenkins, install suggested plugins + Go plugin — [docs/jenkins-install.md](docs/jenkins-install.md).
3. Register Go in Global Tool Config — [docs/tools-config.md](docs/tools-config.md).
4. Create a Pipeline job, paste [`jenkins/Jenkinsfile`](jenkins/Jenkinsfile), build.

## How the pipeline works

One parameterized job, pick a chain from the dropdown. Stages:

1. **Checkout & Pin** — Groovy map resolves chain → repo/version/daemon, persisted via `env.*` so later stages can read them.
2. **Build** — `make install` produces the chain binary into `$GOPATH/bin`.
3. **Verify & Lint** (parallel) — `sha256sum` the binary + record version; `go vet ./...` on the chain source. Runs concurrently to save wall-clock time.
4. **Smoke Test** — `daemon init` against a throwaway home, assert genesis/config files exist. Wrapped in `timeout` + `retry`.
5. **Archive** — tar the binary + checksum, attach to the build via `archiveArtifacts` (Jenkins' built-in artifact store).
6. **Approval Gate** — `input` step, capped by `timeout`, so a build can pause for manual promotion without pinning an executor forever.
7. **Post** — `success` / `failure` / `always` blocks for notification + workspace cleanup.

Build pattern is the same one used in chain Dockerfiles at work.

## Stack

Jenkins (LTS), Go 1.23.4, Ubuntu 22.04, AWS EC2.
