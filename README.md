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

## Next Steps
- [ ] Add a domain and configure Route 53
- [ ] Enable AWS WAF on the ALB
- [ ] Add Prometheus + Grafana monitoring
- [ ] Set up Slack notifications in Jenkins
- [ ] Add staging environment with separate namespace
