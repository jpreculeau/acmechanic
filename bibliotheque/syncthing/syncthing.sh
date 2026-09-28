#!/usr/bin/env bash
# syncthing.sh - Maintenance de Syncthing (synchronisation de fichiers).
#
# Installation (lien : les mises a jour du depot sont suivies) :
#   ln -s ../bibliotheque/syncthing services/syncthing
# Modele de compose : bibliotheque/syncthing/docker-compose.yml
# Reglages a surcharger dans local.conf : voir le bloc « Reglages ».
#
# SPDX-License-Identifier: GPL-3.0-or-later

set -uo pipefail

SERVICE_NAME="syncthing"
: "${ACMECHANIC_HOME:=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)}"
# shellcheck source=../../lib/service.sh
source "${ACMECHANIC_HOME}/lib/service.sh"

# --- Reglages (surchargeables dans local.conf) ---------------------------------
: "${SYNCTHING_PROJET:=$HOME/syncthing}"
: "${SYNCTHING_DONNEES:=$SYNCTHING_PROJET}"   # contient config/ (cles, dossiers)
: "${SYNCTHING_URL:=http://127.0.0.1:8384/rest/noauth/health}"
: "${SYNCTHING_CANAL:=latest}"                # edge = pointe
# -------------------------------------------------------------------------------

DOCKER_PROJET="$SYNCTHING_PROJET"
docker_preparer "Syncthing" "$DOCKER_PROJET"
docker_standard syncthing "syncthing/syncthing:$SYNCTHING_CANAL" "$SYNCTHING_URL" \
	"$SYNCTHING_DONNEES" config
docker_terminer "Syncthing" "$DOCKER_PROJET"
