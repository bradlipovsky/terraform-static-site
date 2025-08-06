# Chatbot Website on AWS (S3 + CloudFront + ECS Fargate via ALB + OpenAI)

A minimal, reproducible starter that serves a **static frontend** (S3 + CloudFront) and a **FastAPI backend** (Docker → ECR → ECS Fargate behind an ALB). CloudFront securely **proxies** `/chat` requests to the backend, so your site is HTTPS end-to-end **without** needing a custom domain.

---

## 🧱 Architecture

```
Browser (HTTPS)
   │
   ▼
CloudFront  ───────────────►  S3 bucket (index.html, script.js, styles.css)
   │
   └────  /chat*  (HTTPS viewer → HTTP origin)  ──►  ALB  ──►  ECS Fargate task (FastAPI + Uvicorn)
                                                     ▲
                                                     └── pulls Docker image from ECR
```

* **Frontend**: Static site in S3, delivered by **CloudFront** (HTTPS).
* **Backend**: FastAPI container on **ECS Fargate**; receives `/chat` POSTs via **ALB**.
* **Proxying**: CloudFront has a **second origin** (the ALB) and a **behavior** for `/chat*`; requests go to the backend while staying HTTPS for the browser.
* **OpenAI**: API key injected into the ECS task as an env var.

---

## 📂 Repository Layout

```
backend/                  # FastAPI app
  ├── main.py
  ├── requirements.txt
  ├── Dockerfile
  ├── .env.example        # sample env (do NOT commit real .env)

frontend/                 # Your static files (optional if you keep at repo root)
  ├── index.html
  ├── script.js
  └── styles.css

backend_service/          # Terraform for VPC, subnets, ALB, ECS, ECR, logs
  ├── main.tf
  ├── variables.tf
  ├── terraform.tfvars.example  # sample variables (do NOT commit real tfvars)

static_site/              # Terraform for S3 + CloudFront (if you split it)
  └── main.tf

README.md
.gitignore
```

> You can keep `index.html`/`script.js` at the repo root if you prefer—just adjust your upload commands accordingly.

---

## 🛡️ Secrets & Git Hygiene

**Never commit secrets.** Use these ignore rules:

* **Do not commit**: `backend/.env`, `backend_service/terraform.tfvars`, `terraform.tfstate*`, `.terraform/`, `*.tfplan`
* Provide examples only: `backend/.env.example`, `backend_service/terraform.tfvars.example`
* Add a root `.gitignore` similar to:

```gitignore
# Terraform
*.tfstate
*.tfstate.*
.terraform/
.terraform.lock.hcl
*.tfplan
terraform.tfvars
*.auto.tfvars

# Secrets
.env
.env.*

# Python/venv
__pycache__/
*.py[cod]
.venv/
venv/
env/

# OS/Editor
.DS_Store
.vscode/
.idea/
```

---

## 🔧 Prerequisites

* **AWS account** + **AWS CLI** configured (SSO or keys)
* **Terraform** installed
* **Docker** (with `buildx`)
* An **OpenAI API key** with quota

If using SSO:

```bash
aws sso login --profile <your-profile>
export AWS_PROFILE=<your-profile>
```

Sanity check:

```bash
aws sts get-caller-identity
```

---

## 🚀 Step 1 — Frontend (S3 + CloudFront)

You likely have this deployed already. If not, use Terraform in `static_site/` (or your existing TF) to:

* Create an S3 bucket (static website hosting **off** if using CloudFront origin access)
* Create a CloudFront distribution with the S3 origin
* Output the CloudFront **domain name** (e.g., `dxxxx.cloudfront.net`)

**Upload assets:**

```bash
aws s3 cp index.html s3://<your-bucket>/ --content-type "text/html" --cache-control "no-cache"
aws s3 cp script.js s3://<your-bucket>/ --content-type "application/javascript" --cache-control "no-cache"
aws s3 cp styles.css s3://<your-bucket>/ --content-type "text/css" --cache-control "no-cache"
```

**Invalidate CloudFront** after any change:

```bash
aws cloudfront create-invalidation --distribution-id <DIST_ID> --paths "/index.html" "/script.js" "/styles.css"
```

---

## 🐳 Step 2 — Backend (Docker + ECR)

**Build for amd64** (ECS Fargate runs x86\_64):

```bash
cd backend/
docker buildx build --platform linux/amd64 -t chatbot-backend .
```

**Login to ECR & Push:**

```bash
aws ecr get-login-password --region us-west-2 \
| docker login --username AWS --password-stdin <ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com

docker tag chatbot-backend:latest <ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com/chatbot-backend:latest
docker push <ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com/chatbot-backend:latest
```

> If buildx complains, run once: `docker buildx create --use`

---

## ☁️ Step 3 — Infrastructure (Terraform for VPC, ALB, ECS, ECR)

From `backend_service/`:

1. **Fill variables**

`variables.tf` includes:

```hcl
variable "openai_api_key" {
  description = "OpenAI API Key"
  type        = string
  sensitive   = true
}
```

Create `terraform.tfvars` (do NOT commit):

```hcl
openai_api_key = "sk-..."
```

2. **Apply**

```bash
cd backend_service/
terraform init
terraform apply
```

This creates:

* VPC + **two** public subnets (required by ALB)
* **ALB** (HTTP:80) + target group (port 8000)
* **Security groups** (ALB: 80/443 if you add TLS; ECS: allows 8000 from ALB SG)
* **CloudWatch Logs** group for the container
* **ECR** repository (if not made already)
* **ECS cluster**, task definition (env injects `OPENAI_API_KEY`), and service
* Fargate task with public networking

3. **Verify task is RUNNING**, then get the **ALB DNS name** from **EC2 → Load Balancers**.

**Curl test** (bypassing CloudFront):

```bash
curl -X POST http://<ALB_DNS>/chat \
  -H "Content-Type: application/json" \
  -d '{"message":"Hello from curl"}'
```

---

## 🔁 Step 4 — CloudFront Proxy for `/chat`

We keep the browser HTTPS while the ALB can remain HTTP.

### A) Add ALB as a **second origin** in CloudFront

* Console → CloudFront → Distribution → **Origins** → **Create origin**

  * Origin domain: `<ALB_DNS>`
  * Name: `backend-alb`
  * Protocol: **HTTP only** (origin protocol; viewer remains HTTPS)

### B) Create a **behavior** for `/chat*`

* **Behaviors** → **Create behavior**

  * **Path pattern**: `/chat*`
  * **Origin**: `backend-alb`
  * **Viewer protocol policy**: *Redirect HTTP to HTTPS*
  * **Allowed methods**: `GET, HEAD, OPTIONS, PUT, POST, PATCH, DELETE` (POST + OPTIONS required)
  * **Cache policy**: `CachingDisabled`
  * **Origin request policy**: `AllViewer` (forwards headers and body)
  * Save

### C) Point the frontend to CloudFront

In `script.js`:

```js
// before: fetch("http://<ALB_DNS>/chat", ...)
fetch("/chat", {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ message: input.value }),
});
```

Re-upload & invalidate:

```bash
aws s3 cp script.js s3://<your-bucket>/ --content-type "application/javascript" --cache-control "no-cache"
aws cloudfront create-invalidation --distribution-id <DIST_ID> --paths "/script.js"
```

### D) Test in browser

* Open your CloudFront URL (e.g., `https://dxxxx.cloudfront.net`)
* Open DevTools → Network
* Send a message → confirm `POST /chat` → **Status 200** → response JSON

---

## 🔐 CORS

Requests **go through CloudFront to ALB**; typical CORS issues are avoided. If you test directly from `http://<ALB_DNS>`, or host your frontend elsewhere, add CORS to FastAPI:

```python
from fastapi.middleware.cors import CORSMiddleware

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],            # or restrict to your domain(s)
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)
```

Rebuild/push/redeploy if you add this.

---

## 🧪 Local Dev Quickstart

* Run backend locally:

  ```bash
  cd backend
  uvicorn main:app --host 0.0.0.0 --port 8000
  ```
* Open `index.html` from filesystem or a local web server:

  ```bash
  python3 -m http.server 8080
  ```
* Point `script.js` to `http://localhost:8000/chat` (dev only)

---

## 🔄 Updating the Backend

1. Edit code in `backend/`
2. Rebuild & push for amd64:

```bash
docker buildx build --platform linux/amd64 -t chatbot-backend .
docker tag chatbot-backend:latest <ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com/chatbot-backend:latest
docker push <ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com/chatbot-backend:latest
```

3. Roll the ECS service:

```bash
cd backend_service
terraform apply
# (ensure a new task definition revision registers; a dummy env var change can force it)
```

---

## 🧹 Teardown

Be mindful: S3 buckets must be **emptied** before destroy.

```bash
# backend_service/
terraform destroy

# static_site/
aws s3 rm s3://<your-bucket> --recursive
terraform destroy
```

---

## 💸 Costs (Approximate)

* **Fargate** task (CPU/memory hours)
* **ALB** hours + LCU
* **CloudFront** egress (cheap, but not free)
* **CloudWatch Logs** (tiny)
* **S3** (tiny)

Idle dev deployments typically cost only a few dollars/day depending on region and hours. Turn off the ECS service when not in use.

---

## 🧯 Troubleshooting

**Problem**: `curl` to ALB fails
**Check**:

* ECS task status = RUNNING
* Security group for ECS allows **port 8000 from ALB SG**
* App binds `0.0.0.0:8000` (Uvicorn cmd in Dockerfile/CMD)

**Problem**: “exec format error” in logs
**Fix**:

* Rebuild image for `linux/amd64` with `docker buildx build --platform linux/amd64 ...`

**Problem**: Frontend says “Error contacting backend”
**Fix**:

* Mixed content (HTTPS → HTTP) → use CloudFront proxy `/chat`
* CloudFront behavior for `/chat*` points to ALB with **CachingDisabled** and **AllViewer** origin request policy
* Invalidate `/script.js`

**Problem**: Terraform hangs destroying SG
**Fix**:

* ECS service/ENIs still attached; stop service or wait for ENIs to detach; re-run `terraform apply`/`destroy`

**Problem**: No logs in CloudWatch
**Fix**:

* Ensure `logConfiguration` with `awslogs` driver is set inside the container definition

---

## 🗺️ Next Steps (Optional Enhancements)

* **TLS on ALB** (with a real domain via Route 53 + ACM)
* **Secrets Manager** for `OPENAI_API_KEY` instead of TF vars
* **API Gateway** instead of ALB if you prefer
* **PDF ingestion + embeddings** (FAISS/Chroma + RAG)
* **Autoscaling** and **health checks** tuning
* **CI/CD** (GitHub Actions: build → push → terraform plan/apply)

---

## 📎 References (internal)

* CloudFront Distribution ID: `<DIST_ID>`
* ALB DNS: `<ALB_DNS>`
* ECR repo: `<ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com/chatbot-backend`

> Replace placeholders with your actual values when documenting for the team.
