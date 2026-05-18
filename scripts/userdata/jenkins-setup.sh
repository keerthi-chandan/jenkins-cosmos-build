#!/bin/bash

# EC2 userdata for the Jenkins controller used by the Noble hands-on pipeline.
# Provisions: JDK 17, Jenkins, Docker, Go, golangci-lint, gosec, Trivy, AWS CLI v2.

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

# JDK 21 (current Jenkins LTS requires Java 21+)
echo "Installing JDK 21..."
sudo apt install -y fontconfig openjdk-21-jdk
check_error "Failed installing JDK."

# Jenkins (current 2026-stamped signing key per jenkins.io/doc/book/installing/linux/)
echo "Installing Jenkins..."
sudo mkdir -p /etc/apt/keyrings
sudo wget -O /etc/apt/keyrings/jenkins-keyring.asc \
    https://pkg.jenkins.io/debian-stable/jenkins.io-2026.key
if ! file /etc/apt/keyrings/jenkins-keyring.asc | grep -q 'PGP public key'; then
    echo "Key URL did not return a PGP key; falling back to keyserver..."
    sudo rm -f /etc/apt/keyrings/jenkins-keyring.asc
    sudo gpg --no-default-keyring \
        --keyring /etc/apt/keyrings/jenkins-keyring.gpg \
        --keyserver keyserver.ubuntu.com \
        --recv-keys 7198F4B714ABFC68
    sudo chmod 644 /etc/apt/keyrings/jenkins-keyring.gpg
    JENKINS_KEYRING=/etc/apt/keyrings/jenkins-keyring.gpg
else
    JENKINS_KEYRING=/etc/apt/keyrings/jenkins-keyring.asc
fi
echo "deb [signed-by=${JENKINS_KEYRING}] https://pkg.jenkins.io/debian-stable binary/" \
    | sudo tee /etc/apt/sources.list.d/jenkins.list > /dev/null
sudo apt update
sudo apt install -y jenkins
check_error "Failed installing Jenkins."
sudo systemctl enable jenkins
sudo systemctl start jenkins

# Docker
echo "Installing Docker..."
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin
check_error "Failed installing Docker."
sudo usermod -aG docker jenkins
sudo systemctl enable docker
sudo systemctl restart docker

# Go
echo "Installing Go..."
sudo rm -rvf /usr/local/go/
wget https://golang.org/dl/go$GO_VERSION.linux-amd64.tar.gz
sudo tar -C /usr/local -xzf go$GO_VERSION.linux-amd64.tar.gz
rm go$GO_VERSION.linux-amd64.tar.gz
echo 'export PATH=$PATH:/usr/local/go/bin:/var/lib/jenkins/go/bin' | sudo tee /etc/profile.d/go.sh
sudo chmod +x /etc/profile.d/go.sh

# golangci-lint (direct download; install.sh has stale checksums for recent v2.x releases)
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

# AWS CLI v2 (for ECR login from pipeline)
echo "Installing AWS CLI v2..."
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
unzip -q awscliv2.zip
sudo ./aws/install
rm -rf awscliv2.zip aws/
check_error "Failed installing AWS CLI."

# Restart Jenkins so it picks up the docker group + tool paths
sudo systemctl restart jenkins

echo "Setup complete."
echo "Jenkins URL:    http://<this-ec2-public-ip>:8080"
echo "Initial admin password is at: /var/lib/jenkins/secrets/initialAdminPassword"
echo "Run: sudo cat /var/lib/jenkins/secrets/initialAdminPassword"
