#!/usr/bin/env bash
# plex.sh - Maintenance de Plex Media Server.
#
# Installation (lien : les mises a jour du depot sont suivies) :
#   ln -s "$PWD/bibliotheque/plex" services/plex
# Modele de compose : bibliotheque/plex/docker-compose.yml
# Reglages a surcharger dans local.conf : voir le bloc « Reglages ».
#
# SPDX-License-Identifier: GPL-3.0-or-later

set -uo pipefail

SERVICE_NAME="plex"
: "${ACMECHANIC_HOME:=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)}"
# shellcheck source=../../lib/service.sh
source "${ACMECHANIC_HOME}/lib/service.sh"

# --- Reglages (surchargeables dans local.conf) ---------------------------------
: "${PLEX_PROJET:=$HOME/plex}"
: "${PLEX_DONNEES:=$PLEX_PROJET}"
: "${PLEX_URL:=http://127.0.0.1:32400/identity}"
: "${PLEX_CANAL:=latest}"
BACKUP_EXCLURE=('*/Cache' '*/Crash Reports' '*/Logs' '*/Media' '*/Metadata' '*/Codecs' '*/Updates')
# -------------------------------------------------------------------------------

DOCKER_PROJET="$PLEX_PROJET"
docker_preparer "Plex" "$DOCKER_PROJET"
docker_standard plex "plexinc/pms-docker:$PLEX_CANAL" "$PLEX_URL" \
	"$PLEX_DONNEES" config
docker_terminer "Plex" "$DOCKER_PROJET"
