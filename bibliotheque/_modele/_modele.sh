#!/usr/bin/env bash
# _modele.sh - Modele de service Docker Compose pour Acmechanic.
#
# Pour un nouveau service « mon-app » :
#   cp -r bibliotheque/_modele services/mon-app
#   mv services/mon-app/_modele.sh services/mon-app/mon-app.sh
# puis adapter SERVICE_NAME et les reglages ci-dessous (convention
# <NOM>_PROJET / _DONNEES / _URL / _CANAL, voir lib/service.sh).
#
# SPDX-License-Identifier: GPL-3.0-or-later

set -uo pipefail

SERVICE_NAME="mon-app"
: "${ACMECHANIC_HOME:=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)}"
# shellcheck source=../../lib/service.sh
source "${ACMECHANIC_HOME}/lib/service.sh"

# --- Reglages (surchargeables dans local.conf) ---------------------------------
: "${MON_APP_PROJET:=$HOME/mon-app}"                  # dossier du docker-compose.yml
: "${MON_APP_DONNEES:=$MON_APP_PROJET}"               # source des sauvegardes
: "${MON_APP_URL:=http://127.0.0.1:8080/health}"      # sonde HTTP (vide = Docker seul)
: "${MON_APP_CANAL:=latest}"                          # ou un canal de pointe (edge...)
BACKUP_EXCLURE=('*/cache' '*/logs')                    # exclus de l'archive
# -------------------------------------------------------------------------------

DOCKER_PROJET="$MON_APP_PROJET"
docker_preparer "Mon app" "$DOCKER_PROJET"
docker_standard mon-app "editeur/mon-app:$MON_APP_CANAL" "$MON_APP_URL" \
	"$MON_APP_DONNEES" config
docker_terminer "Mon app" "$DOCKER_PROJET"
