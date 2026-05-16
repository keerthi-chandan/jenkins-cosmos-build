# Jenkins Install

1. Get the admin password:
   ```bash
   sudo cat /var/lib/jenkins/secrets/initialAdminPassword
   ```
2. Open `http://<ec2-ip>:8080`, paste password.
3. Install suggested plugins.
4. Add the **Go** plugin: Manage Jenkins → Plugins → Available → search `Go` → install.
5. Create admin user.

Done. Next: `tools-config.md`.
