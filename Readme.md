### Use: 
```shell 
docker run --rm -p 53:53/udp -p 53:53 \
  -e BIND_ZONE="kcarterlabs.tech" \
  -e BIND_NS_IP="10.0.0.1" \
  -e API_KEY=supersecretdnskey
#   -e BIND_RECORDS=$'www IN A 10.0.0.10\nmail IN A 10.0.0.20' \
  my-bind-image
```

| Variable          | Purpose                                    | Example                                |
| ----------------- | ------------------------------------------ | -------------------------------------- |
| `BIND_ZONE`       | DNS zone name                              | `example.com`                          |
| `BIND_NS_IP`      | IP address for the NS record               | `192.168.1.1`                          |
| `BIND_TTL`        | Time-to-live for zone records              | `3600`                                 |
| `BIND_RECORDS`    | Additional DNS records (newline delimited) | `'www IN A 1.2.3.4\napi IN CNAME www'` |
| `BIND_NAMED_CONF` | Full override of named.conf.local          | (optional)                             |

curl -H "X-API-Key: supersecretdnskey" http://localhost:5000/records


curl -X POST http://localhost:5000/records \
  -H 'Content-Type: application/json' \
  -H 'X-API-Key: supersecretdnskey' \
  -d '{"ttl": 300, "ns_ip": "10.0.0.1", "records": [{"name": "test", "type": "A", "value": "1.2.3.4"}]}'

curl -XH "X-API-Key: supersecretdnskey" http://localhost:5000/records
{"ns_ip":"10.10.69.72","records":[{"name":"testicle","type":"A","value":"192.168.10.2"}],"ttl":300}

curl -X POST http://localhost:5000/records \
  -H 'Content-Type: application/json' \
  -H 'X-API-Key: supersecretdnskey' \
  -d '{"ttl": 300, "ns_ip": "10.10.69.72", "records": [{"name": "testicle", "type": "A", "value": "192.168.10.2"}]}'

sudo docker run --rm \
  -p 53:53/udp \
  -p 53:53/tcp \
  -p 5000:5000 \
  -e BIND_ZONE="kcarterlabs.tech" \
  -e BIND_NS_IP="10.0.0.1" \
  -e API_KEY="supersecretdnskey" \
  -v $(pwd)/records.yaml:/data/records.yaml \
  bind-flask-dns

kubectl apply -f bind-flask/templates/test-dig-pod.yaml
kubectl exec -it dig-test -- dig @bind-flask.kube-system test.kcarterlabs.tech
