#!/bin/sh

##
## Non-Kubernetes path: install docker-ce + the compose plugin from Docker's
## apt repository (Blueprint's docker_* wiring specs produce docker-compose
## deployments), and let the swapper use docker without sudo.
##

set -x

if [ -z "$EUID" ]; then
    EUID=`id -u`
fi

# Grab our libs
. "`dirname $0`/setup-lib.sh"

if [ -f $OURDIR/docker-done ]; then
    exit 0
fi

logtstart "docker"

. /etc/os-release

maybe_install_packages ca-certificates curl gnupg lsb-release
$SUDO install -m 0755 -d /etc/apt/keyrings
if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
	| $SUDO gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    $SUDO chmod a+r /etc/apt/keyrings/docker.gpg
fi
ARCHDEB=`dpkg --print-architecture`
echo "deb [arch=${ARCHDEB} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
    | $SUDO tee /etc/apt/sources.list.d/docker.list > /dev/null
$SUDO apt-get update
$SUDO apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# The docker data dir was bind-mounted onto $STORAGEDIR by setup-disk-space.sh;
# make sure the daemon is up and running from there.
$SUDO systemctl enable docker
$SUDO systemctl restart docker
$SUDO usermod -a -G docker $SWAPPER

docker --version
docker compose version

logtend "docker"
touch $OURDIR/docker-done
exit 0
