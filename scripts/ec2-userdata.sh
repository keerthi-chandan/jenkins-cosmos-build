#!/bin/bash
set -e

# system + deps
apt-get update
apt-get install -y build-essential git wget curl make openjdk-17-jre

# Go
GO_VERSION=1.23.4
cd /tmp
wget -q https://golang.org/dl/go${GO_VERSION}.linux-amd64.tar.gz
tar -C /usr/local -xzf go${GO_VERSION}.linux-amd64.tar.gz
echo 'export PATH=$PATH:/usr/local/go/bin' > /etc/profile.d/go.sh

# swap (t3.micro RAM is tight for Cosmos builds)
fallocate -l 2G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab

# Jenkins
wget -qO /usr/share/keyrings/jenkins.asc https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key
echo "deb [signed-by=/usr/share/keyrings/jenkins.asc] https://pkg.jenkins.io/debian-stable binary/" \
    > /etc/apt/sources.list.d/jenkins.list
apt-get update
apt-get install -y jenkins
systemctl enable jenkins
systemctl start jenkins
