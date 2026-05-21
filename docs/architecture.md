# Architecture & flow

## 1. What we're building (topology)

```
+---------------------------------+            +--------------------------------------------------+
|           Your laptop           |            |                  AWS Account                     |
|                                 |            |                  (us-east-1)                     |
|  ~/Desktop/devops/              |            |                                                  |
|    jenkins-cosmos-build/        |            |  +-----------------------------+                 |
|      Jenkinsfile                |  browser   |  | EC2: jenkins-controller     |                 |
|      Dockerfile                 +----------->|  | m7i-flex.large (2vCPU/8GB)  |                 |
|      userdata/*.sh              |  port 8080 |  |   - Jenkins (port 8080)     |                 |
|      README.md                  |            |  |   - JDK 21                  |                 |
|                                 |  SSH       |  |   - Orchestrates only —     |                 |
|                                 +----------->|  |     no builds run here      |                 |
+---------------------------------+  port 22   |  +--------------+--------------+                 |
                                               |                 | SSH (22) launches agent.jar    |
                                               |                 v                                |
                                               |  +-----------------------------+                 |
                                               |  | EC2: jenkins-agent          |                 |
                                               |  | t3.medium (2vCPU/4GB)       |                 |
                                               |  | Label: cosmos-builder       |                 |
                                               |  |   - JDK 21 (agent.jar)      |                 |
                                               |  |   - Docker daemon           |                 |
                                               |  |   - Go, golangci-lint,      |                 |
                                               |  |     gosec, Trivy, AWS CLI   |                 |
                                               |  +--------------+--------------+                 |
                                               |                 | docker push                    |
                                               |                 v                                |
                                               |  +-----------------------------+                 |
                                               |  | ECR repo:                   |                 |
                                               |  |   cosmos/nobled             |                 |
                                               |  |   <ACCOUNT_ID>.dkr.ecr...   |                 |
                                               |  +--------------+--------------+                 |
                                               |                 | pulled by Fargate              |
                                               |                 v                                |
                                               |  +-----------------------------+                 |
                                               |  | ECS cluster: nobled-cluster |                 |
                                               |  |   launch type: Fargate      |                 |
                                               |  |   +-----------------------+ |                 |
                                               |  |   | Service:              | |                 |
                                               |  |   |   nobled-smoke-service| |                 |
                                               |  |   |   desired=1, replica  | |                 |
                                               |  |   |   +-----------------+ | |                 |
                                               |  |   |   | Task (Fargate)  | | |                 |
                                               |  |   |   |  image: cosmos/ | | |                 |
                                               |  |   |   |   nobled:<N>    | | |                 |
                                               |  |   |   |  uses execRole: | | |                 |
                                               |  |   |   |   ecsTaskExecn  | | |                 |
                                               |  |   |   |   Role          | | |                 |
                                               |  |   |   +--------+--------+ | |                 |
                                               |  |   +------------|--------+ | |                 |
                                               |  +----------------|----------+                   |
                                               |                   | stdout/stderr               |
                                               |                   v                              |
                                               |  +-----------------------------+                 |
                                               |  | CloudWatch Logs:            |                 |
                                               |  |   /ecs/nobled-smoke         |                 |
                                               |  +-----------------------------+                 |
                                               |                                                  |
                                               |   aws creds     ^                                |
                                               |                 |                                |
                                               |  +-----------------------------+                 |
                                               |  | IAM user: jenkins           |                 |
                                               |  |   AmazonEC2ContainerRegistry|                 |
                                               |  |     FullAccess              |  (ECR push)     |
                                               |  |   ecs-deploy-nobled-smoke   |  (inline,       |
                                               |  |     - Register/DescribeTask |   scoped to     |
                                               |  |       Definition            |   one service)  |
                                               |  |     - Update/DescribeServ.  |                 |
                                               |  |       on nobled-smoke-svc   |                 |
                                               |  |     - PassRole on           |                 |
                                               |  |       ecsTaskExecutionRole  |                 |
                                               |  |   (access key + secret,     |                 |
                                               |  |    injected by controller   |                 |
                                               |  |    into the agent's shell)  |                 |
                                               |  +-----------------------------+                 |
                                               +--------------------------------------------------+

  Controller responsibilities: web UI, job scheduling, Slack notifications, credential vault.
  Agent responsibilities:      every build stage — clone, compile, lint, scan, docker build,
                               ECR push, and ECS Deploy.
```

## 2. Pipeline execution flow (what `Build Now` does)

```
                                          inputs
                                          ------
+-----------------------------------+
| Stage 1: Checkout                 |  <- github.com/strangelove-ventures/noble
|   git clone --branch v11.1.0-rc.1 |     at tag v11.1.0-rc.1
+-----------------------------------+
                |
                v
+-----------------------------------+
| Stage 2: Build                    |  -> compiled `nobled` binary
|   make install                    |     in /var/lib/jenkins/go/bin/
+-----------------------------------+
                |
                v
+-----------------------------------+
| Stage 3: Test                     |  fails build if upstream
|   go test ./... -timeout 15m      |  Cosmos SDK tests fail
+-----------------------------------+
                |
                v
+-----------------------------------+
| Stage 4: Lint                     |  fails on unused vars, dead code,
|   golangci-lint run               |  inefficient idioms, etc.
+-----------------------------------+
                |
                v
+-----------------------------------+
| Stage 5: Security (gosec)         |  fails on hardcoded creds,
|   gosec ./...                     |  weak crypto, unsafe SQL, etc.
+-----------------------------------+
                |
                v
+-----------------------------------+
| Stage 6: Docker Build             |  -> local image: nobled:<BUILD_NUMBER>
|   docker build -t nobled:<N> .    |     (multistage: golang -> debian-slim)
+-----------------------------------+
                |
                v
+-----------------------------------+
| Stage 7: Trivy Scan               |  fails on HIGH/CRITICAL CVEs
|   trivy image --severity          |  in any package layer of the image
|     HIGH,CRITICAL --exit-code 1   |
+-----------------------------------+
                |
                v
+-----------------------------------+
| Stage 8: ECR Push                 |  reads: aws-account-id, aws-ecr
|   aws ecr get-login-password ...  |  pushes to:
|   docker tag ... <ECR URI>        |    <ACCOUNT_ID>.dkr.ecr.us-east-1
|   docker push <ECR URI>           |    .amazonaws.com/cosmos/nobled:<N>
+-----------------------------------+
                |
                v
+-----------------------------------+
| Stage 9: ECS Deploy               |  reads: aws-ecr
|   describe-task-definition        |  jq-patches the existing task def
|     -> jq patch image tag         |  to point at cosmos/nobled:<N>,
|   register-task-definition        |  registers as a new revision,
|     -> new revision               |  updates nobled-smoke-service to
|   update-service                  |  it, then `wait services-stable`
|   wait services-stable            |  blocks until the rollout succeeds
+-----------------------------------+      (build fails if it doesn't)
                |
                v
+-----------------------------------+
| post { success | failure }        |  posts a message to Slack webhook
|   slack notification (curl)       |  (skipped silently if cred missing)
+-----------------------------------+

  End result: cosmos/nobled:<BUILD_NUMBER> is pushed to ECR AND running
              as the live task behind nobled-smoke-service on Fargate.
              One `git push` -> one new running task.
```

## 3. Controller vs agent — what runs where

```
Jenkinsfile directive            Runs on            Why
=====================            =======            ===
pipeline { agent none }          n/a                Force per-stage agent choice.
stage('Checkout' ...9 stages)    cosmos-builder     All build heavy lifting lives on the agent.
post { success } / { failure }   built-in (ctrl)    Curl-to-Slack — light, and survives an
                                                    offline agent (you still get the failure ping).
post { always } docker prune     cosmos-builder     Docker daemon lives on the agent, not controller.
```

The `built-in` label is Jenkins' name for the controller node itself.

## 4. Where each Jenkins credential is used

```
Jenkins UI                          Jenkinsfile                Used in stage
==========                          ===========                =============
aws-account-id  (Secret text)  -->  ${AWS_ACCOUNT_ID}      -->  Stage 8 (ECR URI)            on agent
aws-ecr         (AWS Creds)    -->  withCredentials([...]) -->  Stage 8 (docker push) +      on agent
                                                                Stage 9 (ECS register/update)
slack-webhook   (Secret text)  -->  ${SLACK_URL}           -->  post { success/failure }     on controller
ssh-agent-key   (SSH Username) -->  Manage Jenkins -> Nodes -> launch agents via SSH (controller -> agent)
```

Credentials are stored once on the controller. When a stage runs on the agent,
the controller injects the resolved secrets into the agent's shell via the SSH
channel — they never live on disk on the agent.

## 5. From source to running task (full CI + CD loop)

```
Source: strangelove-ventures/noble
            |
            +----[ Jenkins pipeline ]----> Docker image in ECR
                                           (cosmos/nobled:<BUILD_NUMBER>)
                                                       |
                                                       v
                                           ECS task def revision
                                           (nobled-smoke:<N>)
                                                       |
                                                       v
                                           Fargate task running
                                           nobled-smoke-service
```

The CI pipeline (build, test, scan, push) and the CD step (register task
def revision, update service, wait for stable rollout) are now a single
pipeline. One `git push` produces one running task on Fargate.

The smoke service intentionally runs `nobled version && sleep 3600` — it
proves the image boots on AWS but does no chain sync. A real syncing
RPC fullnode (persistent volume, snapshot restore, peer config, exposed
port 26657) is out of scope for this repo and a better fit for Kubernetes
StatefulSets.

Parallel to all this, `scripts/userdata/noble-node-setup.sh` still
provisions a plain EC2 running `nobled` as systemd — used for hands-on
node-ops practice, independent of the pipeline.
