#!/usr/bin/env bash
# cross-seed.sh - Maintenance de cross-seed.
#
# Avant la mise a jour du conteneur, controle des liens physiques
# (linkDirs de config.js, cross-seed en matchMode flexible) :
#   - chaque dataDir, et le dossier d'arrivee de qBittorrent, doit avoir un
#     linkDir sur le meme systeme de fichiers, sinon l'injection echoue
#     (un lien physique ne traverse pas les systemes de fichiers) ;
#   - ces dossiers doivent etre montes dans le conteneur au meme chemin que
#     sur l'hote (les chemins viennent de qBittorrent, qui tourne sur l'hote) ;
#   - bilan : liens par tracker, liens orphelins (aucun torrent de
#     qBittorrent ne pointe dessus). Rien n'est supprime ici : le menage
#     des orphelins est propose par bibliotheque/nettoyage.
# Tout ecart est un point d'attention, jamais un echec de l'etape.
#
# Installation (lien : les mises a jour du depot sont suivies) :
#   ln -s ../bibliotheque/cross-seed services/cross-seed
# Modele de compose : bibliotheque/cross-seed/docker-compose.yml
# Reglages a surcharger dans local.conf : voir le bloc « Reglages ».
#
# SPDX-License-Identifier: GPL-3.0-or-later

set -uo pipefail

SERVICE_NAME="cross-seed"
: "${ACMECHANIC_HOME:=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)}"
# shellcheck source=../../lib/service.sh
source "${ACMECHANIC_HOME}/lib/service.sh"

# --- Reglages (surchargeables dans local.conf) ---------------------------------
: "${CROSS_SEED_PROJET:=$HOME/cross-seed}"
: "${CROSS_SEED_DONNEES:=$CROSS_SEED_PROJET}"   # contient config/ (config.js)
: "${CROSS_SEED_URL:=http://127.0.0.1:2468/api/ping}"
: "${CROSS_SEED_CANAL:=latest}"
: "${CROSS_SEED_LIENS:=oui}"                    # non = pas de controle des liens physiques
# CROSS_SEED_CONFIG (config.js) et CROSS_SEED_QBIT_URL : voir lib/xseed.sh
# -------------------------------------------------------------------------------
# shellcheck source=../../lib/xseed.sh
source "${ACMECHANIC_HOME}/lib/xseed.sh"

CONTENEUR="cross-seed"

DOCKER_PROJET="$CROSS_SEED_PROJET"
docker_preparer "cross-seed" "$DOCKER_PROJET"
xseed_controler "$CONTENEUR"
docker_standard "$CONTENEUR" "crossseed/cross-seed:$CROSS_SEED_CANAL" "$CROSS_SEED_URL" \
	"$CROSS_SEED_DONNEES" config
docker_terminer "cross-seed" "$DOCKER_PROJET"
