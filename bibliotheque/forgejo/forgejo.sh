#!/usr/bin/env bash
# forgejo.sh - Maintenance de Forgejo (forge Git auto-hebergee).
#
# Installation (lien : les mises a jour du depot sont suivies) :
#   ln -s "$PWD/bibliotheque/forgejo" services/forgejo
# Modele de compose : bibliotheque/forgejo/docker-compose.yml
# Reglages a surcharger dans local.conf : voir le bloc « Reglages ».
#
# SPDX-License-Identifier: GPL-3.0-or-later

set -uo pipefail

SERVICE_NAME="forgejo"
: "${ACMECHANIC_HOME:=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)}"
# shellcheck source=../../lib/service.sh
source "${ACMECHANIC_HOME}/lib/service.sh"

# --- Reglages (surchargeables dans local.conf) ---------------------------------
: "${FORGEJO_PROJET:=$HOME/forgejo}"
: "${FORGEJO_DONNEES:=$FORGEJO_PROJET}"
: "${FORGEJO_URL:=http://127.0.0.1:3000/api/healthz}"
: "${FORGEJO_CANAL:=11}"
BACKUP_EXCLURE=('*/log' '*/tmp' '*/sessions' '*/queues')
# Version majeure suivie (pas « latest ») : une majeure se migre a la main.
# -------------------------------------------------------------------------------

DOCKER_PROJET="$FORGEJO_PROJET"
docker_preparer "Forgejo" "$DOCKER_PROJET"
docker_standard forgejo "codeberg.org/forgejo/forgejo:$FORGEJO_CANAL" "$FORGEJO_URL" \
	"$FORGEJO_DONNEES" data
docker_terminer "Forgejo" "$DOCKER_PROJET"
