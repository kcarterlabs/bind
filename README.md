# BIND DNS Server with Automated Deployment

## Overview

This project provides a containerized BIND DNS server with automated build and deployment using GitHub Actions and AWS ECR. DNS records are managed via a YAML file and converted to zone files at runtime. The setup supports integration with Pi-hole and automated health checks.

## Features

- BIND 9 DNS server in Docker
- Automated build and push to AWS ECR via GitHub Actions
- Dynamic zone file generation from `records.yaml`
- Automated deployment to local/remote Docker hosts
- Health check and auto-restart via cron
- Easy integration with Pi-hole as upstream DNS

## Project Structure

```
.
├── build.sh              # Build and test the Docker image locally
├── deploy.sh             # Pull from ECR and run the container
├── Dockerfile            # Container build instructions
├── entrypoint.sh         # Entrypoint for zone file generation and BIND startup
├── records.yaml          # DNS records in YAML format
├── zone_converter.py     # Converts YAML records to BIND zone file
├── named.conf.local      # BIND zone configuration
├── named.conf.options    # BIND options (forwarders, etc.)
├── .github/workflows/    # GitHub Actions CI/CD
└── bind-flask/           # Helm chart for Kubernetes deployment
```

## Usage

### 1. Build and Test Locally

```sh
./build.sh
```
- Builds the Docker image and runs the container.
- Tests DNS resolution for all records in `records.yaml`.

### 2. Deploy from AWS ECR

```sh
./deploy.sh
```
- Pulls the latest image from ECR.
- Stops and removes any existing container.
- Runs the new container with `--restart unless-stopped`.
- Tests DNS resolution for all records.

### 3. Automated Health Check

Add this to your crontab (`crontab -e`) to ensure the container is always running:

```sh
* * * * * docker ps --filter "name=bind-flask" --filter "status=running" | grep bind-flask > /dev/null || docker start bind-flask
```

### 4. Change Upstream DNS

Edit `named.conf.options`:

```conf
forwarders {
    10.10.69.72;  # Pi-hole 1
    10.10.69.73;  # Pi-hole 2
};
```

### 5. AWS CLI Setup

Install AWS CLI:

```sh
sudo apt update
sudo apt install awscli
```
Configure credentials:

```sh
aws configure
```

## GitHub Actions

- Builds and tags Docker images with both commit SHA and `latest`.
- Pushes images to AWS ECR.
- Optionally packages and pushes Helm charts.

## Helm Chart

See `bind-flask/` for Kubernetes deployment using Helm.

## Troubleshooting

- Check container logs: `docker logs bind-flask`
- Check BIND logs for zone errors.
- Ensure AWS credentials are configured for ECR access.
- Make sure Pi-hole or other upstream DNS servers are reachable.

## License

MIT (or your preferred license)
