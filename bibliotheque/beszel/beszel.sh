#!/usr/bin/env bash
# beszel.sh - Maintenance de Beszel (supervision : hub + agent).
#
# Installation (lien : les mises a jour du depot sont suivies) :
#   ln -s ../bibliotheque/beszel services/beszel
# Modele de compose : bibliotheque/beszel/docker-compose.yml
# Reglages a surcharger dans local.conf : voir le bloc « Reglages ».
#
# SPDX-License-Identifier: GPL-3.0-or-later

set -uo pipefail

SERVICE_NAME="beszel"
: "${ACMECHANIC_HOME:=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)}"
# shellcheck source=../../lib/service.sh
source "${ACMECHANIC_HOME}/lib/service.sh"

# --- Reglages (surchargeables dans local.conf) ---------------------------------
: "${BESZEL_PROJET:=$HOME/beszel}"
: "${BESZEL_DONNEES:=$BESZEL_PROJET}"
: "${BESZEL_URL:=http://127.0.0.1:8090}"
: "${BESZEL_CANAL:=latest}"            # edge = pointe (hub et agent)
: "${BESZEL_AGENT_PORT:=45876}"
# -------------------------------------------------------------------------------

# L'agent repond sur son port par une banniere SSH « SSH-2.0-beszel ».
verifier_agent_beszel() {
	local rep i
	command -v nc >/dev/null 2>&1 || { log "nc absent : controle de l'agent saute."; return 0; }
	for i in 1 2 3 4 5 6; do
		rep="$(timeout 3 nc -w 3 127.0.0.1 "$BESZEL_AGENT_PORT" </dev/null 2>/dev/null | head -c 40)"
		if grep -q 'SSH-2.0-beszel' <<<"$rep"; then
			ok "Agent Beszel joignable ($(tr -d '\r' <<<"$rep"))."
			return 0
		fi
		sleep 2
	done
	err "Agent Beszel injoignable sur le port $BESZEL_AGENT_PORT."
	return 1
}

DOCKER_PROJET="$BESZEL_PROJET"
docker_preparer "Beszel" "$DOCKER_PROJET"
docker_standard beszel "henrygd/beszel:$BESZEL_CANAL" "$BESZEL_URL" \
	"$BESZEL_DONNEES" beszel_data
docker_standard beszel-agent "henrygd/beszel-agent:$BESZEL_CANAL" "" \
	"$BESZEL_DONNEES" beszel_agent_data
run_etape "beszel-agent : verification de l'activite" 60 verifier_agent_beszel
docker_terminer "Beszel" "$DOCKER_PROJET"
