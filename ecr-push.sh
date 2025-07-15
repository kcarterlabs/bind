aws ecr create-repository --repository-name bind-flask
aws ecr get-login-password | docker login --username AWS --password-stdin <aws_account_id>.dkr.ecr.<region>.amazonaws.com

docker tag bind-flask-image:latest <aws_account_id>.dkr.ecr.<region>.amazonaws.com/bind-flask:latest
docker push <aws_account_id>.dkr.ecr.<region>.amazonaws.com/bind-flask:latest