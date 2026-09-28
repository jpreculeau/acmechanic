#!/usr/bin/env bash
# docker-exemple.sh - Modele de service Docker Compose pour Acmechanic.
#
# Copier ce dossier dans services/<nom>/ et renommer le script en
# <nom>.sh (le script doit porter le nom de son dossier), puis adapter
# les variables ci-dessous. Voir maintenir_service_docker (lib/common.sh) :
# sauvegarde, mise a jour de l'image SEULEMENT si le registre a une
# version plus recente (ou si la config compose a change, ou si le
# conteneur est arrete), redemarrage et verification de sante.
#
# SPDX-License-Identifier: GPL-3.0-or-later

set -uo pipefail

SERVICE_NAME="docker-exemple"
# Lance seul (hors Acmechanic) : la racine est deux dossiers au-dessus.
: "${ACMECHANIC_HOME:=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)}"
export ACMECHANIC_HOME
# shellcheck source=../../../lib/common.sh
source "${ACMECHANIC_HOME}/lib/common.sh"
# shellcheck source=../../../config.sh
source "${ACMECHANIC_HOME}/config.sh"
# shellcheck source=../../../lib/backup.sh
source "${ACMECHANIC_HOME}/lib/backup.sh"

prendre_verrou "$SERVICE_NAME"

# --- A adapter -----------------------------------------------------------------
PROJET="$HOME/mon-app"                 # dossier du docker-compose.yml
CONTENEUR="mon-app"                    # nom du service dans le compose
DONNEES="$HOME/mon-app"                # dossier source de la sauvegarde
ELEMENTS=(config)                      # chemins relatifs a DONNEES a archiver
URL="http://127.0.0.1:8080/health"     # sonde HTTP (vide = healthcheck Docker seul)
# Image de reference sur Docker Hub. Avec un tag de pointe (ex. :edge),
# choisir_tag retient le plus recent entre ce tag et « latest ».
IMAGE_REF="editeur/mon-app:latest"
# -------------------------------------------------------------------------------

titre "MAINTENANCE ${CONTENEUR^^}"

if ! verifier_commandes docker curl tar; then
	err "Dependances manquantes, arret."
	exit 1
fi

if [ ! -f "$PROJET/docker-compose.yml" ]; then
	err "Fichier $PROJET/docker-compose.yml introuvable, arret."
	exit 1
fi

# Exporte pour le compose : image: editeur/mon-app:${APP_TAG:-latest}
APP_TAG="$(choisir_tag "$IMAGE_REF")"
export APP_TAG
log "Tag resolu = $APP_TAG"

maintenir_service_docker "$PROJET" "$CONTENEUR" "$URL" "${IMAGE_REF%:*}:${APP_TAG}" \
	oui "$DONNEES" "${ELEMENTS[@]}"

if [ "$NB_ECHEC" -gt 0 ]; then
	echo
	warn "Dernieres lignes du journal :"
	compose "$PROJET" logs --tail=20 2>&1 | sed 's/^/    /'
fi

bilan_service "Bilan de la maintenance $CONTENEUR"
exit $?
