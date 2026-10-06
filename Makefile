SHELL    := /bin/bash
REGISTRY ?= registry.local:5000
TAG      ?= v1
HOST     ?= nebula.local

.DEFAULT_GOAL := help
.PHONY: help dev dev-down build edge deploy status smoke clean

help: ## Affiche cette aide
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[1m%-10s\033[0m %s\n",$$1,$$2}'

dev: ## Lance les 7 services en local, hors Swarm (verification rapide)
	docker compose -f compose.dev.yml up --build -d && docker compose -f compose.dev.yml ps
dev-down: ## Arrete l'environnement local
	docker compose -f compose.dev.yml down
build: ## Construit et pousse les 3 images
	REGISTRY=$(REGISTRY) bash ./scripts/build-push.sh $(TAG)
edge: ## Deploie le point d'entree Traefik (cree aussi le reseau edge_public)
	REGISTRY=$(REGISTRY) docker stack deploy \
	  -c swarm/stack.edge.yml --with-registry-auth edge
deploy: ## Deploie Nebula dans la version TAG
	REGISTRY=$(REGISTRY) TAG=$(TAG) docker stack deploy \
	  -c swarm/stack.nebula.yml --with-registry-auth nebula
status: ## Services, instances, versions et ports publies
	docker service ls --format 'table {{.Name}}\t{{.Replicas}}\t{{.Image}}\t{{.Ports}}'
smoke: ## Verifie la chaine complete
	bash ./scripts/smoke.sh $(HOST)
clean: ## Retire les deux stacks (volumes et secrets conserves)
	docker stack rm nebula edge
