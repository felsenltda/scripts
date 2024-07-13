#!/bin/bash

# ------------------------ FUNÇÕES AUXILIARES

function verificar_erro() {
  if [ $? -ne 0 ]; then
    echo "Erro detectado. Abortando."
    exit 1
  fi
}

function instalar_pacote() {
  pacote=$1
  if ! dpkg -l | grep -q $pacote; then
    sudo apt-get install -y $pacote
    verificar_erro
  else
    echo "$pacote já está instalado."
  fi
}

function alterar_hostname() {
  local novo_hostname=$1
  sudo hostnamectl set-hostname $novo_hostname
  verificar_erro
  
  # Atualizar /etc/hosts
  sudo sed -i "s/127.0.1.1.*/127.0.1.1 $novo_hostname/" /etc/hosts
  verificar_erro
  
  echo "Hostname alterado para $novo_hostname"
}

# ------------------------ VERIFICAÇÃO DE PERMISSÕES

if [ "$EUID" -ne 0 ]; then 
  echo "Por favor, execute como root ou use sudo."
  exit 1
fi

# ------------------------ DECLARAÇÃO DE VARIÁVEIS

echo "Insira o nome do servidor (HOSTNAME):"
read nome_servidor

echo "Insira o domínio do portainer:"
read portainer_dominio

echo "Insira o e-mail do administrador:"
read email_administrador

echo "Insira o nome da rede swarm:"
read nome_rede

# ------------------------ ALTERAR HOSTNAME

alterar_hostname $nome_servidor

# ------------------------ UPDATE E INSTALAÇÃO DE PACOTES

sudo apt-get update
sudo apt-get upgrade -y
instalar_pacote apparmor-utils
instalar_pacote dialog
instalar_pacote git

# ------------------------ INSTALAÇÃO DO DOCKER

curl -fsSL https://get.docker.com -o get-docker.sh
sh get-docker.sh
verificar_erro

sudo systemctl enable docker
sudo systemctl start docker

# ------------------------ INICIALIZAÇÃO DO DOCKER SWARM

docker swarm init
verificar_erro

# ------------------------ CRIANDO REDE DOCKER SWARM

docker network create --driver=overlay $nome_rede
verificar_erro

# ------------------------ CRIANDO YAML TRAEFIK

cat > traefik.yaml << FELSEN
version: "3.7"

services:
  traefik:
    image: traefik:v2.11.2
    command:
      - "--api.dashboard=true"
      - "--providers.docker.swarmMode=true"
      - "--providers.docker.endpoint=unix:///var/run/docker.sock"
      - "--providers.docker.exposedbydefault=false"
      - "--providers.docker.network=$nome_rede"
      - "--entrypoints.web.address=:80"
      - "--entrypoints.web.http.redirections.entryPoint.to=websecure"
      - "--entrypoints.web.http.redirections.entryPoint.scheme=https"
      - "--entrypoints.web.http.redirections.entrypoint.permanent=true"
      - "--entrypoints.websecure.address=:443"
      - "--certificatesresolvers.letsencryptresolver.acme.httpchallenge=true"
      - "--certificatesresolvers.letsencryptresolver.acme.httpchallenge.entrypoint=web"
      - "--certificatesresolvers.letsencryptresolver.acme.email=$email_administrador"
      - "--certificatesresolvers.letsencryptresolver.acme.storage=/etc/traefik/letsencrypt/acme.json"
      - "--log.level=DEBUG"
      - "--log.format=common"
      - "--log.filePath=/var/log/traefik/traefik.log"
      - "--accesslog=true"
      - "--accesslog.filepath=/var/log/traefik/access-log"
    deploy:
      placement:
        constraints:
          - node.role == manager
      labels:
        - "traefik.enable=true"
        - "traefik.http.middlewares.redirect-https.redirectscheme.scheme=https"
        - "traefik.http.middlewares.redirect-https.redirectscheme.permanent=true"
        - "traefik.http.routers.http-catchall.rule=hostregexp(\`{host:.+}\`)"
        - "traefik.http.routers.http-catchall.entrypoints=web"
        - "traefik.http.routers.http-catchall.middlewares=redirect-https@docker"
        - "traefik.http.routers.http-catchall.priority=1"
    volumes:
      - "/var/run/docker.sock:/var/run/docker.sock:ro"
      - "vol_certificates:/etc/traefik/letsencrypt"
    ports:
      - target: 80
        published: 80
        mode: host
      - target: 443
        published: 443
        mode: host
    networks:
      - $nome_rede

volumes:
  vol_shared:
    external: true
    name: volume_swarm_shared
  vol_certificates:
    external: true
    name: volume_swarm_certificates

networks:
  $nome_rede:
    external: true
    name: $nome_rede
FELSEN

# ------------------------ SUBINDO STACK DO TRAEFIK

docker stack deploy --prune --resolve-image always -c traefik.yaml traefik > /dev/null 2>&1
verificar_erro

sleep 30

# ------------------------ CRIANDO YAML PORTAINER

cat > portainer.yaml << FELSEN
version: "3.7"

services:
  agent:
    image: portainer/agent:latest
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /var/lib/docker/volumes:/var/lib/docker/volumes
    networks:
      - $nome_rede
    deploy:
      mode: global
      placement:
        constraints: [node.platform.os == linux]

  portainer:
    image: portainer/portainer-ce:latest
    command: -H tcp://tasks.agent:9001 --tlsskipverify
    volumes:
      - portainer_data:/data
    networks:
      - $nome_rede
    deploy:
      mode: replicated
      replicas: 1
      placement:
        constraints: [node.role == manager]
      labels:
        - "traefik.enable=true"
        - "traefik.docker.network=wasehubnet"
        - "traefik.http.routers.portainer.rule=Host(\`$portainer_dominio\`)"
        - "traefik.http.routers.portainer.entrypoints=websecure"
        - "traefik.http.routers.portainer.priority=1"
        - "traefik.http.routers.portainer.tls.certresolver=letsencryptresolver"
        - "traefik.http.routers.portainer.service=portainer"
        - "traefik.http.services.portainer.loadbalancer.server.port=9000"

networks:
  $nome_rede:
    external: true
    attachable: true
    name: $nome_rede
volumes:
  portainer_data:
    external: true
    name: portainer_data
FELSEN

# ------------------------ SUBINDO STACK DO PORTAINER

docker stack deploy --prune --resolve-image always -c portainer.yaml portainer > /dev/null 2>&1
verificar_erro

sleep 30

# ------------------------

echo "Acesse https://$portainer_dominio para configurar usuário e senha"
