#!/bin/bash
# Set these variables
AWS_REGION="<your-aws-region>"
ECR_REPO="<aws-account-id>.dkr.ecr.$AWS_REGION.amazonaws.com/<your-repo-name>"
IMAGE_TAG="latest"
CONTAINER_NAME="bind-flask"

# Login to ECR
aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $ECR_REPO
# Pull the latest image
docker pull $ECR_REPO:$IMAGE_TAG

# Stop and remove old container
docker stop $CONTAINER_NAME || true
docker rm $CONTAINER_NAME || true

# Run the new container
docker run -d --name $CONTAINER_NAME -p 53:53/udp -p 53:53/tcp $ECR_REPO:$IMAGE_TAG --restart unless-stopped

for name in $(yq '.records[].name' records.yaml); do
  if dig @localhost "${name}.kcarterlabs.tech" +short > /dev/null; then
    echo "✅ SUCCESS: ${name}.kcarterlabs.tech resolved! 🎉"
  else
    echo "❌ FAIL: ${name}.kcarterlabs.tech did not resolve. 😢"
  fi
done