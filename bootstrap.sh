#!/usr/bin/env bash
set -euo pipefail

# ====== SỬA BIẾN NÀY CHO PHÙ HỢP MÔI TRƯỜNG CỦA BẠN ======
ACCOUNT_ID="507737351904"
AWS_REGION="ap-southeast-1"
CLUSTER_NAME="maxphan-eks-demo-1"
ECR_REPO="flask-app"
VPC_ID="vpc-0f21a566eac6f5ebc"
# Điền danh sách subnet riêng (private) dạng CSV rồi chuyển thành mảng:
PRIVATE_SUBNET_IDS_CSV="subnet-0800603a593d587b2,subnet-053599a064ba68b5e"
# =========================================================

IFS=',' read -r -a PRIVATE_SUBNET_IDS <<< "$PRIVATE_SUBNET_IDS_CSV"

# Thư mục
mkdir -p app helm/flask-app/templates infra/terraform .github/workflows

# ---------- ỨNG DỤNG FLASK ----------
cat > app/app.py <<'PY'
from flask import Flask
import os
app = Flask(__name__)

@app.route("/")
def hello():
    env = os.getenv("APP_ENV", "dev")
    return f"Hello from Flask on EKS via Helm! Env={env}\n"

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.getenv("PORT", 8080)))
PY

cat > app/requirements.txt <<'REQ'
flask==3.0.3
REQ

cat > app/Dockerfile <<'DOCKER'
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
ENV PORT=8080
EXPOSE 8080
CMD ["python","app.py"]
DOCKER

# ---------- HELM CHART ----------
cat > helm/flask-app/Chart.yaml <<'YAML'
apiVersion: v2
name: flask-app
description: Flask sample deployed to EKS
type: application
version: 0.1.0
appVersion: "1.0.0"
YAML

cat > helm/flask-app/values.yaml <<YAML
replicaCount: 2

image:
  repository: ${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO}
  tag: "latest"
  pullPolicy: IfNotPresent

service:
  type: ClusterIP
  port: 80
  targetPort: 8080

ingress:
  enabled: true
  className: alb
  hosts:
    - host: ""
      paths:
        - path: /
          pathType: Prefix
  tls: []

resources:
  requests:
    cpu: "100m"
    memory: "128Mi"
  limits:
    cpu: "250m"
    memory: "256Mi"

autoscaling:
  enabled: true
  minReplicas: 2
  maxReplicas: 5
  targetCPUUtilizationPercentage: 70

env:
  - name: APP_ENV
    value: "base"

serviceAccount:
  create: true
  name: ""
  annotations: {}
YAML

cat > helm/flask-app/values-dev.yaml <<'YAML'
image:
  tag: "dev-${GIT_SHA}"
env:
  - name: APP_ENV
    value: "dev"
autoscaling:
  minReplicas: 1
  maxReplicas: 2
YAML

cat > helm/flask-app/values-staging.yaml <<'YAML'
image:
  tag: "staging-${GIT_SHA}"
env:
  - name: APP_ENV
    value: "staging"
autoscaling:
  minReplicas: 2
  maxReplicas: 4
YAML

cat > helm/flask-app/values-prod.yaml <<'YAML'
image:
  tag: "prod-${GIT_SHA}"
env:
  - name: APP_ENV
    value: "prod"
autoscaling:
  minReplicas: 3
  maxReplicas: 6
resources:
  requests:
    cpu: "200m"
    memory: "256Mi"
  limits:
    cpu: "500m"
    memory: "512Mi"
YAML

cat > helm/flask-app/templates/deployment.yaml <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "flask-app.fullname" . }}
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels:
      app.kubernetes.io/name: {{ include "flask-app.name" . }}
  template:
    metadata:
      labels:
        app.kubernetes.io/name: {{ include "flask-app.name" . }}
    spec:
      serviceAccountName: {{ .Values.serviceAccount.name | default (include "flask-app.fullname" .) }}
      containers:
        - name: app
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          ports:
            - containerPort: {{ .Values.service.targetPort }}
          env:
          {{- toYaml .Values.env | nindent 12 }}
          resources:
            {{- toYaml .Values.resources | nindent 12 }}
YAML

cat > helm/flask-app/templates/service.yaml <<'YAML'
apiVersion: v1
kind: Service
metadata:
  name: {{ include "flask-app.fullname" . }}
spec:
  type: {{ .Values.service.type }}
  selector:
    app.kubernetes.io/name: {{ include "flask-app.name" . }}
  ports:
    - port: {{ .Values.service.port }}
      targetPort: {{ .Values.service.targetPort }}
YAML

cat > helm/flask-app/templates/hpa.yaml <<'YAML'
{{- if .Values.autoscaling.enabled }}
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: {{ include "flask-app.fullname" . }}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: {{ include "flask-app.fullname" . }}
  minReplicas: {{ .Values.autoscaling.minReplicas }}
  maxReplicas: {{ .Values.autoscaling.maxReplicas }}
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: {{ .Values.autoscaling.targetCPUUtilizationPercentage }}
{{- end }}
YAML

cat > helm/flask-app/templates/ingress.yaml <<'YAML'
{{- if .Values.ingress.enabled }}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ include "flask-app.fullname" . }}
  annotations:
    kubernetes.io/ingress.class: {{ .Values.ingress.className }}
spec:
  rules:
  {{- range .Values.ingress.hosts }}
    - host: {{ .host | quote }}
      http:
        paths:
        {{- range .paths }}
          - path: {{ .path }}
            pathType: {{ .pathType }}
            backend:
              service:
                name: {{ include "flask-app.fullname" $ }}
                port:
                  number: {{ $.Values.service.port }}
        {{- end }}
  {{- end }}
{{- end }}
YAML

# ---------- TERRAFORM ----------
cat > infra/terraform/providers.tf <<'HCL'
terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.30" }
    helm = { source = "hashicorp/helm", version = "~> 2.13" }
  }
}
provider "aws" {
  region = var.region
}
HCL

cat > infra/terraform/variables.tf <<'HCL'
variable "region" { type = string }
variable "cluster_name" { type = string }
variable "vpc_id" { type = string }
variable "private_subnet_ids" { type = list(string) }
HCL

cat > infra/terraform/eks.tf <<HCL
module "eks" {
  source          = "terraform-aws-modules/eks/aws"
  version         = "~> 20.0"
  cluster_name    = var.cluster_name
  cluster_version = "1.30"
  vpc_id          = var.vpc_id
  subnet_ids      = var.private_subnet_ids

  eks_managed_node_groups = {
    default = {
      instance_types = ["t3.medium"]
      desired_size   = 2
      min_size       = 2
      max_size       = 5
    }
  }

  enable_irsa = true
}
HCL

cat > infra/terraform/ecr.tf <<HCL
resource "aws_ecr_repository" "flask_app" {
  name                 = "${ECR_REPO}"
  image_tag_mutability = "MUTABLE"
  image_scanning_configuration { scan_on_push = true }
}
output "ecr_url" { value = aws_ecr_repository.flask_app.repository_url }
HCL

cat > infra/terraform/outputs.tf <<'HCL'
output "cluster_name" { value = var.cluster_name }
HCL

cat > infra/terraform/main.tf <<HCL
# Ví dụ apply:
# terraform apply -var="region=${AWS_REGION}" -var="cluster_name=${CLUSTER_NAME}" -var="vpc_id=${VPC_ID}" -var='private_subnet_ids=${PRIVATE_SUBNET_IDS_CSV}'

HCL

# ---------- GITHUB ACTIONS ----------
cat > .github/workflows/build-and-deploy-dev.yml <<YML
name: Build & Deploy (dev)

on:
  push:
    branches: [ "main" ]
    paths:
      - "app/**"
      - "helm/**"
      - ".github/workflows/build-and-deploy-dev.yml"

env:
  AWS_REGION: ${AWS_REGION}
  ECR_REPO: ${ECR_REPO}
  CLUSTER_NAME: ${CLUSTER_NAME}
  NAMESPACE: default

permissions:
  id-token: write
  contents: read

jobs:
  build-and-deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Configure AWS Credentials (OIDC)
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::${ACCOUNT_ID}:role/GHActions-Deployer
          aws-region: \${{ env.AWS_REGION }}

      - name: Login to ECR
        uses: aws-actions/amazon-ecr-login@v2

      - name: Build & Push
        env:
          ECR_REGISTRY: \${{ steps.login-ecr.outputs.registry }}
          IMAGE_TAG: dev-\${{ github.sha }}
        run: |
          docker build -t \$ECR_REGISTRY/\$ECR_REPO:\$IMAGE_TAG ./app
          docker push \$ECR_REGISTRY/\$ECR_REPO:\$IMAGE_TAG
          echo "IMAGE_TAG=\$IMAGE_TAG" >> \$GITHUB_ENV
          echo "ECR_REGISTRY=\$ECR_REGISTRY" >> \$GITHUB_ENV

      - name: Update kubeconfig
        run: aws eks update-kubeconfig --region \${{ env.AWS_REGION }} --name \${{ env.CLUSTER_NAME }}

      - name: Helm upgrade
        run: |
          helm upgrade --install flask-app ./helm/flask-app \
            --namespace \${{ env.NAMESPACE }} --create-namespace \
            --set image.repository=\${{ env.ACCOUNT_ID }}.dkr.ecr.\${{ env.AWS_REGION }}.amazonaws.com/\${{ env.ECR_REPO }} \
            --set image.tag=\${{ env.IMAGE_TAG }} \
            -f helm/flask-app/values-dev.yaml
YML

# ---------- README ----------
cat > README.md <<MD
# k8s-aws-helm-git

Khung dự án học Kubernetes trên AWS (EKS) với Helm & CI/CD.

## Nhanh tay
\`\`\`bash
# tạo venv (tuỳ chọn), cài awscli, kubectl, helm
# sửa biến ở đầu bootstrap.sh, sau đó:
bash bootstrap.sh
\`\`\`

## Build tại chỗ (tuỳ chọn)
\`\`\`bash
# nếu có Docker engine hợp lệ
docker build -t \$(aws sts get-caller-identity --query Account --output text).dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO}:dev-local ./app
\`\`\`

## Triển khai thử
- Tạo EKS & ECR bằng Terraform (sau khi điền VPC/Subnet thật).
- Push image lên ECR (qua CI hoặc tạm thời).
- \`helm upgrade --install\` như workflow.

MD

# Ghi ra file .env gợi ý (không bắt buộc)
cat > .env.example <<ENV
ACCOUNT_ID=${ACCOUNT_ID}
AWS_REGION=${AWS_REGION}
CLUSTER_NAME=${CLUSTER_NAME}
ECR_REPO=${ECR_REPO}
VPC_ID=${VPC_ID}
PRIVATE_SUBNET_IDS_CSV=${PRIVATE_SUBNET_IDS_CSV}
ENV

echo "✅ Project skeleton generated."
