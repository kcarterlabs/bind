export CONTAINER_NAME="bind-flask"

docker stop $CONTAINER_NAME
docker rm $CONTAINER_NAME

export IMAGE="bind"

sudo docker build -t $IMAGE .

sudo docker run -d --name $CONTAINER_NAME  \
  -p 53:53/udp \
  -p 53:53/tcp \
  $IMAGE

dig @localhost glados.kcarterlabs.tech
dig @localhost pihole.kcarterlabs.tech