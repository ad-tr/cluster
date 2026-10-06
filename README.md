# Nebula

Déploiement et exploitation d'un réseau social sur un cluster Docker Swarm de
trois machines. Le code applicatif est celui du starter fourni : **tout le
travail de ce dépôt est de l'infrastructure**.

| | |
|---|---|
| Orchestrateur | Docker Swarm, Docker Engine 29.8 |
| Cluster | 1 gestionnaire, 2 exécutants, plus 1 machine pour le registry |
| Services | 7 : `edge`, `comptes`, `publications`, `worker-medias`, `db`, `cache`, `bus` |
| Point d'entrée | Traefik 3.6, un seul port publié (80) |

## Sommaire

1. [Architecture](#1-architecture)
2. [Choix et limites assumées](#2-choix-et-limites-assumées)
3. [Construire le cluster](#3-construire-le-cluster)
4. [Les cinq procédures](#4-les-cinq-procédures)
5. [Observer](#5-observer)
6. [Vérifier : les dix scénarios](#6-vérifier--les-dix-scénarios)
7. [Ajouter un service](#7-ajouter-un-service)
8. [Développement local](#8-développement-local)
9. [Contenu du dépôt](#9-contenu-du-dépôt)

---

## 1. Architecture

### Les machines

```
poste ──> réseau du labo
              │
          routeur (passerelle et DNS du réseau 10.96.248.0/24)
              │
   ┌──────────┼────────────┬───────────────┐
manager    worker1      worker2         registry
  .11        .12          .13             .20
gestionnaire exécutant   exécutant      hors Swarm
└─────────── Swarm ───────────┘
```

Quatre machines virtuelles Debian 13, 2 vCPU, 2 Go de RAM, 20 Go de disque,
adresses fixes.

| Machine | Rôle | Étiquettes |
|---|---|---|
| `manager` | gestionnaire du Swarm, héberge Traefik | |
| `worker1` | exécutant, héberge la base | `db=true`, `zone=dmz` |
| `worker2` | exécutant, héberge le bus | `zone=internal` |
| `registry` | registry d'images, hors du cluster | |

### Les services

| Service | Rôle | Instances | Placement | Mémoire max |
|---|---|---:|---|---|
| `traefik` (`edge`) | point d'entrée HTTP, seul port publié | 1 | gestionnaire | |
| `comptes` | création et lecture de comptes | 3 | exécutants | 256 Mo |
| `publications` | publication et lecture du fil | 3 | exécutants | 256 Mo |
| `worker-medias` | consomme les événements | 2 | exécutants | 256 Mo |
| `db` | PostgreSQL 18, données durables | 1 | `node.labels.db == true` | 512 Mo |
| `cache` | Redis, cache de lecture du fil | 1 | exécutants | 128 Mo |
| `bus` | RabbitMQ, file d'événements | 1 | `node.labels.zone == internal` | 512 Mo |

Deux stacks : `edge` (Traefik) et `nebula` (les six autres). L'application se
redéploie sans toucher au point d'entrée.

### Les réseaux et les flux

```
                 port 80 (seul port publié du cluster)
                              │
                          Traefik
        ══════════════════════╪══════════════════  edge_public
                 ┌────────────┴───────────┐
              comptes                publications
        ═════════╪════════════════════════╪══════  nebula_interne (internal)
                 │              ┌─────────┼───────────┬──────────┐
                 db             db      cache      comptes      bus
                                                                 │
                                                           worker-medias
```

| Réseau | Rôle | Services |
|---|---|---|
| `edge_public` | flux venant de l'extérieur | `traefik`, `comptes`, `publications` |
| `nebula_interne` | échanges internes, déclaré `internal: true` | les six services de la stack `nebula` |

La base, le cache et le bus ne sont que sur le réseau interne, qui n'a aucune
sortie vers l'extérieur.

### Le routage

Chaque service déclare son routage dans ses propres étiquettes Traefik.

| Adresse | Service |
|---|---|
| `nebula.local/api/comptes...` | `comptes` |
| `nebula.local/api/publications`, `/api/fil`, `/api/health` | `publications` |
| `traefik.local` | tableau de bord Traefik, protégé par mot de passe |

Sur le poste qui consulte : `<IP d'un nœud>  nebula.local traefik.local`
dans `/etc/hosts`.

---

## 2. Choix et limites assumées

**Topologie : un gestionnaire, deux exécutants.** Avec trois nœuds, trois
gestionnaires toléreraient la perte d'un (quorum de 2 sur 3). Le choix d'un
seul gestionnaire garde deux machines entièrement disponibles pour la charge
et un cluster simple à raisonner. Limite : si `manager` tombe, les tâches
déjà lancées continuent de tourner, mais plus rien n'est orchestré et le
point d'entrée, épinglé sur lui, ne répond plus.

**Registry hors du cluster.** Pour redémarrer le cluster il faut tirer les
images, et pour tirer les images il faudrait que le cluster tourne. Le
registry vit donc sur sa propre machine, lancé par `docker compose`. Toutes
les images y sont, y compris Postgres, Redis, RabbitMQ et Traefik : le
cluster ne dépend d'aucun registry extérieur. Limite : c'est un point de
défaillance unique, en HTTP sur un réseau privé.

**Secrets.** Les mots de passe de la base, du bus et du cache sont générés
aléatoirement et rangés dans des secrets Swarm : personne ne les connaît et
aucun n'est dans ce dépôt. Le bus et le cache attendent leur mot de passe
dans une variable : il est lu dans le secret au démarrage du conteneur.

**Mises à jour.** Services sans état en `start-first`, une instance à la fois,
retour arrière automatique. Les instances attendent 15 secondes avant de
s'arrêter, le temps que Traefik les retire de sa liste : sans ce délai, deux
requêtes sur 300 se perdaient pendant une mise à jour.

**Données.** La base et le bus ont un volume local et sont épinglés par
étiquette sur leur machine. Le cache est volatil, par choix. Les traces du
worker sont écrites dans le conteneur : elles prouvent le traitement, ce ne
sont pas des données à conserver.

**Écarts par rapport au starter.**

| Fichier | Écart | Raison |
|---|---|---|
| `swarm/stack.nebula.todo.yml` | laissé tel que fourni, vide | la stack est dans `swarm/stack.nebula.yml` |
| `swarm/stack.edge.yml` | Traefik v3.3 remplacé par v3.6 | la v3.3 ne sait pas parler à Docker Engine 29 (`client version 1.24 is too old`) |
| `swarm/stack.edge.yml` | port 8088 et `--api.insecure` retirés, tableau de bord derrière un mot de passe | un seul port publié, accès d'administration protégé |
| `compose.dev.yml` | mots de passe lus dans un fichier `.env` | aucun identifiant dans le dépôt |
| `Makefile` | cibles `edge` et `deploy` alignées sur les commandes réelles | le réseau `edge_public` est créé par la stack `edge` |

**Environnement.** Les machines virtuelles sont sur un hyperviseur Proxmox
de laboratoire et non sur le poste, derrière un routeur.

---

## 3. Construire le cluster

Depuis zéro. Adresses à adapter.

### Les machines

Quatre machines Debian 13 avec une adresse fixe, sur le même réseau. Sur
chacune, installer Docker Engine depuis le dépôt officiel :

```bash
sudo apt-get update && sudo apt-get install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker "$USER"
```

Si les machines sont clonées d'un même modèle, régénérer leur identifiant :
`sudo rm -f /etc/machine-id && sudo systemd-machine-id-setup && sudo reboot`.

### Le Swarm

```bash
# sur manager
docker swarm init --advertise-addr 10.96.248.11
# sur worker1 et worker2, avec la commande affichée par la précédente
docker swarm join --token <jeton> 10.96.248.11:2377
# sur manager
docker node update --label-add db=true --label-add zone=dmz worker1
docker node update --label-add zone=internal worker2
docker node ls
```

Ports à laisser passer entre les nœuds : 2377/tcp, 7946/tcp et udp, 4789/udp.
Vérifier le dernier avant tout déploiement : un service de test publié doit
répondre sur les trois nœuds.

```bash
docker service create --name test --replicas 1 --publish 8080:80 nginx:alpine
for ip in 11 12 13; do curl -s -o /dev/null -w "10.96.248.$ip -> %{http_code}\n" http://10.96.248.$ip:8080; done
docker service rm test
```

### Le registry

Sur la machine `registry`, avec le dossier `registry/` de ce dépôt :

```bash
cd registry && mkdir -p auth
docker run --rm --entrypoint htpasswd httpd:2.4-alpine -Bbn nebula '<mot de passe>' > auth/htpasswd
docker compose up -d
```

Sur `manager`, `worker1` et `worker2`, une machine à la fois :

```bash
echo "10.96.248.20 registry.local" | sudo tee -a /etc/hosts
echo '{ "insecure-registries": ["registry.local:5000"] }' | sudo tee /etc/docker/daemon.json
sudo systemctl restart docker
```

Sur des machines configurées par Cloud-Init, écrire aussi la ligne dans
`/etc/cloud/templates/hosts.debian.tmpl`, sinon elle disparaît au redémarrage.

Copier dans le registry les images extérieures, depuis `manager` après
`docker login registry.local:5000 -u nebula` :

```bash
for img in postgres:18-alpine redis:7-alpine rabbitmq:4-management-alpine; do
  docker pull $img && docker tag $img registry.local:5000/$img && docker push registry.local:5000/$img
done
docker pull ghcr.io/traefik/traefik:v3.6
docker tag ghcr.io/traefik/traefik:v3.6 registry.local:5000/traefik:v3.6
docker push registry.local:5000/traefik:v3.6
```

---

## 4. Les cinq procédures

Toutes se lancent sur `manager`, à la racine du dépôt, sauf mention contraire.

### 4.1 Déploiement initial

```bash
docker login registry.local:5000 -u nebula
REGISTRY=registry.local:5000 bash scripts/build-push.sh v1
for s in pg_password bus_password cache_password; do openssl rand -hex 16 | docker secret create $s -; done
printf 'admin:%s\n' "$(openssl passwd -apr1)" | docker secret create traefik_users -
REGISTRY=registry.local:5000 docker stack deploy -c swarm/stack.edge.yml --with-registry-auth edge
REGISTRY=registry.local:5000 TAG=v1 docker stack deploy -c swarm/stack.nebula.yml --with-registry-auth nebula
docker stack services nebula          # attendre 3/3, 3/3, 2/2, 1/1, 1/1, 1/1
bash scripts/smoke.sh nebula.local
```

Si les secrets existent déjà, sauter les lignes 3 et 4. Redéployer après un
`docker stack rm nebula edge` ne demande que les lignes 5 à 8 : volumes et
secrets sont conservés.

### 4.2 Mise à jour

```bash
REGISTRY=registry.local:5000 bash scripts/build-push.sh v2
REGISTRY=registry.local:5000 TAG=v2 docker stack deploy -c swarm/stack.nebula.yml --with-registry-auth nebula
docker service ps nebula_publications --format 'table {{.Name}}\t{{.Image}}\t{{.CurrentState}}' | head -8
docker service inspect nebula_publications --format '{{.UpdateStatus.State}}'   # attendre completed
curl -s http://nebula.local/api/health                                          # la version servie
```

Une instance à la fois, la nouvelle avant l'ancienne. En cas d'échec, le
Swarm revient seul à la version précédente.

### 4.3 Retour arrière

```bash
docker service inspect nebula_publications --format '{{.UpdateStatus.State}} : {{.UpdateStatus.Message}}'
docker service ps nebula_publications --no-trunc | head -6
docker service logs --tail 30 nebula_publications
docker service rollback nebula_publications
docker service ps nebula_publications --filter desired-state=running
```

Les trois premières lignes constatent, localisent et donnent la cause. Pour
ramener toute l'application à une version : redéployer avec l'ancien `TAG`.

### 4.4 Arrêt et redémarrage du cluster

```bash
sudo poweroff        # sur worker2, puis worker1, puis manager
```

Rallumer `registry` si elle était éteinte, puis `manager`, `worker1`,
`worker2`. Aucune commande à taper : le cluster se reforme seul.

```bash
docker node ls                        # trois nœuds Ready, manager Leader
docker stack services nebula          # tous au complet en deux minutes environ
bash scripts/smoke.sh nebula.local
```

### 4.5 Sauvegarde et restauration des données

Sur `worker1`, là où tourne la base.

```bash
C=$(docker ps -q -f name=nebula_db)
mkdir -p ~/sauvegardes && F=~/sauvegardes/nebula-$(date +%Y%m%d-%H%M%S).sql
docker exec "$C" pg_dump -U nebula -d nebula > "$F"                      # sauvegarder
docker exec "$C" createdb -U nebula nebula_restauree                     # tester : restaurer à côté
docker exec -i "$C" psql -U nebula -d nebula_restauree -q -v ON_ERROR_STOP=1 < "$F"
docker exec "$C" psql -U nebula -d nebula_restauree -c 'SELECT count(*) FROM publications'
docker exec "$C" dropdb -U nebula nebula_restauree
docker exec -i "$C" psql -U nebula -d nebula < "$F"                      # vraie panne : base revenue vide
```

La dernière ligne ne sert qu'après la perte du volume. La restauration a été
testée dans une base à côté et vérifiée par comparaison du contenu.

---

## 5. Observer

```bash
docker service ls --format 'table {{.Name}}\t{{.Replicas}}\t{{.Image}}\t{{.Ports}}'
docker stack ps nebula --filter desired-state=running --format 'table {{.Name}}\t{{.Node}}\t{{.Image}}'
docker service logs --tail 30 nebula_publications
docker service logs -f nebula_worker-medias
curl -s http://nebula.local/api/health
```

La première répond en une commande à : quels services, combien d'instances,
quelle version, quels ports. La deuxième ajoute : sur quelles machines.

Attention : `docker service ls` montre la version **demandée**. Pendant une
mise à jour en échec, c'est `docker service ps` qui montre celle qui sert.

---

## 6. Vérifier : les dix scénarios

Joués le 6 octobre 2026.

| # | Scénario | Commande de preuve | Résultat |
|---|---|---|---|
| 1 | Un seul cluster | `docker node ls` | 3 nœuds `Ready`, `manager` `Leader` |
| 2 | Arrêt et redémarrage complet | procédure 4.4 | cluster reformé seul, données intactes |
| 3 | Déploiement depuis zéro | `docker stack rm nebula edge` puis 4.1 | 108 s jusqu'au retour complet |
| 4 | Contrôle de l'exposition | `docker service ls`, test des ports | seul le port 80 répond |
| 5 | Placement cohérent | `docker stack ps nebula`, contraintes | base sur `worker1`, bus sur `worker2` |
| 6 | Montée en charge | `docker service scale nebula_publications=6` | 6 instances, 5 réponses chacune sur 30 |
| 7 | Mise à jour sans interruption | 500 requêtes pendant 4.2 | 500 réponses 200 sur 500 |
| 8 | Version défectueuse, retour arrière | `scenarios/version-cassee`, puis 4.3 | 17 s en automatique, 40 s à la main, 0 requête perdue |
| 9 | Panne du plan de données | procédure 4.5 | restauration identique à l'original |
| 10 | Ajout d'un service | section 7 | 75 s, les autres services non redémarrés |

Contrôle de l'exposition :

```bash
for p in 80 5432 5672 6379; do timeout 2 bash -c "</dev/tcp/10.96.248.12/$p" 2>/dev/null && echo "port $p : ouvert" || echo "port $p : fermé"; done
```

Tir de requêtes pendant une mise à jour :

```bash
for i in $(seq 1 500); do curl -s -o /dev/null -w "%{http_code}\n" --max-time 3 http://nebula.local/api/health; sleep 0.5; done | sort | uniq -c
```

---

## 7. Ajouter un service

Sans toucher aux autres services ni à la stack `edge`.

1. Publier son image dans le registry.
2. Copier le bloc `comptes` dans `swarm/stack.nebula.yml`, et changer le nom,
   l'image, le nom du routeur, la règle de routage et le port.
3. Redéployer avec la commande de mise à jour.

```yaml
  whoami:
    image: ${REGISTRY:-registry.local:5000}/whoami:v1
    networks: [edge_public]
    deploy:
      <<: *sans-etat
      replicas: 2
      labels:
        - traefik.enable=true
        - traefik.swarm.network=edge_public
        - traefik.http.routers.whoami.rule=Host(`nebula.local`) && PathPrefix(`/api/whoami`)
        - traefik.http.routers.whoami.entrypoints=web
        - traefik.http.services.whoami.loadbalancer.server.port=80
```

C'est possible parce que les réglages communs sont factorisés dans
`x-sans-etat`, que les réseaux existent déjà, et que Traefik découvre les
services par leurs étiquettes.

---

## 8. Développement local

Hors Swarm, pour vérifier que le code n'est pas en cause.

```bash
cp .env.example .env      # y choisir les mots de passe locaux
make dev
curl -X POST localhost:3001/comptes -H 'content-type: application/json' -d '{"pseudo":"moi"}'
curl -X POST localhost:3002/publications -H 'content-type: application/json' -d '{"auteur_id":1,"titre":"salut"}'
curl localhost:3002/fil
make dev-down
```

## 9. Contenu du dépôt

```
swarm/stack.nebula.yml     la stack Nebula : six services, réseaux, secrets
swarm/stack.edge.yml       le point d'entrée Traefik
registry/compose.yaml      le registry, hors du cluster
scenarios/version-cassee/  image volontairement cassée, pour le scénario 8
scripts/build-push.sh      construit et publie les trois images
scripts/smoke.sh           vérifie la chaîne complète
services/                  les trois services applicatifs (fournis)
db/init.sql                schéma de la base
compose.dev.yml            développement local, hors Swarm
Makefile                   raccourcis : make help
```

Aucun secret n'est versionné : voir `.gitignore`.
