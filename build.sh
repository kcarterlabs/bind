export CONTAINER_NAME="bind-flask"

docker stop $CONTAINER_NAME
docker rm $CONTAINER_NAME

export IMAGE="bind"

sudo docker build -t $IMAGE .

sudo docker run -d --name $CONTAINER_NAME  \
  -p 53:53/udp \
  -p 53:53/tcp \
  $IMAGE


for name in $(yq '.records[].name' records.yaml); do
  if dig @localhost "${name}.kcarterlabs.tech" +short > /dev/null; then
    echo "✅ SUCCESS: ${name}.kcarterlabs.tech resolved! 🎉"
  else
    echo "❌ FAIL: ${name}.kcarterlabs.tech did not resolve. 😢"
  fi
done

#dig @localhost glados.kcarterlabs.tech
#dig @localhost pihole.kcarterlabs.tech
#dig @localhost 1u-pve.kcarterlabs.tech
#dig @localhost argocd.kcarterlabs.tech
#dig @localhost rancher.kcarterlabs.tech
#dig @localhost truenas.kcarterlabs.tech
#dig @localhost hermes.kcarterlabs.tech
#dig @localhost unifi.kcarterlabs.tech
#dig @localhost truenasbackup.kcarterlabs.tech
#dig @localhost proxmoxdev.kcarterlabs.tech