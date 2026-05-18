# Architecture & flow

## 1. What we're building (topology)

```
+---------------------------------+            +-----------------------------------+
|           Your laptop           |            |          AWS Account              |
|                                 |            |          (us-east-1)              |
|  ~/Desktop/devops/              |            |                                   |
|    handson-jenkins-noble/       |            |  +-----------------------------+  |
|      Jenkinsfile                |  browser   |  | EC2: jenkins-controller     |  |
|      Dockerfile                 +----------->|  | m7i-flex.large (2vCPU/8GB)  |  |
|      userdata/*.sh              |  port 8080 |  |   - Jenkins (port 8080)     |  |
|      README.md                  |            |  |   - Docker daemon            |  |
|                                 |  SSH       |  |   - Go, golangci-lint,      |  |
|                                 +----------->|  |     gosec, Trivy, AWS CLI   |  |
+---------------------------------+  port 22   |  +--------------+--------------+  |
                                               |                 |                 |
                                               |   docker push   v                 |
                                               |  +-----------------------------+  |
                                               |  | ECR repo:                   |  |
                                               |  |   cosmos/nobled             |  |
                                               |  |   <ACCOUNT_ID>.dkr.ecr...   |  |
                                               |  +-----------------------------+  |
                                               |                 ^                 |
                                               |   aws creds     |                 |
                                               |  +-----------------------------+  |
                                               |  | IAM user: jenkins           |  |
                                               |  |   policy:                   |  |
                                               |  |   AmazonEC2ContainerRegistry|  |
                                               |  |   FullAccess                |  |
                                               |  |   (access key + secret)     |  |
                                               |  +-----------------------------+  |
                                               +-----------------------------------+

  (Later, separately: a 2nd EC2 runs `nobled` from source as systemd —
   that's the "spin the node" piece, not connected to the pipeline yet.
   ECS section will connect ECR image -> deployment.)
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
| post { success | failure }        |  posts a message to Slack webhook
|   slack notification (curl)       |  (skipped silently if cred missing)
+-----------------------------------+

  End result: ECR has tagged image `cosmos/nobled:<BUILD_NUMBER>`
              ready to be pulled by anything (ECS task, k8s pod, plain docker run)
```

## 3. Where each Jenkins credential is used

```
Jenkins UI                          Jenkinsfile                Used in stage
==========                          ===========                =============
aws-account-id  (Secret text)  -->  ${AWS_ACCOUNT_ID}      -->  Stage 8 (ECR URI)
aws-ecr         (AWS Creds)    -->  withCredentials([...]) -->  Stage 8 (docker push auth)
slack-webhook   (Secret text)  -->  ${SLACK_URL}           -->  post { success/failure }
```

## 4. The two parallel artifacts (intentional, for now)

```
Source: strangelove-ventures/noble
            |
            +----[ Jenkins pipeline ]----> Docker image in ECR
            |                              (just sits there until
            |                               we have something to deploy to)
            |
            +----[ Bare-metal EC2 ]------> Running `nobled` syncing
                  noble-node-setup.sh      Noble testnet on its own
                  systemd service
```

The pipeline and the bare-metal node are **independent right now**. They
get connected in the next course section (AWS ECS) which will pull the
ECR image and run it as an ECS task instead of bare-metal.
