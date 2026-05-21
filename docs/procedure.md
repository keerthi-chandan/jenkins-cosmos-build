# Hands-on procedure — Noble testnet Jenkins CI

Chronological walkthrough of the steps to get a working Docker-build → ECR-push pipeline for `nobled` (Noble testnet `grand-1`). Includes the gotchas we hit and how they were resolved, so a future-you (or anyone repeating this) can avoid the same dead ends.

Paired references: see [architecture.md](architecture.md) for the topology + pipeline flow, and [purposes.md](purposes.md) for "why each step exists."

**Two EC2s are required:**
1. **Jenkins controller** — runs the Jenkins server (UI, job scheduler, credentials).
2. **Jenkins agent (`cosmos-builder`)** — runs the heavy work: `go build`, `docker build`, Trivy scan, ECR push.

The Jenkinsfile is declared `agent none` at the top, with every build stage pinned to `label 'cosmos-builder'`. A build will hang forever if the agent isn't registered, so both EC2s must exist before you click `Build Now`.

---

## 1. AWS prerequisites

**Purpose:** Create the AWS-side artifacts the pipeline writes to (ECR repo + IAM user with keys). Nothing else works without these.

1. AWS account with admin access (used in `us-east-1` here).
2. Note your **12-digit Account ID** — top-right of console, under your username.
3. **Create the ECR repo** (Elastic Container Registry → Private registry → Repositories → Create):
   - Visibility: Private
   - Namespace: `cosmos`, repo name: `nobled` → full URI becomes `<acct>.dkr.ecr.us-east-1.amazonaws.com/cosmos/nobled`
   - Image tag mutability: Mutable
4. **Create an IAM user** (IAM → Users → Create user):
   - Name: `jenkins` (anything works)
   - Uncheck "Provide user access to the AWS Management Console" — programmatic only
   - Permissions: Attach `AmazonEC2ContainerRegistryFullAccess` directly
5. **Generate access key** for that user (Security credentials tab → Create access key → "Application running outside AWS"). **Download the CSV or copy both values immediately** — the secret is shown once.

---

## 2. Launch the Jenkins controller EC2

**Purpose:** Stand up the box that hosts the Jenkins UI, scheduler, and credentials. Orchestrator only — no build work runs here.

EC2 → Launch instance:

- **Name**: `jenkins-controller`
- **AMI**: Ubuntu Server 22.04 LTS, **64-bit (x86)**
- **Instance type**: `m7i-flex.large` (2 vCPU / 8 GiB RAM). 8 GiB is the floor — Jenkins itself + plugins are RAM-hungry even though heavy build work now lives on the agent.
- **Key pair**: create or reuse one (`cosmos.pem` in our case). After download, `chmod 400 ~/.ssh/cosmos.pem`.
- **Network settings → Edit**:
  - VPC: default; auto-assign public IP: **Enable**
  - Create security group `jenkins-sg` with inbound rules **from My IP only**:
    - SSH (22)
    - Custom TCP 8080 (Jenkins web UI)
    - Custom TCP 50000 (Jenkins JNLP — still useful for future plain agents)
- **Storage**: 1× 30 GiB gp3 root volume.
- **Advanced details → User data**: paste **all** of `scripts/userdata/jenkins-setup.sh` (verified URLs/versions as of 2026-05).
- Launch.

Boot + userdata install takes ~8-10 min.

---

## 3. Launch the Jenkins agent EC2 (`cosmos-builder`)

**Purpose:** Stand up the worker box where the heavy lifting (`go build`, Docker, scans, ECR push) actually runs. Isolating it protects the controller from build crashes and RAM spikes.

EC2 → Launch instance:

- **Name**: `jenkins-agent-cosmos-builder`
- **AMI**: Ubuntu Server 22.04 LTS, **64-bit (x86)** (same as controller — keeps PATH/GOPATH identical).
- **Instance type**: `t3.medium` (2 vCPU / 4 GiB RAM). This is where `docker build` + Trivy live, so don't go smaller.
- **Key pair**: reuse `cosmos.pem` (or whatever you used for the controller — you'll SSH in once to paste the controller's public key).
- **Network settings → Edit**:
  - VPC: default; auto-assign public IP: **Enable** (only needed for your initial bootstrap SSH; can be disabled afterwards).
  - Create security group `jenkins-agent-sg` with inbound rules:
    - SSH (22) **from `jenkins-sg`** (source = the controller's SG, not from My IP) — this is how the controller reaches the agent to launch `agent.jar`.
    - SSH (22) from My IP — temporary, for the initial public-key paste. Remove once the controller can reach the agent.
- **Storage**: 1× 30 GiB gp3 root volume (Docker layer cache + Go module cache live here).
- **Advanced details → User data**: paste **all** of `scripts/userdata/jenkins-agent-setup.sh`.
- Launch.

Boot + userdata install takes ~6-8 min (no Jenkins package, but Go + Docker + Trivy + golangci-lint + gosec all install).

### Wire the controller's SSH key onto the agent

On the **controller** (after SSHing in), generate a keypair for the `jenkins` user that the controller will use to reach the agent:

```
sudo -u jenkins ssh-keygen -t ed25519 -f /var/lib/jenkins/.ssh/id_ed25519 -N ""
sudo cat /var/lib/jenkins/.ssh/id_ed25519.pub
```

Copy the printed public key. SSH to the **agent** (using `cosmos.pem` and ubuntu user), then append it to the jenkins user's authorized_keys:

```
ssh -i ~/.ssh/cosmos.pem ubuntu@<agent-public-ip>
sudo bash -c 'echo "<paste-pub-key-here>" >> /var/lib/jenkins/.ssh/authorized_keys'
sudo chown jenkins:jenkins /var/lib/jenkins/.ssh/authorized_keys
sudo chmod 600 /var/lib/jenkins/.ssh/authorized_keys
```

Confirm from the controller:

```
sudo -u jenkins ssh -o StrictHostKeyChecking=accept-new jenkins@<agent-private-ip> "hostname && whoami"
```

Expect the agent's hostname and `jenkins`. If this fails, the Jenkins node config in step 7 will also fail — fix it now.

---

## 4. Connect to Jenkins

**Purpose:** Confirm both EC2s booted cleanly and the Jenkins UI is reachable before touching anything inside it.

SSH to the controller:
```
ssh -i ~/.ssh/cosmos.pem ubuntu@<controller-public-ip>
```

Verify the controller is healthy:
```
bash scripts/userdata/verify-jenkins-host.sh
```
Expect `cloud-init status: done`, Jenkins `active (running)`, and a JDK 21 version string. The controller only runs the Jenkins server — Docker / Go / scan-tools / AWS CLI all live on the agent, not here, so the script intentionally doesn't check for them.

Then SSH to the agent and verify *its* toolchain:
```
ssh -i ~/.ssh/cosmos.pem ubuntu@<agent-public-ip>
bash scripts/userdata/verify-jenkins-agent.sh
```
Expect version strings for JDK 21, Docker, Go 1.24.x, golangci-lint v2.12.x, gosec, Trivy, AWS CLI v2. It also checks the things the controller relies on for the SSH launch:
- The `jenkins` user exists with home `/var/lib/jenkins`.
- `~/.ssh/authorized_keys` is present (will be empty until you paste the controller's pubkey in step 3 — that's expected on first run).
- The `jenkins` user is in the `docker` group (otherwise `docker build` fails with permission-denied at runtime).

> If you're running this against EC2s that were launched **before** the controller script was slimmed down, the controller will physically still have Docker/Go/Trivy/etc. installed (userdata only runs on first boot). That's harmless — they sit unused. The new verify script just stops reporting on them.

Get the initial admin password from the controller:
```
sudo cat /var/lib/jenkins/secrets/initialAdminPassword
```

Open `http://<controller-public-ip>:8080`, paste it.

---

## 5. Initial Jenkins setup

**Purpose:** Run Jenkins's first-run wizard and install the AWS / Docker / SSH plugins the pipeline depends on.

1. "Customize Jenkins" → **Install suggested plugins**. Wait ~3-5 min.
2. Create first admin user (username/password/email of your choice).
3. Instance Configuration → leave default Jenkins URL → Save and Finish.

### Add AWS-specific plugins
Manage Jenkins → Plugins → Available plugins. Search and install:
- **AWS Credentials** (required — pipeline uses `AmazonWebServicesCredentialsBinding`)
- **Docker Pipeline** (recommended)
- **SSH Build Agents** (usually preinstalled with "suggested plugins" — confirm it's there; without it you can't add the agent in step 7)

---

## 6. Add Jenkins credentials

**Purpose:** Store the AWS keys and agent SSH key in Jenkins's encrypted credential store so the Jenkinsfile can reference them by ID instead of hardcoding secrets.

Manage Jenkins → Credentials → System → Global credentials → Add Credentials.

**Credential 1: AWS Account ID** (Secret text)
- ID: `aws-account-id`
- Secret: 12-digit account ID (no spaces/dashes)

**Credential 2: AWS access key** (AWS Credentials kind — the option appears because we installed the AWS Credentials plugin)
- ID: `aws-ecr`
- Access Key ID + Secret Access Key from Step 1.5

**Credential 3: Agent SSH key** (SSH Username with private key)
- ID: `ssh-agent-key`
- Username: `jenkins`
- Private Key: **Enter directly** → paste the contents of `/var/lib/jenkins/.ssh/id_ed25519` from the controller (the *private* half of the keypair you generated in step 3). Get it with `sudo cat /var/lib/jenkins/.ssh/id_ed25519` on the controller.
- Passphrase: (none — we generated it with `-N ""`)

(Slack webhook is optional and intentionally not configured — the Jenkinsfile's post-actions handle its absence gracefully.)

---

## 7. Register the agent as a Jenkins node

**Purpose:** Tell the controller about the agent and how to SSH into it. Without this, every `label 'cosmos-builder'` stage hangs forever waiting for an executor.

Manage Jenkins → Nodes → New Node:

- **Node name**: `cosmos-builder`
- Type: **Permanent Agent** → Create
- **Number of executors**: `1`
- **Remote root directory**: `/var/lib/jenkins`
- **Labels**: `cosmos-builder` (must match `label 'cosmos-builder'` in Jenkinsfile)
- **Usage**: "Only build jobs with label expressions matching this node" (keeps the controller out of build work)
- **Launch method**: **Launch agents via SSH**
  - Host: `<agent-private-ip>` (private IP is reachable from the controller via the SG rule; using the public IP works too but costs a couple cents in cross-AZ traffic if you're unlucky)
  - Credentials: select `ssh-agent-key`
  - Host Key Verification Strategy: **Non verifying** for now (or "Manually trusted" if you want to paste in the agent's known_hosts entry — safer, more steps)
- **Availability**: "Keep this agent online as much as possible"
- Save.

Jenkins now connects to the agent and the node card should turn from grey/red → green within ~15 sec. If it stays red, check the "Log" link on the node page — 9 times out of 10 it's the SSH key or host-key strategy.

---

## 8. Pipeline job

**Purpose:** Create the Jenkins job that pulls the Jenkinsfile from this repo and dispatches each stage to the registered agent.

Dashboard → New Item → name `nobled-ci`, type **Pipeline** → OK.

The Jenkinsfile lives in this repo, so we go straight to SCM (the old inline-script debug path is no longer applicable — the Jenkinsfile references `jenkins/Dockerfile` by repo-relative path, which only exists once the repo is cloned into the workspace).

- Definition: **Pipeline script from SCM**
- SCM: Git
- Repository URL: `https://github.com/keerthi-chandan/jenkins-cosmos-build.git`
- Credentials: (none — public repo)
- **Branches to build: `*/main`** (NOT `*/master` — see gotcha G9 below)
- **Script Path: `jenkins/Jenkinsfile`**
- Save → Build Now

First green build should land all 10 stages, ~3-5 min cold, ~20 sec with caches warmed.

---

## 9. Verify success

**Purpose:** Prove the image actually landed in ECR and is pullable from outside the pipeline.

After the pipeline succeeds (10 green stages):

```
aws ecr list-images --repository-name cosmos/nobled --region us-east-1
```
Or AWS console → ECR → `cosmos/nobled` → Images tab.

Pull and run from anywhere:
```
aws ecr get-login-password --region us-east-1 \
  | docker login --username AWS --password-stdin <acct>.dkr.ecr.us-east-1.amazonaws.com
docker pull <acct>.dkr.ecr.us-east-1.amazonaws.com/cosmos/nobled:<build-number>
docker run --rm <acct>.dkr.ecr.us-east-1.amazonaws.com/cosmos/nobled:<build-number> version
```

---

## 10. Teardown

**Purpose:** Shut down both EC2s between sessions to stop paying for compute, without losing Jenkins state or the agent's toolchain.

End of session — stop **both** EC2s:

```
AWS console → EC2 → select jenkins-controller            → Actions → Instance state → Stop instance
AWS console → EC2 → select jenkins-agent-cosmos-builder  → Actions → Instance state → Stop instance
```

Stopping (rather than terminating) preserves both EBS volumes (~$5/mo total for the two 30 GB gp3 disks). All of this persists across stop/start:
- Controller: Jenkins config, credentials, plugins, job definitions, node registration.
- Agent: Go module cache, Docker layer cache, scan tool binaries.

### When restarting later (after stop):
- **Both** public IPs change. The controller's new public IP is what you SSH to and what you open in the browser.
- The agent's **private** IP usually also changes (it's not Elastic). The Jenkins node config in step 7 references the agent by IP/hostname → if the private IP changed, update it under Manage Jenkins → Nodes → cosmos-builder → Configure → Host. Otherwise the node will stay offline and you'll hit G10.
  - **Avoid this churn** by either (a) attaching an Elastic IP to the agent or (b) using the agent's private DNS name (`ip-10-0-x-x.ec2.internal`) — but the DNS name also changes when the private IP does, so EIP is the cleaner fix if you stop/start often.
- Restart both EC2s **before** clicking `Build Now`. The build will hang (G10) if the agent isn't up.

If terminated, redo from Step 2 — both EC2s + Jenkins setup + credentials + node registration + job. ~30 min from cold to green build.

---

## 11. What this pipeline does NOT do

- **Lint blocking** on issues in our own code. Currently report-only for upstream-code reasons; flip to blocking once we own the lint surface.
- **Run a real Noble node.** The smoke service in ECS just proves the image boots. A real syncing fullnode (persistent volume, snapshot restore, peers, exposed RPC) is a separate concern. `scripts/userdata/noble-node-setup.sh` provisions a bare-metal node for hands-on node-ops practice.
- **Auto-scale the agent.** Only one `cosmos-builder` node exists; concurrent builds queue. For real load, add a second agent EC2 with the same label, or use the EC2 Fleet plugin to spin agents on demand.

---

## 12. ECS deployment — plan

ECR push alone isn't deployment — the image just sits in the registry. The ECS deploy stage wires AWS Fargate up as the deploy target so each green build automatically rolls out a new `nobled-smoke-service` task.

Split into three phases, in this order:

1. **Phase 1 — Manual ECS setup in the AWS console** (~25 min). Stand up `nobled-cluster` + task definition + service running an existing ECR image. Confirms the AWS-side plumbing works *before* touching Jenkins. Walked through in §13.
2. **Phase 2 — IAM permissions for the Jenkins IAM user** (~5 min). The pipeline needs to register new task definition revisions and update services. A tight inline policy on the existing `jenkins` user covers it. Walkthrough in §14.
3. **Phase 3 — Add ECS Deploy stage to the Jenkinsfile** (~30 min). New stage after ECR Push that (a) describes the current task def, (b) patches the image field to the new build's tag, (c) registers as a new revision, (d) updates the service to that revision, (e) waits for `services-stable` so the build only goes green if the rollout actually succeeded. Production pattern: immutable image refs per revision. Walkthrough in §15.

**Workload chosen for the smoke test**: long-running ECS service running `sh -c "nobled version && sleep 3600"`. Container prints version, sleeps an hour, exits, gets restarted by ECS. No EFS, no networking, no chain sync — just proves the image works on ECS and that rolling deploys work end-to-end. Realistic Cosmos workloads (RPC fullnodes with EFS-backed chain state + ALB-exposed RPC) are deliberately out of scope here — they belong to a separate Kubernetes-based exercise.

---

## 13. Phase 1 — Manual ECS setup in the console

All steps in `us-east-1`. Bootstrap image: `cosmos/nobled:6` (substitute your latest green build number wherever you see `:6`).

### 13.1 — CloudWatch Log Group (~2 min)

CloudWatch → **Log groups** → **Create log group**
- Log group name: `/ecs/nobled-smoke`
- Retention: 1 week (cheap; we don't need forever)
- Create

*Why first*: the task definition will fail to register if you reference a log group that doesn't exist.

### 13.2 — IAM execution role (~3 min)

IAM → **Roles** → **Create role**
- Trusted entity: **AWS service**
- Use case: **Elastic Container Service** → **Elastic Container Service Task** (NOT "EC2 Container Service")
- Permissions: attach **`AmazonECSTaskExecutionRolePolicy`** (AWS managed)
- Role name: **`ecsTaskExecutionRole`** (this exact name — some AWS wizards expect it)
- Create

*Why this role*: ECS Fargate uses it to pull from ECR and write to CloudWatch Logs *on your behalf* **before** the container starts. It is **not** the role the container itself uses (that's "task role", different thing — we leave that blank since our smoke test container needs no AWS perms).

### 13.3 — ECS Cluster (~2 min)

**Purpose:** Create the logical container that will hold our service + tasks. Just a named bucket — no compute is reserved.

ECS → **Clusters** → **Create cluster**
- Cluster name: **`nobled-cluster`**
- Infrastructure: **AWS Fargate (serverless)** — leave checked; uncheck EC2 if it's on
- Tags: skip
- Create (takes ~1 min)

### 13.4 — Task Definition (~5 min) ⚠️ most landmines here

**Purpose:** Define the blueprint Fargate will use to run our container (which image, CPU/memory, command, logging). This is the versioned spec the pipeline will later patch and re-register on every deploy.

ECS → **Task definitions** → **Create new task definition** (use the "new" wizard, not the raw JSON editor for the first pass)

**Task definition configuration:**
- Family: **`nobled-smoke`**
- Launch type: **AWS Fargate**
- Operating system / Arch: **Linux/X86_64**
- Network mode: `awsvpc` (Fargate forces this)
- CPU: **0.25 vCPU**
- Memory: **0.5 GB**
- Task role: leave blank / `None` (container needs no AWS perms)
- Task execution role: **`ecsTaskExecutionRole`** (the one you just created)

**Container — 1:**
- Container name: **`nobled`**
- Image URI: **`<ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/cosmos/nobled:6`** (substitute your account ID + the build number you confirmed)
- Essential container: **Yes**
- Port mappings: **none** (smoke test, no networking needed)
- Resource limits / GPU: leave blank
- **Docker configuration** (expand):
  - Entry point: `sh,-c`
  - Command: `nobled version && sleep 3600`

⚠️ **Landmine — entrypoint vs command override**: The Dockerfile sets `ENTRYPOINT ["nobled"]` + `CMD ["start"]`. If you override only **Command**, the final invocation becomes `nobled sh -c "nobled version && sleep 3600"` — broken. You must override **both** Entry point AND Command so the final invocation resolves to `sh -c "nobled version && sleep 3600"`. The console's UI for these two fields is finicky — confirm both saved values after creating the task def.

- **Logging**: enable **Use log collection** → **CloudWatch**
  - Log group: select **`/ecs/nobled-smoke`** (must exist from step 14.1)
  - Region: `us-east-1`
  - Stream prefix: `nobled`

- Health check / environment / secrets: skip

- Create

You should now have **`nobled-smoke:1`** (revision 1).

### 13.5 — Service (~5 min)

**Purpose:** Tell ECS to keep N copies of the task running forever — restarts crashed tasks and handles rolling deploys. This is what the pipeline's `update-service` will target.

ECS → Clusters → **`nobled-cluster`** → **Services** tab → **Create**

- Environment: **Launch type → Fargate**, Platform version → `LATEST`
- **Application type: Service**
- Family: **`nobled-smoke`** (the task def family)
- Revision: `1` (latest)
- Service name: **`nobled-smoke-service`**
- Desired tasks: **1**
- **Networking**:
  - VPC: default
  - Subnets: pick the **2 default public subnets** (us-east-1a, us-east-1b)
  - Security group: create a new one called `nobled-smoke-sg` with **no inbound rules** (smoke test exposes nothing) and default outbound (all traffic out — needed to reach ECR)
  - **Public IP: TURNED ON** ⚠️ if this is off, Fargate can't reach ECR's public endpoint; task gets stuck PROVISIONING → STOPPED with `CannotPullContainerError`. Easiest mistake in this whole phase.
- Load balancing: **None** (smoke test, no incoming traffic)
- Service auto scaling: **off**
- Create

Service creation takes ~1-2 min. Then ECS will start trying to pull the image and launch the task.

### 13.6 — Verify (~3 min)

**Purpose:** Confirm the image actually boots on Fargate before we try to automate deploys to it.

1. Service → **Tasks** tab → wait ~1-2 min for a task to appear with status `RUNNING` (transitions PROVISIONING → PENDING → RUNNING).
2. Click the task → **Logs** tab → should see:
   ```
   name: nobled
   server_name: nobled
   version: v11.1.0-rc.1
   commit: ...
   build_tags: ...
   go: go version go1.24.X linux/amd64
   ```
3. Then the container sits in `sleep 3600` for an hour, exits 0, and ECS restarts it. Loops forever. Expected.

Phase 1 is **done** when CloudWatch logs show `version: v11.1.0-rc.1` on a running task. Then move to Phase 2 (§14).

---

## 14. Phase 2 — IAM permissions for the pipeline

The existing `jenkins` IAM user (created in §1.4 for ECR pushes) currently only has `AmazonEC2ContainerRegistryFullAccess`. For Phase 3's pipeline stage to register task definitions and update services, it also needs ECS permissions plus one specific `iam:PassRole`.

We'll use a **tight custom inline policy** (not the AWS-managed `AmazonECS_FullAccess`) — closer to production practice and a much better portfolio talking point than "I gave the user FullAccess and called it done."

### 14.1 — Create inline policy (~3 min)

**Purpose:** Grant the `jenkins` IAM user the exact ECS + PassRole permissions the deploy stage needs — and nothing more.

IAM → **Users** → **`jenkins`** → **Permissions** tab → **Add permissions** → **Create inline policy**
- Switch to the **JSON** tab
- Paste (substitute your account ID `<ACCOUNT_ID>` in both places):

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "EcsDescribeAndRegister",
            "Effect": "Allow",
            "Action": [
                "ecs:DescribeTaskDefinition",
                "ecs:RegisterTaskDefinition"
            ],
            "Resource": "*"
        },
        {
            "Sid": "EcsUpdateNobledSmokeService",
            "Effect": "Allow",
            "Action": [
                "ecs:UpdateService",
                "ecs:DescribeServices"
            ],
            "Resource": "arn:aws:ecs:us-east-1:<ACCOUNT_ID>:service/nobled-cluster/nobled-smoke-service"
        },
        {
            "Sid": "PassExecutionRoleToEcsOnly",
            "Effect": "Allow",
            "Action": "iam:PassRole",
            "Resource": "arn:aws:iam::<ACCOUNT_ID>:role/ecsTaskExecutionRole",
            "Condition": {
                "StringEquals": {
                    "iam:PassedToService": "ecs-tasks.amazonaws.com"
                }
            }
        }
    ]
}
```

- Click **Next**
- Policy name: **`ecs-deploy-nobled-smoke`**
- Create

*Why three statements*:
1. **EcsDescribeAndRegister** must be `Resource: "*"` because `ecs:DescribeTaskDefinition` and `ecs:RegisterTaskDefinition` don't support resource-level perms (the new revision being registered doesn't exist yet, so there's nothing concrete to scope to).
2. **EcsUpdateNobledSmokeService** *can* be scoped to the specific service ARN, so it is. The `jenkins` user can only mutate this one ECS service, not anyone else's.
3. **PassExecutionRoleToEcsOnly** is the easy-to-forget statement. When you register a task def that names an `executionRoleArn`, IAM treats that as "passing" the role to ECS. Without this, `register-task-definition` fails with `AccessDenied: User: jenkins is not authorized to perform: iam:PassRole on resource: ...ecsTaskExecutionRole`. The condition further restricts the passing to ECS only (defense in depth — the user couldn't pass the role to, say, Lambda).

### 14.2 — Verify (~2 min)

**Purpose:** Prove the new policy actually attached and works — before the pipeline tries to use it.

From your laptop (or anywhere with the jenkins user's AWS keys configured):

```bash
aws ecs describe-services \
    --cluster nobled-cluster \
    --services nobled-smoke-service \
    --region us-east-1 \
    --query 'services[0].{name:serviceName,desired:desiredCount,running:runningCount,taskDef:taskDefinition}'
```

Expect a JSON snippet like:
```json
{
    "name": "nobled-smoke-service",
    "desired": 1,
    "running": 1,
    "taskDef": "arn:aws:ecs:us-east-1:<ACCOUNT_ID>:task-definition/nobled-smoke:1"
}
```

If you get `AccessDeniedException`, the inline policy didn't attach. Re-check it's on the `jenkins` user (IAM → Users → jenkins → Permissions tab → should see `ecs-deploy-nobled-smoke` listed under "Permissions policies").

Phase 2 done.

---

## 15. Phase 3 — Add ECS Deploy stage to Jenkinsfile

### 15.1 — Add the stage to `jenkins/Jenkinsfile` (~5 min)

**Purpose:** Wire the deploy step into the pipeline itself, so every green build automatically rolls the new image out to Fargate.

Open `jenkins/Jenkinsfile` and add a new stage **after `ECR Push` and before the closing `}` of `stages {`**:

```groovy
stage('ECS Deploy') {
    agent { label 'cosmos-builder' }
    steps {
        withCredentials([[
            $class: 'AmazonWebServicesCredentialsBinding',
            credentialsId: 'aws-ecr',
            accessKeyVariable: 'AWS_ACCESS_KEY_ID',
            secretKeyVariable: 'AWS_SECRET_ACCESS_KEY'
        ]]) {
            sh '''
                set -eu

                echo "==> Reading current task def for nobled-smoke"
                aws ecs describe-task-definition \
                    --task-definition nobled-smoke \
                    --region ${AWS_REGION} \
                    --query 'taskDefinition' \
                    --output json > current-task-def.json

                echo "==> Patching image tag to ${IMAGE_REMOTE}"
                jq --arg IMG "${IMAGE_REMOTE}" '
                    .containerDefinitions[0].image = $IMG
                    | del(.taskDefinitionArn, .revision, .status,
                          .requiresAttributes, .compatibilities,
                          .registeredAt, .registeredBy)
                ' current-task-def.json > new-task-def.json

                echo "==> Registering new task definition revision"
                NEW_ARN=$(aws ecs register-task-definition \
                    --region ${AWS_REGION} \
                    --cli-input-json file://new-task-def.json \
                    --query 'taskDefinition.taskDefinitionArn' \
                    --output text)
                echo "    new revision: ${NEW_ARN}"

                echo "==> Updating nobled-smoke-service"
                aws ecs update-service \
                    --cluster nobled-cluster \
                    --service nobled-smoke-service \
                    --task-definition "${NEW_ARN}" \
                    --region ${AWS_REGION} > /dev/null

                echo "==> Waiting for services-stable (build fails if rollout doesn't succeed)"
                aws ecs wait services-stable \
                    --cluster nobled-cluster \
                    --services nobled-smoke-service \
                    --region ${AWS_REGION}
                echo "==> Rollout complete"

                rm -f current-task-def.json new-task-def.json
            '''
        }
    }
}
```

*Why this pattern (vs the simpler `:latest` + `--force-new-deployment` shortcut)*:
- **Immutable image refs per revision.** Each build produces a unique task def revision pointing at a unique image tag (`cosmos/nobled:6`, `:7`, …). To roll back, point the service at a previous revision — no rebuild, no image retag, instant.
- **`services-stable` wait.** The build only goes green if the new task actually reaches `RUNNING` and the old one drains. Catches deploys that *look* successful in `update-service` but immediately crashloop.
- **`jq` strip of read-only fields.** `describe-task-definition` returns fields that `register-task-definition` rejects (`taskDefinitionArn`, `revision`, `status`, `requiresAttributes`, `compatibilities`, `registeredAt`, `registeredBy`). Stripping with `jq` keeps everything else verbatim — so any console-side changes you make to the task def (memory, env vars, command edits) are preserved across pipeline deploys.

### 15.2 — Commit and push (~2 min)

**Purpose:** Push the Jenkinsfile change so the next build picks up the new stage (Jenkins loads it via SCM, not from local).

The Jenkinsfile loads via SCM. Push to `main` so the next `Build Now` picks up the new stage:

```bash
cd ~/Desktop/devops/jenkins-cosmos-build
git add jenkins/Jenkinsfile
git diff --cached
git commit -m "Add ECS Deploy stage — register new task def revision and update nobled-smoke-service"
git push origin main
```

(Reminder: per your global rules, no Co-Authored-By or Claude attribution trailers. The portfolio-scope hooks should already enforce this.)

### 15.3 — Run and verify (~5-8 min)

**Purpose:** Trigger a full CI+CD run and confirm the new task def revision is actually serving live traffic on Fargate.

Jenkins UI → `nobled-ci` → **Build Now**.

Stage view should now show **11 stages** instead of 10:
Checkout → Build → Test → Lint → Security (gosec) → Docker Build → Trivy Scan → ECR Push → **ECS Deploy** → Post Actions → End

ECS Deploy timing baseline (cold): **~3-5 min**, mostly spent in the `services-stable` wait while Fargate provisions the new task and drains the old. The CI stages before ECS Deploy add ~5-8 min on top.

While ECS Deploy is running, you can watch the rollout live:
- ECS console → `nobled-cluster` → `nobled-smoke-service` → **Tasks** tab — you'll see two tasks for ~30 sec (old draining, new starting), then back to one.
- **Events** tab — narrates each rollout state in plain English.

After the build is green, confirm the new revision is in use:
```bash
aws ecs describe-services \
    --cluster nobled-cluster \
    --services nobled-smoke-service \
    --region us-east-1 \
    --query 'services[0].taskDefinition'
```
Should show `:2` (or higher), incremented from the `:1` we created in §13.4.

And confirm CloudWatch logs show the freshly-deployed container started:
```bash
aws logs tail /ecs/nobled-smoke --since 5m --region us-east-1
```
Should show a `version: v11.1.0-rc.1` etc. line from the new task — same chain version, but from a fresh task ID.

Phase 3 is **done** when (a) a Jenkins build is green with the ECS Deploy stage, (b) `describe-services` shows task def revision ≥ 2, and (c) the running ECS task is on that new revision (visible in console + CloudWatch).

---

## 16. Final state — full CI/CD loop

What the pipeline now does end-to-end on every push to `main`:

```
git push  ->  Jenkins SCM poll/webhook
                ->  Checkout (clone jenkins-cosmos-build)
                ->  Build (clone noble, make install)
                ->  Test (go test ./...)
                ->  Lint / Security / Trivy (report-only)
                ->  Docker Build (multistage image)
                ->  ECR Push (cosmos/nobled:BUILD_NUMBER)
                ->  ECS Deploy (new task def revision -> update service -> wait stable)
                ->  Slack notify (when configured)
```

One `git push` produces one running `nobled` task on Fargate with the new binary. That's the full CI + CD loop.

### 16.1 — Cleanup at end of session

To minimize ongoing cost while preserving everything for next time:
- **Stop** the controller EC2 + agent EC2 (preserves Jenkins state + agent toolchain on EBS — ~$5/mo total for the two 30 GB gp3 disks).
- **Leave running**: ECR repo (storage cost is cents), ECS cluster definition itself (free), CloudWatch log group (cents at 1-week retention).
- **Scale `nobled-smoke-service` to 0** to stop paying for the running Fargate task:
  ```bash
  aws ecs update-service \
      --cluster nobled-cluster \
      --service nobled-smoke-service \
      --desired-count 0 \
      --region us-east-1
  ```
  Set back to `1` (same command, `--desired-count 1`) when you resume work. The next pipeline run will re-deploy whatever revision is current.

Total resting cost when fully stopped: ~$5/mo EBS + cents for ECR storage + cents for CloudWatch logs. Negligible compared to leaving the Fargate task running ($8-12/mo depending on hours).
