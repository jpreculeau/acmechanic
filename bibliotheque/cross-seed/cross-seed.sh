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

# controler_liens : les trois controles decrits en tete. Appele hors
# run_etape : ses points d'attention et ses lignes de bilan doivent rester
# dans ce shell (un sous-shell les perdrait).
controler_liens() {
	local libelle="cross-seed : liens physiques" fichier_contenus="" arrivee="" d l p trouve
	local -a liens donnees
	local qbit_ok=non
	if [ "$CROSS_SEED_LIENS" != oui ]; then
		ignorer_etape "$libelle" "desactive (CROSS_SEED_LIENS)"
		return 0
	fi
	if [ ! -r "$CROSS_SEED_CONFIG" ]; then
		ignorer_etape "$libelle" "config.js illisible : $CROSS_SEED_CONFIG (CROSS_SEED_CONFIG)"
		return 0
	fi
	mapfile -t liens < <(xseed_liens_dossiers)
	mapfile -t donnees < <(xseed_donnees_dossiers)
	if [ ${#liens[@]} -eq 0 ]; then
		log "cross-seed : pas de linkDirs dans config.js : liens physiques non utilises, rien a controler."
		return 0
	fi
	step "$libelle (${#liens[@]} linkDir)"

	# qBittorrent : dossier d'arrivee et contenus des torrents. Sans lui, les
	# controles qui en dependent sont sautes, les autres faits quand meme.
	local url code
	url="$(qbit_url)"
	qbit_session "$url"; code=$?
	case $code in
	0)
		if ! fichier_temp fichier_contenus || ! qbit_chemins_contenus >"$fichier_contenus"; then
			warn "cross-seed : API qBittorrent sans reponse exploitable ($QBIT_BASE : jq absent, ou acces refuse) : orphelins et dossier d'arrivee non controles."
		elif [ ! -s "$fichier_contenus" ]; then
			warn "cross-seed : aucun content_path renvoye par qBittorrent ($QBIT_BASE) : orphelins non controles."
		else
			qbit_ok=oui
			arrivee="$(qbit_dossier_arrivee)" || arrivee=""
			[ "$arrivee" != / ] && arrivee="${arrivee%/}"   # qBittorrent le donne souvent avec / final
		fi ;;
	1) warn "cross-seed : identifiants qBittorrent refuses ($QBIT_BASE ; refus memorise dans $QBIT_REFUS, a supprimer si le mot de passe a ete corrige cote qBittorrent) : orphelins et dossier d'arrivee non controles." ;;
	2) warn "cross-seed : qBittorrent injoignable ($QBIT_BASE, HTTP ${QBIT_HTTP:-aucune reponse}) : orphelins et dossier d'arrivee non controles." ;;
	4) warn "cross-seed : qBittorrent demande une authentification et l'URL n'a pas d'identifiants (CROSS_SEED_QBIT_URL) : orphelins et dossier d'arrivee non controles." ;;
	*) warn "cross-seed : URL de qBittorrent inconnue (torrentClients de config.js, ou CROSS_SEED_QBIT_URL) : orphelins et dossier d'arrivee non controles." ;;
	esac

	# Sources des liens : dataDirs et dossier d'arrivee, chacun une fois.
	local -A vu=()
	local -a sources=()
	for d in "${donnees[@]}" ${arrivee:+"$arrivee"}; do
		[ -n "${vu[$d]:-}" ] && continue
		vu[$d]=1; sources+=("$d")
	done

	# 1. Un linkDir sur le meme systeme de fichiers que chaque source.
	for l in "${liens[@]}"; do
		[ -d "$l" ] || point_attention "cross-seed : linkDir absent sur l'hote : $l (disque debranche, ou chemin du conteneur seulement ?)"
	done
	for d in "${sources[@]}"; do
		if [ ! -d "$d" ]; then
			point_attention "cross-seed : dossier absent sur l'hote : $d (dataDirs ou dossier d'arrivee de qBittorrent)"
			continue
		fi
		trouve=non
		for l in "${liens[@]}"; do
			[ -d "$l" ] && meme_fs "$d" "$l" && { trouve=oui; break; }
		done
		[ "$trouve" = oui ] ||
			point_attention "cross-seed : hardlink impossible pour $d : injection en echec (aucun linkDir sur le meme systeme de fichiers ; en ajouter un dans linkDirs)"
	done

	# 2. Memes chemins dans le conteneur que sur l'hote.
	local inspectable=oui
	for p in "${liens[@]}" "${sources[@]}"; do
		xseed_monte_a_l_identique "$CONTENEUR" "$p"; code=$?
		[ $code -eq 2 ] && { inspectable=non; break; }
		[ $code -eq 0 ] ||
			point_attention "cross-seed : $p n'est pas monte dans le conteneur au meme chemin que sur l'hote (volume <chemin>:<chemin> a ajouter au compose : les chemins viennent de qBittorrent)"
	done
	[ "$inspectable" = oui ] ||
		log "cross-seed : conteneur $CONTENEUR non inspectable (absent, ou Docker arrete) : montages non controles."

	# 3. Bilan : liens par tracker, orphelins.
	local tracker n total=0
	for l in "${liens[@]}"; do
		[ -d "$l" ] || continue
		while IFS=$'\t' read -r n tracker; do
			noter_bilan "cross-seed : liens $tracker" "$n"
			total=$((total + n))
		done < <(xseed_liens_par_tracker "$l")
	done
	if [ "$qbit_ok" = oui ]; then
		n="$(xseed_liens_orphelins "$fichier_contenus" "${liens[@]}" | wc -l)"
		if [ "$total" -gt 0 ] && [ "$n" -eq "$total" ]; then
			# Tous orphelins : qBittorrent ne voit sans doute pas les memes chemins que l'hote.
			point_attention "cross-seed : tous les liens ($total) sont orphelins : les chemins de qBittorrent ne sont pas ceux de l'hote ? (qBittorrent en conteneur, montages differents)"
		else
			noter_bilan "cross-seed : liens orphelins" "$n sur $total (aucun torrent qBittorrent ne pointe dessus ; menage propose par nettoyage)"
		fi
	fi
	ok "$libelle -- controles faits"
}

DOCKER_PROJET="$CROSS_SEED_PROJET"
docker_preparer "cross-seed" "$DOCKER_PROJET"
controler_liens
docker_standard "$CONTENEUR" "crossseed/cross-seed:$CROSS_SEED_CANAL" "$CROSS_SEED_URL" \
	"$CROSS_SEED_DONNEES" config
docker_terminer "cross-seed" "$DOCKER_PROJET"
