#!/bin/bash

# EC2 userdata for the Jenkins **controller** in the Noble hands-on pipeline.
#
# What this host runs:
#   - Jenkins server (UI, job scheduler, credentials store, plugin registry).
#   - Slack post-action curl calls — they run on the 'built-in' node so that a
#     notification still goes out if the build agent itself is the thing that
#     failed (see Jenkinsfile's `post { success / failure }` blocks).
#
# What this host does NOT run (pipeline-wise):
#   - Build, test, lint, gosec, docker build, Trivy scan, ECR push. All eight
#     build stages are pinned to `label 'cosmos-builder'` in the Jenkinsfile and
#     execute on the agent EC2 provisioned by jenkins-agent-setup.sh.
#
# Hence: install only what the Jenkins server needs (base packages + JDK 21 +
# the Jenkins package). Docker / Go / golangci-lint / gosec / Trivy / AWS CLI
# all live on the agent, not here.

check_error() {
    if [ $? -ne 0 ]; then
        echo "ERROR: $1"
        exit 1
    fi
}

# Base packages
echo "Installing base packages..."
sudo apt update && sudo apt upgrade -y
sudo apt install -y curl wget git ca-certificates gnupg lsb-release software-properties-common file
check_error "Failed installing base packages."

# JDK 21 (current Jenkins LTS requires Java 21+ — JDK 17 will install but not run)
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

echo "Setup complete."
echo "Jenkins URL:    http://<this-ec2-public-ip>:8080"
echo "Initial admin password is at: /var/lib/jenkins/secrets/initialAdminPassword"
echo "Run: sudo cat /var/lib/jenkins/secrets/initialAdminPassword"
