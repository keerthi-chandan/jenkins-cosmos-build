#!/bin/bash

# Verifies that the Jenkins **build agent** EC2 (provisioned by
# jenkins-agent-setup.sh) has the full pipeline toolchain plus the `jenkins`
# user and SSH inbox the controller needs.
# Run on the agent after userdata finishes.
#
# Pairs with verify-jenkins-host.sh (for the controller).

# Load Go's PATH if the current shell hasn't yet
if [ -f /etc/profile.d/go.sh ]; then
    source /etc/profile.d/go.sh
fi

echo "=== cloud-init (was userdata done?) ==="
cloud-init status

echo
echo "=== JDK (needed to run agent.jar) ==="
java -version

echo
echo "=== Docker ==="
sudo systemctl status docker --no-pager | head -5
docker --version

echo
echo "=== Go ==="
go version

echo
echo "=== golangci-lint ==="
golangci-lint --version

echo
echo "=== gosec ==="
gosec -version 2>&1 | head -3

echo
echo "=== Trivy ==="
trivy --version | head -3

echo
echo "=== AWS CLI ==="
aws --version

echo
echo "=== jenkins user + SSH inbox ==="
if id jenkins >/dev/null 2>&1; then
    getent passwd jenkins | awk -F: '{print "  user: "$1"  uid: "$3"  home: "$6"  shell: "$7}'
else
    echo "  jenkins user MISSING — useradd in jenkins-agent-setup.sh failed"
fi
if [ -f /var/lib/jenkins/.ssh/authorized_keys ]; then
    KEY_COUNT=$(sudo wc -l < /var/lib/jenkins/.ssh/authorized_keys)
    echo "  authorized_keys present ($KEY_COUNT line(s))"
    if [ "$KEY_COUNT" -eq 0 ]; then
        echo "  WARN: file is empty — paste controller's pubkey before adding the node in Jenkins"
    fi
else
    echo "  /var/lib/jenkins/.ssh/authorized_keys MISSING"
fi

echo
echo "=== docker group membership (jenkins user must be in 'docker' to docker build) ==="
groups jenkins 2>/dev/null | grep -q docker \
    && echo "  ok — jenkins is in the docker group" \
    || echo "  WARN: jenkins user is NOT in the docker group — docker build will fail with permission denied"
