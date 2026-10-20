# BIND for kcarterlabs.tech on every host in [dns] (ansible/inventory/hosts.ini), deployed from here with Ansible,
# one server at a time. CI (.github/workflows) builds the image and pushes it to ECR on every push to main.
ANSIBLE := cd ansible &&
PLAYBOOK := bind.yml
IMAGE := bind:validate
ECR_REPO := kcarterlabs/bind
ECR_REGION := us-west-2

# FORCE=1 deploys files that aren't committed and pushed (emergencies only).
FORCE_ARGS := $(if $(FORCE),-e bind_allow_unpushed=true,)
# LIMIT=bind-a (or bind-a,bind-b) runs the playbook targets on those only.
LIMIT_ARGS := $(if $(LIMIT),--limit $(LIMIT),)

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
	@python3 -m json.tool .render/daemon.json >/dev/null && echo "daemon.json OK"
	$(ANSIBLE) ansible-playbook pihole.yml --syntax-check >/dev/null && echo "pihole.yml OK"
	@python3 -m py_compile scripts/dns-ask.py scripts/pihole-sync.py && echo "dns-ask.py, pihole-sync.py OK"
	@bash -n entrypoint.sh && bash -n bind-reload.sh && echo "shell syntax OK"
	@docker build -q -t $(IMAGE) . >/dev/null && echo "image builds"
	@docker run --rm --entrypoint bind-reload $(IMAGE) --no-rndc && echo "named-checkzone + named-checkconf OK"

.PHONY: test
test: validate ## Run the image locally: every record, live reload, a bad edit refused, restart on crash
	./scripts/test-local.sh

.PHONY: test-playbook
test-playbook: ## The real playbook vs a fresh Ubuntu VM stand-in and a Docker-in-Docker copy of networkdocker (legacy setup included)
	./scripts/test-playbook.sh

.PHONY: ping
ping: ## Check every server answers and can sudo
	$(ANSIBLE) ansible dns -m ping
	$(ANSIBLE) ansible dns -b -m command -a 'id -un'

.PHONY: preflight
preflight: ## Read-only checks: records lint, pushed, in ECR, Docker, port 53, forwarders answer
	$(ANSIBLE) ansible-playbook $(PLAYBOOK) $(LIMIT_ARGS) --tags always --check

.PHONY: check
check: ## Dry run: preflight (pushed? in ECR?) plus a diff of every file it would write
	$(ANSIBLE) ansible-playbook $(PLAYBOOK) $(LIMIT_ARGS) --check --diff --skip-tags verify $(FORCE_ARGS)

.PHONY: release
release: ## One stop: validate, commit (MSG="..."), push, watch CI push to ECR, check, deploy. YES=1 skips the prompts
	@./scripts/release.sh

.PHONY: deploy
deploy: ## Deploy to each server in turn (Docker, image copied from here, records), verifying each before the next
	$(ANSIBLE) ansible-playbook $(PLAYBOOK) $(LIMIT_ARGS) $(FORCE_ARGS)

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
verify: ## Ask every server for every record in records.yaml, from here
	$(ANSIBLE) ansible-playbook $(PLAYBOOK) $(LIMIT_ARGS) --tags verify

.PHONY: ps
ps: ## Container status on every server
	$(ANSIBLE) ansible dns -b -m command -a 'docker compose --project-directory /opt/bind/compose ps'

.PHONY: logs
logs: ## Last 100 log lines on every server
	$(ANSIBLE) ansible dns -b -m command -a 'docker logs --tail 100 bind'

# ------------------------------------------------------------- Pi-holes ---
# pihole.yml: the Pi-holes BIND forwards to ([pihole]), to the state in
# group_vars/pihole.yml. LIMIT=pihole2 works here too.

.PHONY: test-pihole
test-pihole: ## pihole.yml vs throwaway Pi-hole containers (FTL 6.2.3 and 6.8): plan, apply, changed=0, lists, refusals
	./scripts/test-pihole.sh

.PHONY: pihole-check
pihole-check: ## Dry run: what would change on each Pi-hole (read-only)
	$(ANSIBLE) ansible-playbook pihole.yml $(LIMIT_ARGS) --check

.PHONY: pihole-deploy
pihole-deploy: ## Apply group_vars/pihole.yml, one Pi-hole at a time, each verified before the next
	$(ANSIBLE) ansible-playbook pihole.yml $(LIMIT_ARGS)

.PHONY: pihole-verify
pihole-verify: ## On each Pi-hole: a normal name resolves, a blocklist domain and every deny entry are blocked
	$(ANSIBLE) ansible-playbook pihole.yml $(LIMIT_ARGS) --tags verify
