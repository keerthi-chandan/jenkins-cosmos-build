# EC2 Setup

- AMI: Ubuntu 22.04 LTS
- Type: t3.micro (free tier)
- Storage: 20 GB gp3
- Security group: SSH 22 + 8080, both from my IP only
- User data: paste `scripts/ec2-userdata.sh`

After ~3 min, SSH in and check:

```bash
sudo systemctl status jenkins
/usr/local/go/bin/go version
```

Then continue to `jenkins-install.md`.
