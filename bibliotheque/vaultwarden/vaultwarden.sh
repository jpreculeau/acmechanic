#!/usr/bin/env bash
# vaultwarden.sh - Maintenance de Vaultwarden (gestionnaire de mots de passe).
#
# Installation (lien : les mises a jour du depot sont suivies) :
#   ln -s "$PWD/bibliotheque/vaultwarden" services/vaultwarden
# Modele de compose : bibliotheque/vaultwarden/docker-compose.yml
# Reglages a surcharger dans local.conf : voir le bloc « Reglages ».
#
# SPDX-License-Identifier: GPL-3.0-or-later

set -uo pipefail

SERVICE_NAME="vaultwarden"
: "${ACMECHANIC_HOME:=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)}"
# shellcheck source=../../lib/service.sh
source "${ACMECHANIC_HOME}/lib/service.sh"

# --- Reglages (surchargeables dans local.conf) ---------------------------------
: "${VAULTWARDEN_PROJET:=$HOME/vaultwarden}"
: "${VAULTWARDEN_DONNEES:=$VAULTWARDEN_PROJET}"
: "${VAULTWARDEN_URL:=http://127.0.0.1:8081/alive}"
: "${VAULTWARDEN_CANAL:=latest}"
BACKUP_EXCLURE=('*/icon_cache' '*/tmp')
# -------------------------------------------------------------------------------

DOCKER_PROJET="$VAULTWARDEN_PROJET"
docker_preparer "Vaultwarden" "$DOCKER_PROJET"
docker_standard vaultwarden "vaultwarden/server:$VAULTWARDEN_CANAL" "$VAULTWARDEN_URL" \
	"$VAULTWARDEN_DONNEES" data
docker_terminer "Vaultwarden" "$DOCKER_PROJET"
