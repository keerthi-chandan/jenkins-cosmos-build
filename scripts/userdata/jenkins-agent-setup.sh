#!/bin/bash

# EC2 userdata for the Jenkins **build agent** ("cosmos-builder") in the Noble
# hands-on pipeline. Pairs with the controller provisioned by jenkins-setup.sh.
#
# What this host runs:
#   - Every Jenkinsfile build stage: Checkout, Build, Test, Lint, Security
#     (gosec), Docker Build, Trivy Scan, ECR Push — all pinned to
#     `label 'cosmos-builder'`.
#   - The `docker image prune` cleanup in the post { always } block.
#
# What this host does NOT run:
#   - The Jenkins server itself. That's on the controller. The controller
#     SSHes in here and launches `agent.jar` over the JVM (hence JDK 21 is still
#     required even though we don't install the Jenkins package).
#
# Toolchain installed (each is used by at least one pipeline stage):
#   - Docker          → Docker Build, Trivy Scan, ECR Push
#   - Go              → Build (`make install`), Test (`go test`)
#   - golangci-lint   → Lint
#   - gosec           → Security
#   - Trivy           → Trivy Scan
#   - AWS CLI v2      → ECR Push
#
# A local `jenkins` user is created with home /var/lib/jenkins so PATH/GOPATH
# in the Jenkinsfile (`GOPATH=/var/lib/jenkins/go`) resolve identically here
# and on the controller. ~/.ssh/authorized_keys is pre-created for the
# controller's public key (see step 3 of docs/procedure.md).

GO_VERSION=${GO_VERSION:-"1.24.13"}
GOLANGCI_LINT_VERSION=${GOLANGCI_LINT_VERSION:-"v2.12.2"}
GOSEC_VERSION=${GOSEC_VERSION:-"v2.21.4"}
TRIVY_VERSION=${TRIVY_VERSION:-"0.70.0"}

check_error() {
    if [ $? -ne 0 ]; then
        echo "ERROR: $1"
        exit 1
    fi
}

# Base packages
echo "Installing base packages..."
sudo apt update && sudo apt upgrade -y
sudo apt install -y build-essential curl wget git jq unzip ca-certificates gnupg lsb-release software-properties-common
check_error "Failed installing base packages."

# JDK 21 (matches controller; required to run agent.jar)
echo "Installing JDK 21..."
sudo apt install -y fontconfig openjdk-21-jdk
check_error "Failed installing JDK."

# Docker (build stages produce the nobled image here, not on the controller)
echo "Installing Docker..."
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin
check_error "Failed installing Docker."
sudo systemctl enable docker
sudo systemctl restart docker

# `jenkins` user — home matches the controller so /var/lib/jenkins/go works as GOPATH
echo "Creating jenkins user (home /var/lib/jenkins)..."
sudo useradd --system --create-home --home-dir /var/lib/jenkins --shell /bin/bash jenkins || true
sudo usermod -aG docker jenkins
sudo mkdir -p /var/lib/jenkins/.ssh
sudo touch /var/lib/jenkins/.ssh/authorized_keys
sudo chmod 700 /var/lib/jenkins/.ssh
sudo chmod 600 /var/lib/jenkins/.ssh/authorized_keys
sudo chown -R jenkins:jenkins /var/lib/jenkins

# Go
echo "Installing Go..."
sudo rm -rvf /usr/local/go/
wget https://golang.org/dl/go$GO_VERSION.linux-amd64.tar.gz
sudo tar -C /usr/local -xzf go$GO_VERSION.linux-amd64.tar.gz
rm go$GO_VERSION.linux-amd64.tar.gz
echo 'export PATH=$PATH:/usr/local/go/bin:/var/lib/jenkins/go/bin' | sudo tee /etc/profile.d/go.sh
sudo chmod +x /etc/profile.d/go.sh

# golangci-lint
echo "Installing golangci-lint $GOLANGCI_LINT_VERSION..."
GOLANGCI_VER_NUM=${GOLANGCI_LINT_VERSION#v}
cd /tmp
wget -q "https://github.com/golangci/golangci-lint/releases/download/${GOLANGCI_LINT_VERSION}/golangci-lint-${GOLANGCI_VER_NUM}-linux-amd64.tar.gz"
tar -xzf "golangci-lint-${GOLANGCI_VER_NUM}-linux-amd64.tar.gz"
sudo install -m 0755 "golangci-lint-${GOLANGCI_VER_NUM}-linux-amd64/golangci-lint" /usr/local/bin/golangci-lint
rm -rf "golangci-lint-${GOLANGCI_VER_NUM}-linux-amd64"*
cd -
check_error "Failed installing golangci-lint."

# gosec
echo "Installing gosec $GOSEC_VERSION..."
curl -sSfL https://raw.githubusercontent.com/securego/gosec/master/install.sh \
    | sudo sh -s -- -b /usr/local/bin $GOSEC_VERSION
check_error "Failed installing gosec."

# Trivy
echo "Installing Trivy $TRIVY_VERSION..."
wget https://github.com/aquasecurity/trivy/releases/download/v$TRIVY_VERSION/trivy_${TRIVY_VERSION}_Linux-64bit.deb
sudo dpkg -i trivy_${TRIVY_VERSION}_Linux-64bit.deb
rm trivy_${TRIVY_VERSION}_Linux-64bit.deb
check_error "Failed installing Trivy."

# AWS CLI v2 — ECR push stage runs on the agent, so it needs the CLI here, not on the controller
echo "Installing AWS CLI v2..."
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
unzip -q awscliv2.zip
sudo ./aws/install
rm -rf awscliv2.zip aws/
check_error "Failed installing AWS CLI."

echo "Setup complete."
echo
echo "Next steps — follow docs/procedure.md §3-7 for the full flow. Summary:"
echo "  1. On the CONTROLLER, generate a keypair as the jenkins user:"
echo "       sudo -u jenkins ssh-keygen -t ed25519 -f /var/lib/jenkins/.ssh/id_ed25519 -N ''"
echo "       sudo cat /var/lib/jenkins/.ssh/id_ed25519.pub      # copy this"
echo "  2. On THIS agent (as ubuntu via SSH), paste the controller's public key:"
echo "       echo '<paste-pub-key-here>' | sudo tee -a /var/lib/jenkins/.ssh/authorized_keys"
echo "       sudo chown jenkins:jenkins /var/lib/jenkins/.ssh/authorized_keys"
echo "  3. In Jenkins UI: Manage Jenkins -> Credentials -> add 'ssh-agent-key'"
echo "     (SSH Username with private key; user 'jenkins'; paste the PRIVATE key from step 1)"
echo "  4. In Jenkins UI: Manage Jenkins -> Nodes -> New Node 'cosmos-builder'"
echo "     - Remote root directory: /var/lib/jenkins"
echo "     - Labels: cosmos-builder"
echo "     - Launch method: Launch agents via SSH"
echo "       Host: <this agent's private IP>"
echo "       Credentials: ssh-agent-key"
echo "       Host Key Verification Strategy: Non verifying (lab) or Manually trusted (prod)"
