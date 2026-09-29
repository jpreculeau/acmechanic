#!/usr/bin/env bash
# open-webui.sh - Maintenance d'Open WebUI (interface web pour modeles d'IA).
#
# Installation (lien : les mises a jour du depot sont suivies) :
#   ln -s "$PWD/bibliotheque/open-webui" services/open-webui
# Modele de compose : bibliotheque/open-webui/docker-compose.yml
# Reglages a surcharger dans local.conf : voir le bloc « Reglages ».
#
# SPDX-License-Identifier: GPL-3.0-or-later

set -uo pipefail

SERVICE_NAME="open-webui"
: "${ACMECHANIC_HOME:=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)}"
# shellcheck source=../../lib/service.sh
source "${ACMECHANIC_HOME}/lib/service.sh"

# --- Reglages (surchargeables dans local.conf) ---------------------------------
: "${OPEN_WEBUI_PROJET:=$HOME/open-webui}"
: "${OPEN_WEBUI_DONNEES:=$OPEN_WEBUI_PROJET}"
: "${OPEN_WEBUI_URL:=http://127.0.0.1:3080/health}"
: "${OPEN_WEBUI_CANAL:=main}"
BACKUP_EXCLURE=('*/cache' '*/uploads')
# -------------------------------------------------------------------------------

DOCKER_PROJET="$OPEN_WEBUI_PROJET"
docker_preparer "Open WebUI" "$DOCKER_PROJET"
docker_standard open-webui "ghcr.io/open-webui/open-webui:$OPEN_WEBUI_CANAL" "$OPEN_WEBUI_URL" \
	"$OPEN_WEBUI_DONNEES" data
docker_terminer "Open WebUI" "$DOCKER_PROJET"
