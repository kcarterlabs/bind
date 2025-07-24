export CONTAINER_NAME="bind-flask"

export IMAGE="856817629634.dkr.ecr.us-west-2.amazonaws.com/kcarterlabs/bind:191209e7429d1d4f066597ba8a2226633d3c2d91"

aws ecr get-login-password --region us-west-2 \
  | docker login --username AWS \
  --password-stdin 856817629634.dkr.ecr.us-west-2.amazonaws.com

sudo docker run -d --name $CONTAINER_NAME  \
  -p 53:53/udp \
  -p 53:53/tcp \
  $IMAGE

dig @localhost glados.kcarterlabs.tech
dig @localhost pihole.kcarterlabs.tech
