# shellcheck shell=bash
################################################################################
# service.sh - Socle des scripts de la bibliotheque (bibliotheque/<nom>/).
#
# Un seul `source` charge tout ce dont un service a besoin :
#   lib/common.sh, config.sh (+ local.conf), lib/backup.sh
# puis prend le verrou du service (SERVICE_NAME, a definir AVANT).
#
# Il ajoute trois briques pour les services Docker Compose :
#   docker_preparer  <titre> <projet>             controles prealables
#   docker_standard  <conteneur> <image:canal> <url> <donnees> <elements...>
#   docker_terminer  <titre> <projet>             journal si echec + bilan
#
# Convention de nommage des reglages (surchargeables dans local.conf) :
#   <NOM>_PROJET   dossier du docker-compose.yml
#   <NOM>_DONNEES  dossier source des sauvegardes
#   <NOM>_URL      sonde HTTP depuis l'hote (vide = healthcheck Docker seul)
#   <NOM>_CANAL    tag suivi (latest, ou un canal de pointe : develop, edge...)
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Jean-Philippe Reculeau — voir LICENSE
################################################################################

[ -n "${_SERVICE_SH_LOADED:-}" ] && return 0
_SERVICE_SH_LOADED=1

: "${ACMECHANIC_HOME:?ACMECHANIC_HOME non defini}"
export ACMECHANIC_HOME
# shellcheck source=common.sh
source "${ACMECHANIC_HOME}/lib/common.sh"
# shellcheck source=../config.sh
source "${ACMECHANIC_HOME}/config.sh"
# shellcheck source=backup.sh
source "${ACMECHANIC_HOME}/lib/backup.sh"

prendre_verrou "$SERVICE_NAME"

# etape <libelle> <delai> cmd... : comme run_etape (comptage, delai,
# journal), mais renvoie 1 si l'etape a echoue : run_etape rend toujours 0.
etape() {
	local echecs=$NB_ECHEC
	run_etape "$@"
	[ "$NB_ECHEC" -eq "$echecs" ]
}

# docker_preparer <titre> <projet> : titre, dependances, compose present.
# Sort du script (code 1) si un prerequis manque.
docker_preparer() {
	local titre_svc="$1" projet="$2"
	titre "MAINTENANCE ${titre_svc^^}"
	if ! verifier_commandes docker curl tar; then
		err "Dependances manquantes, arret."
		exit 1
	fi
	if [ ! -f "${COMPOSE_FICHIER:-$projet/docker-compose.yml}" ]; then
		err "Fichier ${COMPOSE_FICHIER:-$projet/docker-compose.yml} introuvable, arret."
		err "Modele : ${ACMECHANIC_HOME}/bibliotheque/${SERVICE_NAME}/docker-compose.yml"
		exit 1
	fi
}

# docker_standard <conteneur> <image:canal> <url> <donnees> <elements...>
# Resout le tag (canal de pointe ou latest, le plus recent : choisir_tag),
# l'exporte en <CONTENEUR>_TAG pour le compose (image: x:${<CONTENEUR>_TAG:-latest}),
# puis delegue a maintenir_service_docker (gate registre, sauvegarde,
# redemarrage, sante). Le projet est lu dans DOCKER_PROJET.
# Elements vides => pas de sauvegarde.
docker_standard() {
	local conteneur="$1" image="$2" url="$3" donnees="$4"
	shift 4
	local var tag sauver=oui
	var="$(tr 'a-z-' 'A-Z_' <<<"$conteneur")_TAG"
	tag="$(choisir_tag "$image")"
	export "$var=$tag"
	log "$conteneur : tag resolu = $tag (canal : ${image##*:})"
	[ $# -eq 0 ] && sauver=non
	maintenir_service_docker "${DOCKER_PROJET:?}" "$conteneur" "$url" \
		"${image%:*}:$tag" "$sauver" "$donnees" "$@"
}

# docker_terminer <titre> <projet> : fin du journal des conteneurs en cas
# d'echec, puis bilan. Sort du script avec le nombre d'echecs.
docker_terminer() {
	local titre_svc="$1" projet="$2"
	if [ "$NB_ECHEC" -gt 0 ]; then
		echo
		warn "Dernieres lignes du journal :"
		compose "$projet" logs --tail=20 2>&1 | sed 's/^/    /'
	fi
	bilan_service "Bilan de la maintenance $titre_svc"
	exit $?
}
