#!/bin/bash

# Verifies that everything jenkins-setup.sh installs is present and working.
# Run on the Jenkins EC2 after userdata finishes.

# Load Go's PATH if the current shell hasn't yet
if [ -f /etc/profile.d/go.sh ]; then
    source /etc/profile.d/go.sh
fi

echo "=== cloud-init (was userdata done?) ==="
cloud-init status

echo "=== Jenkins ==="
sudo systemctl status jenkins --no-pager | head -5

echo "=== Docker ==="
sudo systemctl status docker --no-pager | head -5
docker --version

echo "=== JDK ==="
java -version

echo "=== Go ==="
go version

echo "=== golangci-lint ==="
golangci-lint --version

echo "=== gosec ==="
gosec -version 2>&1 | head -3

echo "=== Trivy ==="
trivy --version | head -3

echo "=== AWS CLI ==="
aws --version
