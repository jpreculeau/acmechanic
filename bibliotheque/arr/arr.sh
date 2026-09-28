#!/usr/bin/env bash
# arr.sh - Maintenance des *arr (Sonarr, Radarr, Prowlarr, Lidarr).
#
# Installation (lien : les mises a jour du depot sont suivies) :
#   ln -s ../bibliotheque/arr services/arr
# Modele de compose : bibliotheque/arr/docker-compose.yml
# Reglages a surcharger dans local.conf : voir le bloc « Reglages ».
#
# SPDX-License-Identifier: GPL-3.0-or-later

set -uo pipefail

SERVICE_NAME="arr"
: "${ACMECHANIC_HOME:=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)}"
# shellcheck source=../../lib/service.sh
source "${ACMECHANIC_HOME}/lib/service.sh"

# --- Reglages (surchargeables dans local.conf) ---------------------------------
: "${ARR_PROJET:=$HOME/arr}"
# Un sous-dossier par service (sonarr/, radarr/...) monte sur /config.
: "${ARR_DONNEES:=$ARR_PROJET}"
if [[ -z "${ARR_SERVICES+x}" ]]; then ARR_SERVICES=(sonarr radarr prowlarr); fi
# Par service : <SVC>_CANAL (defaut latest ; ex. SONARR_CANAL=develop)
# et <SVC>_URL (defaut http://127.0.0.1:<port>/ping).
declare -A ARR_PORTS=([sonarr]=8989 [radarr]=7878 [prowlarr]=9696 [lidarr]=8686)
BACKUP_EXCLURE=('*/logs' '*/logs.db*' '*/asp' '*/Sentry' '*/MediaCover' '*.pid')
# -------------------------------------------------------------------------------

# Arguments : limiter a certains services (ex. arr.sh sonarr).
[ $# -gt 0 ] && ARR_SERVICES=("$@")

DOCKER_PROJET="$ARR_PROJET"
docker_preparer "*arr" "$DOCKER_PROJET"
for svc in "${ARR_SERVICES[@]}"; do
	if [ -z "${ARR_PORTS[$svc]:-}" ]; then
		ignorer_etape "$svc" "service inconnu (${!ARR_PORTS[*]})"
		continue
	fi
	v_canal="${svc^^}_CANAL" v_url="${svc^^}_URL"
	docker_standard "$svc" "linuxserver/$svc:${!v_canal:-latest}" \
		"${!v_url:-http://127.0.0.1:${ARR_PORTS[$svc]}/ping}" "$ARR_DONNEES" "$svc"
done
docker_terminer "*arr" "$DOCKER_PROJET"
