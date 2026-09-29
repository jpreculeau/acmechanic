#!/usr/bin/env bash
# uptime-kuma.sh - Maintenance d'Uptime Kuma (supervision de disponibilite).
#
# Installation (lien : les mises a jour du depot sont suivies) :
#   ln -s "$PWD/bibliotheque/uptime-kuma" services/uptime-kuma
# Modele de compose : bibliotheque/uptime-kuma/docker-compose.yml
# Reglages a surcharger dans local.conf : voir le bloc « Reglages ».
#
# SPDX-License-Identifier: GPL-3.0-or-later

set -uo pipefail

SERVICE_NAME="uptime-kuma"
: "${ACMECHANIC_HOME:=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)}"
# shellcheck source=../../lib/service.sh
source "${ACMECHANIC_HOME}/lib/service.sh"

# --- Reglages (surchargeables dans local.conf) ---------------------------------
: "${UPTIME_KUMA_PROJET:=$HOME/uptime-kuma}"
: "${UPTIME_KUMA_DONNEES:=$UPTIME_KUMA_PROJET}"
: "${UPTIME_KUMA_URL:=http://127.0.0.1:3001}"
: "${UPTIME_KUMA_CANAL:=latest}"
# -------------------------------------------------------------------------------

DOCKER_PROJET="$UPTIME_KUMA_PROJET"
docker_preparer "Uptime Kuma" "$DOCKER_PROJET"
docker_standard uptime-kuma "louislam/uptime-kuma:$UPTIME_KUMA_CANAL" "$UPTIME_KUMA_URL" \
	"$UPTIME_KUMA_DONNEES" data
docker_terminer "Uptime Kuma" "$DOCKER_PROJET"
