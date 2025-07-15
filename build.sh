sudo docker build -t bind-flask-dns .

sudo docker run -d --rm \
  -p 53:53/udp \
  -p 53:53/tcp \
  -p 5000:5000 \
  -e BIND_ZONE="kcarterlabs.tech" \
  -e BIND_NS_IP="10.0.0.1" \
  -e API_KEY="supersecretdnskey" \
  -v $(pwd)/records.yaml:/data/records.yaml \
  bind-flask-dns

# curl http://localhost:5000/records

# curl -X POST http://localhost:5000/reload

curl -H "X-API-Key: supersecretdnskey" http://localhost:5000/records
