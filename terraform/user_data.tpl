#!/bin/bash
# user_data.tpl — EC2 bootstrap script for microservices deployment.
# Rendered by Terraform templatefile(); variables substituted at plan time.
# Runs as root via cloud-init on first boot.
# Log: /var/log/user-data.log

set -euxo pipefail
exec > /var/log/user-data.log 2>&1

echo "=== [1/7] System update ==="
apt-get update -y
apt-get upgrade -y

echo "=== [2/7] Install Docker CE ==="
apt-get install -y ca-certificates curl gnupg lsb-release unzip jq

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

echo "=== [3/7] Install AWS CLI v2 ==="
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp/
/tmp/aws/install
rm -rf /tmp/aws /tmp/awscliv2.zip
echo "AWS CLI version: $(aws --version)"

echo "=== [4/7] Authenticate to ECR ==="
# The instance IAM role (via instance profile) provides credentials automatically.
aws ecr get-login-password --region ${aws_region} \
  | docker login --username AWS --password-stdin ${ecr_registry}
echo "ECR login successful"

echo "=== [5/7] Fetch runtime config from SSM + Secrets Manager ==="
# Non-sensitive runtime config from SSM Parameter Store.
LOG_LEVEL=$(aws ssm get-parameter \
  --region ${aws_region} \
  --name "${ssm_log_level}" \
  --query 'Parameter.Value' --output text || echo "INFO")

FEATURE_FLAGS=$(aws ssm get-parameter \
  --region ${aws_region} \
  --name "${ssm_feature_flags}" \
  --query 'Parameter.Value' --output text || echo "")

# Sensitive secrets from Secrets Manager (JSON blob). Written with mode 600 so
# only root can read it; Docker Compose reads it as an env_file.
mkdir -p /opt/microservices
SECRET_JSON=$(aws secretsmanager get-secret-value \
  --region ${aws_region} \
  --secret-id "${app_secret_arn}" \
  --query 'SecretString' --output text || echo '{}')

# Convert JSON object { "K": "V", ... } into KEY=VALUE lines for env_file.
echo "$SECRET_JSON" | jq -r 'to_entries[] | "\(.key)=\(.value)"' > /opt/microservices/app.env
chmod 600 /opt/microservices/app.env

# Append non-sensitive runtime config and deployment metadata.
cat >> /opt/microservices/app.env <<EOF
LOG_LEVEL=$LOG_LEVEL
FEATURE_FLAGS=$FEATURE_FLAGS
PROJECT_NAME=${project_name}
ENVIRONMENT=${environment}
AWS_REGION=${aws_region}
EOF

echo "=== [6/7] Write docker-compose.yml and start services ==="
cat > /opt/microservices/docker-compose.yml <<'COMPOSE'
version: '3.8'
services:
  service1:
    image: ${service1_image}
    ports:
      - "5000:5000"
    env_file:
      - /opt/microservices/app.env
    environment:
      - FLASK_ENV=production
      - SERVICE_NAME=service1
    restart: unless-stopped
    logging:
      driver: awslogs
      options:
        awslogs-region: ${aws_region}
        awslogs-group: ${log_group_name}
        awslogs-stream-prefix: service1
        awslogs-create-group: "true"
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
    env_file:
      - /opt/microservices/app.env
    environment:
      - FLASK_ENV=production
      - SERVICE_NAME=service2
    restart: unless-stopped
    logging:
      driver: awslogs
      options:
        awslogs-region: ${aws_region}
        awslogs-group: ${log_group_name}
        awslogs-stream-prefix: service2
        awslogs-create-group: "true"
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

echo "=== [7/7] Schedule ECR token refresh every 6 hours ==="
# ECR auth tokens expire after 12 hours; refresh every 6 to be safe.
cat > /etc/cron.d/ecr-login <<'CRON'
0 */6 * * * root aws ecr get-login-password --region ${aws_region} | docker login --username AWS --password-stdin ${ecr_registry} >> /var/log/ecr-refresh.log 2>&1
CRON
chmod 644 /etc/cron.d/ecr-login

echo "=== Bootstrap complete ==="
docker ps
