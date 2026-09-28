#!/usr/bin/env bash
# cross-seed.sh - Maintenance de cross-seed.
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
# -------------------------------------------------------------------------------

DOCKER_PROJET="$CROSS_SEED_PROJET"
docker_preparer "cross-seed" "$DOCKER_PROJET"
docker_standard cross-seed "crossseed/cross-seed:$CROSS_SEED_CANAL" "$CROSS_SEED_URL" \
	"$CROSS_SEED_DONNEES" config
docker_terminer "cross-seed" "$DOCKER_PROJET"
