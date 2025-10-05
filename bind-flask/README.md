```shell
REGION = "<your-aws-region>"

kubectl create secret docker-registry ecr-pull-secret \
  --docker-server=<your-ecr-url> \
  --docker-username=AWS \
  --docker-password="$(aws ecr get-login-password --region $REGION)" \
  --docker-email=your-email@example.com \
  --namespace=bind
```

```yaml
spec:
  template:
    spec:
      imagePullSecrets:
        - name: ecr-pull-secret
```
