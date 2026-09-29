#!/usr/bin/env bash
# audiobookshelf.sh - Maintenance d'Audiobookshelf (livres audio et podcasts).
#
# Installation (lien : les mises a jour du depot sont suivies) :
#   ln -s "$PWD/bibliotheque/audiobookshelf" services/audiobookshelf
# Modele de compose : bibliotheque/audiobookshelf/docker-compose.yml
# Reglages a surcharger dans local.conf : voir le bloc « Reglages ».
#
# SPDX-License-Identifier: GPL-3.0-or-later

set -uo pipefail

SERVICE_NAME="audiobookshelf"
: "${ACMECHANIC_HOME:=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)}"
# shellcheck source=../../lib/service.sh
source "${ACMECHANIC_HOME}/lib/service.sh"

# --- Reglages (surchargeables dans local.conf) ---------------------------------
: "${AUDIOBOOKSHELF_PROJET:=$HOME/audiobookshelf}"
: "${AUDIOBOOKSHELF_DONNEES:=$AUDIOBOOKSHELF_PROJET}"
: "${AUDIOBOOKSHELF_URL:=http://127.0.0.1:13378/healthcheck}"
: "${AUDIOBOOKSHELF_CANAL:=latest}"
BACKUP_EXCLURE=('*/cache' '*/logs')
# -------------------------------------------------------------------------------

DOCKER_PROJET="$AUDIOBOOKSHELF_PROJET"
docker_preparer "Audiobookshelf" "$DOCKER_PROJET"
docker_standard audiobookshelf "advplyr/audiobookshelf:$AUDIOBOOKSHELF_CANAL" "$AUDIOBOOKSHELF_URL" \
	"$AUDIOBOOKSHELF_DONNEES" config metadata
docker_terminer "Audiobookshelf" "$DOCKER_PROJET"
