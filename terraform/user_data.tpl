#!/bin/bash
# user_data.tpl — EC2 bootstrap script for microservices deployment.
# Rendered by Terraform templatefile(); variables substituted at plan time.
# Runs as root via cloud-init on first boot.
# Log: /var/log/user-data.log

set -euxo pipefail
exec > /var/log/user-data.log 2>&1

echo "=== [1/6] System update ==="
apt-get update -y
apt-get upgrade -y

echo "=== [2/6] Install Docker CE ==="
apt-get install -y ca-certificates curl gnupg lsb-release unzip

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
  > /etc/apt/sources.list.d/docker.list

apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

systemctl enable docker
systemctl start docker

echo "Docker version: $(docker --version)"
echo "Docker Compose version: $(docker compose version)"

echo "=== [3/6] Install AWS CLI v2 ==="
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp/
/tmp/aws/install
rm -rf /tmp/aws /tmp/awscliv2.zip
echo "AWS CLI version: $(aws --version)"

echo "=== [4/6] Authenticate to ECR ==="
# The instance IAM role (via instance profile) provides credentials automatically.
# No access keys needed.
aws ecr get-login-password --region ${aws_region} \
  | docker login --username AWS --password-stdin ${ecr_registry}
echo "ECR login successful"

echo "=== [5/6] Write docker-compose.yml and start services ==="
mkdir -p /opt/microservices

# Write compose file with concrete ECR image URIs (substituted by Terraform at plan time)
cat > /opt/microservices/docker-compose.yml <<'COMPOSE'
version: '3.8'
services:
  service1:
    image: ${service1_image}
    ports:
      - "5000:5000"
    environment:
      - FLASK_ENV=production
    restart: unless-stopped
    healthcheck:
      test: ["CMD-SHELL", "python -c \"import urllib.request; urllib.request.urlopen('http://localhost:5000/health')\" || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 15s
  service2:
    image: ${service2_image}
    ports:
      - "5001:5001"
    environment:
      - FLASK_ENV=production
    restart: unless-stopped
    healthcheck:
      test: ["CMD-SHELL", "python -c \"import urllib.request; urllib.request.urlopen('http://localhost:5001/health')\" || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 15s
COMPOSE

cd /opt/microservices
docker compose pull
docker compose up -d
echo "Services started: $(docker compose ps)"

echo "=== [6/6] Schedule ECR token refresh every 6 hours ==="
# ECR auth tokens expire after 12 hours; refresh every 6 to be safe.
cat > /etc/cron.d/ecr-login <<'CRON'
0 */6 * * * root aws ecr get-login-password --region ${aws_region} | docker login --username AWS --password-stdin ${ecr_registry} >> /var/log/ecr-refresh.log 2>&1
CRON
chmod 644 /etc/cron.d/ecr-login

echo "=== Bootstrap complete ==="
docker ps
