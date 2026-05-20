#!/bin/bash

# Verifies that the Jenkins **controller** EC2 (provisioned by jenkins-setup.sh)
# is healthy. Run on the controller after userdata finishes.
#
# The controller only runs the Jenkins server itself — none of the build
# toolchain lives here. To verify the build agent, run verify-jenkins-agent.sh
# on the cosmos-builder EC2.

echo "=== cloud-init (was userdata done?) ==="
cloud-init status

echo
echo "=== Jenkins ==="
sudo systemctl status jenkins --no-pager | head -5

echo
echo "=== JDK ==="
java -version
