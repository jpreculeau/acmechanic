#!/usr/bin/env bash
# portainer.sh - Maintenance de Portainer CE (administration Docker).
#
# Installation (lien : les mises a jour du depot sont suivies) :
#   ln -s "$PWD/bibliotheque/portainer" services/portainer
# Modele de compose : bibliotheque/portainer/docker-compose.yml
# Reglages a surcharger dans local.conf : voir le bloc « Reglages ».
#
# SPDX-License-Identifier: GPL-3.0-or-later

set -uo pipefail

SERVICE_NAME="portainer"
: "${ACMECHANIC_HOME:=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)}"
# shellcheck source=../../lib/service.sh
source "${ACMECHANIC_HOME}/lib/service.sh"

# --- Reglages (surchargeables dans local.conf) ---------------------------------
: "${PORTAINER_PROJET:=$HOME/portainer}"
: "${PORTAINER_DONNEES:=$PORTAINER_PROJET}"
: "${PORTAINER_URL:=http://127.0.0.1:9000/api/system/status}"
: "${PORTAINER_CANAL:=latest}"
# -------------------------------------------------------------------------------

DOCKER_PROJET="$PORTAINER_PROJET"
docker_preparer "Portainer" "$DOCKER_PROJET"
docker_standard portainer "portainer/portainer-ce:$PORTAINER_CANAL" "$PORTAINER_URL" \
	"$PORTAINER_DONNEES" data
docker_terminer "Portainer" "$DOCKER_PROJET"
