#!/usr/bin/env bash
# jellyfin.sh - Maintenance de Jellyfin (serveur multimedia).
#
# Installation (lien : les mises a jour du depot sont suivies) :
#   ln -s ../bibliotheque/jellyfin services/jellyfin
# Modele de compose : bibliotheque/jellyfin/docker-compose.yml
# Reglages a surcharger dans local.conf : voir le bloc « Reglages ».
#
# SPDX-License-Identifier: GPL-3.0-or-later

set -uo pipefail

SERVICE_NAME="jellyfin"
: "${ACMECHANIC_HOME:=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)}"
# shellcheck source=../../lib/service.sh
source "${ACMECHANIC_HOME}/lib/service.sh"

# --- Reglages (surchargeables dans local.conf) ---------------------------------
: "${JELLYFIN_PROJET:=$HOME/jellyfin}"
# Dossier monte sur /config (contient config/, data/, plugins/...).
: "${JELLYFIN_DONNEES:=$JELLYFIN_PROJET/config}"
: "${JELLYFIN_URL:=http://127.0.0.1:8096/health}"
: "${JELLYFIN_CANAL:=latest}"        # unstable = builds de nuit
: "${JELLYFIN_SUDO:=non}"            # oui si les donnees appartiennent a root
# Reconstructible ou volumineux : hors sauvegarde.
BACKUP_EXCLURE=('*/trickplay' '*/subtitles' '*/attachments' '*/transcodes'
	'*/temp' '*/cache' 'metadata')
# -------------------------------------------------------------------------------

DOCKER_PROJET="$JELLYFIN_PROJET"
docker_preparer "Jellyfin" "$DOCKER_PROJET"
if [ "$JELLYFIN_SUDO" = oui ]; then
	if ! sudo_disponible; then
		err "sudo demande un mot de passe : sauvegarde de $JELLYFIN_DONNEES impossible."
		exit 1
	fi
	TAR_CMD="sudo tar"
fi
docker_standard jellyfin "jellyfin/jellyfin:$JELLYFIN_CANAL" "$JELLYFIN_URL" \
	"$JELLYFIN_DONNEES" config data plugins
docker_terminer "Jellyfin" "$DOCKER_PROJET"
