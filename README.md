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

One job, pick a chain from the dropdown. Bash case statement sets the repo / version / daemon vars, then `git clone → git checkout → make install → daemon version`.

Build pattern is the same one I use in chain Dockerfiles at work.

## Stack

Jenkins (LTS), Go 1.23.4, Ubuntu 22.04, AWS EC2.
