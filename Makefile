# BIND for kcarterlabs.tech on networkdocker (10.10.69.21), deployed from here with Ansible.
# CI (.github/workflows) still builds the same image and pushes it to ECR on every push to main.
ANSIBLE := cd ansible &&
PLAYBOOK := bind.yml
IMAGE := bind:validate
ECR_REPO := kcarterlabs/bind
ECR_REGION := us-west-2

# FORCE=1 deploys files that aren't committed and pushed (emergencies only).
FORCE_ARGS := $(if $(FORCE),-e bind_allow_unpushed=true,)

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	 | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

.PHONY: deps
deps: ## Install required Ansible collections
	$(ANSIBLE) ansible-galaxy collection install -r requirements.yml

.PHONY: lint
lint: ## Lint records.yaml only (fast; what to run after editing it)
	@python3 scripts/check-records.py records.yaml

.PHONY: validate
validate: lint ## Lint, Ansible syntax, render compose, build the image, named-checkzone + named-checkconf in it. Changes nothing remote.
	$(ANSIBLE) ansible-playbook $(PLAYBOOK) --syntax-check >/dev/null && echo "ansible OK"
	@rm -rf .render
	$(ANSIBLE) ansible-playbook render.yml >/dev/null && echo "compose rendered to .render/"
	@docker compose -f .render/compose.yaml config -q && echo "compose OK"
	@bash -n entrypoint.sh && bash -n bind-reload.sh && echo "shell syntax OK"
	@docker build -q -t $(IMAGE) . >/dev/null && echo "image builds"
	@docker run --rm --entrypoint bind-reload $(IMAGE) --no-rndc && echo "named-checkzone + named-checkconf OK"

.PHONY: test
test: validate ## Run the image locally: every record, live reload, a bad edit refused, restart on crash
	./scripts/test-local.sh

.PHONY: test-playbook
test-playbook: ## Run the real playbook against a throwaway Docker-in-Docker "networkdocker", legacy setup included
	./scripts/test-playbook.sh

.PHONY: ping
ping: ## Check the server answers and can sudo
	$(ANSIBLE) ansible dns -m ping
	$(ANSIBLE) ansible dns -b -m command -a 'id -un'

.PHONY: preflight
preflight: ## Read-only checks: records lint, Docker, port 53
	$(ANSIBLE) ansible-playbook $(PLAYBOOK) --tags always --check

.PHONY: check
check: ## Dry run: preflight (pushed? in ECR?) plus a diff of every file it would write
	$(ANSIBLE) ansible-playbook $(PLAYBOOK) --check --diff --skip-tags verify $(FORCE_ARGS)

.PHONY: deploy
deploy: ## Pull this commit's image from ECR and deploy it, then verify. First run replaces bind-flask and its cron jobs
	$(ANSIBLE) ansible-playbook $(PLAYBOOK) $(FORCE_ARGS)

.PHONY: image-tag
image-tag: ## The ECR tag this checkout deploys (code-<hash>)
	@scripts/image-tag.sh

.PHONY: ecr-images
ecr-images: ## The last 10 images CI pushed
	@aws ecr describe-images --region $(ECR_REGION) --repository-name $(ECR_REPO) \
	  --query 'reverse(sort_by(imageDetails,&imagePushedAt))[:10].[imagePushedAt,join(`,`,imageTags||[`untagged`])]' --output text

.PHONY: ecr-policy
ecr-policy: ## Apply ecr-lifecycle-policy.json (keep the last 30 images) to the ECR repository
	aws ecr put-lifecycle-policy --region $(ECR_REGION) --repository-name $(ECR_REPO) \
	  --lifecycle-policy-text file://ecr-lifecycle-policy.json --query registryId --output text >/dev/null \
	  && echo "lifecycle policy applied to $(ECR_REPO)"

.PHONY: verify
verify: ## Ask the server for every record in records.yaml, from here
	$(ANSIBLE) ansible-playbook $(PLAYBOOK) --tags verify

.PHONY: ps
ps: ## Container status on the server
	$(ANSIBLE) ansible dns -b -m command -a 'docker compose --project-directory /opt/bind/compose ps'

.PHONY: logs
logs: ## Last 100 log lines on the server
	$(ANSIBLE) ansible dns -b -m command -a 'docker logs --tail 100 bind'
