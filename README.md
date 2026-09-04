# CloudForge — Production-Ready AWS Infrastructure

A secure, automated deployment pipeline for a containerized website using **Terraform, Docker, Kubernetes (EKS), and Jenkins** on AWS.

---

## Architecture

```
Developer → Git Push → Jenkins (EC2)
                          │
                    ┌─────┴─────┐
                    │  Pipeline  │
                    │            │
                    │ 1. Build   │  (Docker multi-stage)
                    │ 2. Scan    │  (Trivy CVE + secrets)
                    │ 3. Push    │  (ECR - immutable tags)
                    │ 4. Deploy  │  (kubectl → EKS)
                    │ 5. Verify  │  (Health check)
                    └─────┬─────┘
                          │
                    ┌─────▼─────┐
                    │  AWS EKS  │
                    │           │
                    │  ┌─pod──┐ │     Internet
                    │  │nginx │◄├─────── ALB ◄── Users
                    │  └──────┘ │
                    │  ┌─pod──┐ │
                    │  │nginx │ │
                    │  └──────┘ │
                    └───────────┘
```

## Project Structure

```
project/
├── website/
│   └── index.html            # The website
├── nginx/
│   ├── nginx.conf            # Nginx config (rate limiting, gzip)
│   └── security-headers.conf # HSTS, CSP, X-Frame-Options
├── terraform/
│   └── main.tf               # VPC + EKS + ECR + Jenkins EC2 + IAM
├── k8s/
│   └── deployment.yaml       # Deployment + Service + HPA + NetworkPolicy + Ingress
├── Dockerfile                # Multi-stage, non-root, minimal image
├── Jenkinsfile               # CI/CD: Build → Scan → Push → Deploy
└── README.md
```

## Security Measures

| Layer          | Measure                                          |
|----------------|--------------------------------------------------|
| **Network**    | VPC with public/private subnets, NAT Gateway     |
| **IAM**        | Least-privilege roles for Jenkins, EKS nodes      |
| **EC2**        | IMDSv2 required, encrypted EBS volumes            |
| **Docker**     | Multi-stage build, non-root user, minimal base    |
| **ECR**        | Immutable tags, scan-on-push, AES256 encryption   |
| **K8s Pods**   | Non-root, read-only FS, drop ALL capabilities     |
| **K8s Network**| NetworkPolicy restricts ingress/egress per pod    |
| **K8s Secrets**| Encrypted at rest with KMS                        |
| **EKS**        | Audit logging, private endpoint, Pod Security      |
| **Nginx**      | Security headers (CSP, HSTS, X-Frame-Options)    |
| **CI/CD**      | Trivy scans for CVEs + secrets before deploy      |
| **TLS**        | cert-manager + Let's Encrypt auto-renewal         |

## Setup Guide

### Prerequisites
- AWS CLI configured with admin access
- Terraform >= 1.5
- kubectl
- An EC2 key pair named `cloudforge-key`

### Step 1: Deploy Infrastructure
```bash
cd terraform/
terraform init
terraform plan -out=plan.out
terraform apply plan.out
```

### Step 2: Configure kubectl
```bash
aws eks update-kubeconfig --name cloudforge-eks --region us-east-1
```

### Step 3: Deploy to Kubernetes (first time)
```bash
# Replace <AWS_ACCOUNT_ID> in k8s/deployment.yaml with your account ID
kubectl apply -f k8s/deployment.yaml
```

### Step 4: Configure Jenkins
1. SSH into Jenkins EC2: `ssh -i cloudforge-key.pem ec2-user@<JENKINS_IP>`
2. Get initial password: `sudo cat /var/lib/jenkins/secrets/initialAdminPassword`
3. Open `http://<JENKINS_IP>:8080` and complete setup
4. Install plugins: Docker Pipeline, Kubernetes CLI, AWS Credentials
5. Add credentials: `aws-account-id` (secret text)
6. Create pipeline job pointing to your Git repo

### Step 5: Push and Deploy
```bash
git push origin main
# Jenkins will automatically: Build → Scan → Push → Deploy
```

## Estimated AWS Cost
- EKS cluster: ~$73/month
- EC2 nodes (2x t3.medium): ~$60/month
- Jenkins (t3.medium): ~$30/month
- NAT Gateway: ~$32/month
- **Total: ~$195/month**

## Troubleshooting

Issues encountered while building this out, and how they were resolved. Most were environment-specific and not obvious from the error messages alone.

### EKS node group fails: "Requested AMI for this version 1.29 is not supported"

The EKS control plane created successfully, but the managed node group failed immediately afterward.

**Cause:** EKS version availability differs by region. Version 1.29 had no supported node AMI in `ap-south-1` at the time, even though the control plane accepted the version string.

**Fix:** Bumped the cluster version to 1.30 in `terraform/main.tf` and re-applied. Since the control plane already existed, only the version update and node group creation ran.

**Takeaway:** Check `aws eks describe-addon-versions` or the regional availability docs before pinning an EKS version. The control plane accepting a version doesn't guarantee node AMIs exist for it.

---

### Pods stuck in `ImagePullBackOff` — wrong region in the image URL

Both pods sat in `ImagePullBackOff` after the first `kubectl apply`.

**Cause:** `k8s/deployment.yaml` still had `us-east-1` in the ECR image URL after the project moved to `ap-south-1`. The registry hostname is region-specific, so the pull targeted a repository that didn't exist.

**Fix:** Updated the image URL to the `ap-south-1` registry hostname and re-applied.

**Diagnosis note:** `kubectl get pods` only shows the status. `kubectl describe pod <name> -n cloudforge` and reading the `Events` section at the bottom is what surfaced the actual URL being pulled.

---

### Pods still failing after the region fix — `latest` tag never pushed

Same `ImagePullBackOff`, but now with the correct region in the error.

**Cause:** The ECR repository is created with `image_tag_mutability = "IMMUTABLE"`. The `docker push` of the `latest` tag failed silently against that setting, leaving two untagged image digests in the registry. Only `v1.0.0` had an actual tag.

**Fix:** Confirmed with `aws ecr list-images --repository-name cloudforge/website --region ap-south-1`, which showed only `v1.0.0` tagged. Pinned the deployment to `v1.0.0` and set `imagePullPolicy: IfNotPresent`.

**Takeaway:** Immutable tags and a `latest` tag are fundamentally incompatible — `latest` needs to be reassigned on every push, which is exactly what immutability prevents. Use explicit version tags with immutable repositories.

---

### Jenkins pipeline times out reaching the EKS API

`kubectl get nodes` in the pipeline failed with `dial tcp 10.0.11.86:443: i/o timeout`.

**Cause:** No security group rule allowed traffic from the Jenkins EC2 instance to the EKS cluster's API endpoint on port 443.

**Fix:** Added an ingress rule on the EKS cluster security group with the Jenkins security group as the source:

```bash
aws ec2 authorize-security-group-ingress \
  --group-id <eks-cluster-sg> \
  --protocol tcp --port 443 \
  --source-group <jenkins-sg> \
  --region ap-south-1
```

The cluster security group ID comes from `aws eks describe-cluster --name cloudforge-eks --query "cluster.resourcesVpcConfig.clusterSecurityGroupId"`.

---

### Jenkins reaches EKS but gets "You must be logged in to the server"

Network path worked, but authentication failed.

**Cause:** Network reachability and Kubernetes RBAC are separate concerns. The Jenkins EC2 instance role (`cloudforge-jenkins-role`) had `eks:DescribeCluster` in IAM, which is enough to fetch a kubeconfig, but it had no identity mapping inside the cluster itself.

**Fix:** Two steps, in order. The cluster's authentication mode had to change before an access entry could be created at all:

```bash
aws eks update-cluster-config --name cloudforge-eks \
  --access-config authenticationMode=API_AND_CONFIG_MAP --region ap-south-1

aws eks create-access-entry --cluster-name cloudforge-eks \
  --principal-arn arn:aws:iam::<account-id>:role/cloudforge-jenkins-role --region ap-south-1

aws eks associate-access-policy --cluster-name cloudforge-eks \
  --principal-arn arn:aws:iam::<account-id>:role/cloudforge-jenkins-role \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
  --access-scope type=cluster --region ap-south-1
```

**Takeaway:** IAM permissions get you to the EKS API. Cluster access entries determine what you can do once you're there. The first attempt fails with `InvalidRequestException` if the cluster is still in `CONFIG_MAP`-only auth mode.

---

### `terraform destroy` fails on the ECR repository

Teardown ran most of the way, then errored: `RepositoryNotEmptyException`.

**Cause:** The repository is declared with `force_delete = false`, so Terraform refuses to delete it while images remain.

**Fix:** Deleted the repository and its images directly, then re-ran destroy:

```bash
aws ecr delete-repository --repository-name cloudforge/website --force --region ap-south-1
terraform destroy
```

---

### Windows / PowerShell notes

A few commands from the standard docs need adjusting on Windows:

| Standard | PowerShell |
|---|---|
| `python3 -m http.server` | `python -m http.server` |
| `terraform plan -out=plan.out` | `terraform plan -out plan.out` |
| `aws ecr get-login-password \| docker login --password-stdin` | Assign to a variable first, then pass with `--password` |

The ECR login in particular:

```powershell
$pass = aws ecr get-login-password --region ap-south-1
docker login --username AWS --password $pass <account-id>.dkr.ecr.ap-south-1.amazonaws.com
```

Amazon Linux 2023 also ships without `wget`. Use `curl -L` — the `-L` matters, since `pkg.jenkins.io` redirects and without it you download an HTML error page instead of the repo file.

## Next Steps
- [ ] Add a domain and configure Route 53
- [ ] Enable AWS WAF on the ALB
- [ ] Add Prometheus + Grafana monitoring
- [ ] Set up Slack notifications in Jenkins
- [ ] Add staging environment with separate namespace
