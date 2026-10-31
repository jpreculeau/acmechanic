#!/usr/bin/env bash
# nettoyage.sh - Menage prudent : ne supprime que du reconstructible.
#
#   Docker   images sans etiquette + cache de construction ancien
#            (JAMAIS de volumes, ni de conteneurs arretes : ils peuvent
#            etre voulus)
#   Journal  systemd au-dela de NETTOYAGE_JOURNAL (sudo)
#   Paquets  cache APT / Nala (sudo)
#   Journaux d'Acmechanic plus gros que NETTOYAGE_LOG_MO (garde la fin)
#   Vignettes ~/.cache/thumbnails plus vieilles que NETTOYAGE_VIGNETTES_JOURS
#   Liens cross-seed (xseed-links) : JAMAIS supprimes par une regle d'ici.
#            Seule exception, en PROPOSITION (point d'attention, jamais
#            automatique) : un lien dont le torrent n'existe plus dans
#            qBittorrent ET dont l'inode a encore un autre nom (st_nlink > 1) ;
#            la commande proposee reverifie l'autre nom avant chaque retrait.
#            Un orphelin qui est le dernier nom de son inode est conserve.
#
# Chaque rubrique se desactive dans local.conf (ex. NETTOYAGE_DOCKER=non).
# Installation : ln -s "$PWD/bibliotheque/nettoyage" services/nettoyage
#
# SPDX-License-Identifier: GPL-3.0-or-later

set -uo pipefail

SERVICE_NAME="nettoyage"
: "${ACMECHANIC_HOME:=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)}"
# shellcheck source=../../lib/service.sh
source "${ACMECHANIC_HOME}/lib/service.sh"

# --- Reglages (surchargeables dans local.conf) ---------------------------------
: "${NETTOYAGE_DOCKER:=oui}"
: "${NETTOYAGE_DOCKER_CACHE_AGE:=168h}"     # cache de construction > 7 jours
: "${NETTOYAGE_JOURNAL:=4weeks}"            # non = ne pas toucher au journal
: "${NETTOYAGE_PAQUETS:=oui}"
: "${NETTOYAGE_LOG_MO:=20}"                 # 0 = ne pas toucher aux journaux
: "${NETTOYAGE_VIGNETTES_JOURS:=90}"        # 0 = ne pas toucher aux vignettes
: "${NETTOYAGE_XSEED:=oui}"                 # non = pas de proposition sur les liens cross-seed
# CROSS_SEED_CONFIG (config.js) et CROSS_SEED_QBIT_URL : voir lib/xseed.sh
# -------------------------------------------------------------------------------
# shellcheck source=../../lib/xseed.sh
source "${ACMECHANIC_HOME}/lib/xseed.sh"

titre "NETTOYAGE"

# supprimer_fichiers : lit des chemins separes par NUL et supprime chaque
# fichier, sauf dans un dossier de liens de cross-seed (xseed_protege) :
# le filet commun a toute regle de menage qui retire des fichiers.
supprimer_fichiers() {
	local f n=0 gardes=0
	while IFS= read -r -d '' f; do
		if xseed_protege "$f"; then gardes=$((gardes + 1)); continue; fi
		rm -f -- "$f" && n=$((n + 1))
	done
	local msg="$n fichier(s) supprime(s)"
	[ "$gardes" -gt 0 ] && msg+=", $gardes garde(s) (liens cross-seed)"
	log "$msg."
}

# Espace libre (Ko) sur la partition de $HOME et sur /.
libre_ko() { df -Pk "$@" 2>/dev/null | awk 'NR>1 && !vu[$1]++ {s+=$4} END {print s+0}'; }
LIBRE_AVANT="$(libre_ko "$HOME" /)"

# --- Docker --------------------------------------------------------------------
if [ "$NETTOYAGE_DOCKER" = oui ] && command -v docker >/dev/null 2>&1; then
	# nettoyer_images (lib/common.sh) : attend la fin des pulls en cours,
	# qu'un prune tuerait (magasin d'images containerd).
	run_etape "Docker : images sans etiquette" "$(delai_etape_prune)" nettoyer_images
	run_etape "Docker : cache de construction > $NETTOYAGE_DOCKER_CACHE_AGE" 300 \
		docker builder prune -f --filter "until=$NETTOYAGE_DOCKER_CACHE_AGE"
else
	ignorer_etape "Docker" "desactive ou absent"
fi

# --- Journal systemd -----------------------------------------------------------
if [ "$NETTOYAGE_JOURNAL" = non ] || ! command -v journalctl >/dev/null 2>&1; then
	ignorer_etape "Journal systemd" "desactive ou absent"
elif sudo_disponible; then
	run_etape "Journal systemd : au-dela de $NETTOYAGE_JOURNAL" 300 \
		sudo -n journalctl --vacuum-time="$NETTOYAGE_JOURNAL"
else
	ignorer_etape "Journal systemd" "sudo indisponible sans mot de passe"
fi

# --- Cache des paquets ---------------------------------------------------------
if [ "$NETTOYAGE_PAQUETS" != oui ]; then
	ignorer_etape "Cache des paquets" "desactive"
elif ! sudo_disponible; then
	ignorer_etape "Cache des paquets" "sudo indisponible sans mot de passe"
elif command -v nala >/dev/null 2>&1; then
	run_etape "Cache des paquets (Nala)" 300 sudo -n nala clean
elif command -v apt-get >/dev/null 2>&1; then
	run_etape "Cache des paquets (APT)" 300 sudo -n apt-get clean
else
	ignorer_etape "Cache des paquets" "ni Nala ni APT"
fi

# --- Journaux d'Acmechanic -----------------------------------------------------
# Un fichier <racine>/<service>/<service>.log par service, qui grossit a
# chaque run. Au-dela du seuil, on garde la fin (les runs recents).
raccourcir_journaux() {
	local racine f n=0
	racine="$(dirname "$LOG_DIR")"
	while IFS= read -r f; do
		[ "$(basename "$f" .log)" = "$(basename "$(dirname "$f")")" ] || continue
		xseed_protege "$f" && continue
		tail -c "$((NETTOYAGE_LOG_MO * 1024 * 1024 / 2))" "$f" >"$f.tmp" && mv "$f.tmp" "$f"
		log "  raccourci : $f"
		n=$((n + 1))
	done < <(find "$racine" -mindepth 2 -maxdepth 2 -name '*.log' -type f -size +"${NETTOYAGE_LOG_MO}"M 2>/dev/null)
	log "$n journal(aux) raccourci(s)."
}
if [ "$NETTOYAGE_LOG_MO" -gt 0 ]; then
	run_etape "Journaux d'Acmechanic > ${NETTOYAGE_LOG_MO} Mo" 120 raccourcir_journaux
else
	ignorer_etape "Journaux d'Acmechanic" "desactive"
fi

# --- Vignettes -----------------------------------------------------------------
if [ "$NETTOYAGE_VIGNETTES_JOURS" -gt 0 ] && [ -d "$HOME/.cache/thumbnails" ]; then
	vignettes_anciennes() {
		find "$HOME/.cache/thumbnails" -type f -atime +"$NETTOYAGE_VIGNETTES_JOURS" -print0 2>/dev/null |
			supprimer_fichiers
	}
	run_etape "Vignettes > $NETTOYAGE_VIGNETTES_JOURS jours" 120 vignettes_anciennes
else
	ignorer_etape "Vignettes" "desactive ou aucun cache"
fi

# --- Liens cross-seed orphelins : proposition seulement --------------------------
# Un lien de <linkDir>/<tracker>/ dont aucun torrent de qBittorrent ne
# couvre le chemin est orphelin (torrent retire du client). S'il a encore
# un autre nom (st_nlink > 1), le retirer ne supprime aucune donnee : la
# commande est proposee, jamais lancee d'ici. Le dernier nom d'un inode
# n'est jamais propose.
liens_orphelins() {
	local libelle="Liens cross-seed orphelins" liste f n=0 seuls=0 code
	local -a liens
	if [ ! -r "$CROSS_SEED_CONFIG" ]; then
		ignorer_etape "$libelle" "config.js illisible : $CROSS_SEED_CONFIG (CROSS_SEED_CONFIG)"
		return 0
	fi
	mapfile -t liens < <(xseed_liens_dossiers)
	if [ ${#liens[@]} -eq 0 ]; then
		log "Liens cross-seed : pas de linkDirs dans config.js, rien a proposer."
		return 0
	fi
	qbit_session "$(qbit_url)"; code=$?
	case $code in
	0) ;;
	1) ignorer_etape "$libelle" "identifiants qBittorrent refuses ($QBIT_BASE ; refus memorise dans $QBIT_REFUS, a supprimer si le mot de passe a ete corrige cote qBittorrent)"; return 0 ;;
	2) ignorer_etape "$libelle" "qBittorrent injoignable ($QBIT_BASE, HTTP ${QBIT_HTTP:-aucune reponse})"; return 0 ;;
	4) ignorer_etape "$libelle" "qBittorrent demande une authentification et l'URL n'a pas d'identifiants (CROSS_SEED_QBIT_URL)"; return 0 ;;
	*) ignorer_etape "$libelle" "URL de qBittorrent inconnue (torrentClients de config.js, ou CROSS_SEED_QBIT_URL)"; return 0 ;;
	esac
	local contenus=""
	if ! fichier_temp contenus || ! qbit_chemins_contenus >"$contenus"; then
		ignorer_etape "$libelle" "API qBittorrent sans reponse exploitable ($QBIT_BASE : jq absent, ou acces refuse)"
		return 0
	fi
	if [ ! -s "$contenus" ]; then
		ignorer_etape "$libelle" "aucun content_path renvoye par qBittorrent ($QBIT_BASE)"
		return 0
	fi
	step "$libelle : inventaire"
	liste="$LOG_DIR/liens-orphelins"
	: >"$liste"
	while IFS= read -r f; do
		if [ "$(stat -c %h -- "$f" 2>/dev/null || echo 1)" -gt 1 ]; then
			printf '%s\0' "$f" >>"$liste"
			n=$((n + 1))
		else
			seuls=$((seuls + 1))
		fi
	done < <(xseed_liens_orphelins "$contenus" "${liens[@]}")
	[ "$seuls" -gt 0 ] && log "Liens cross-seed : $seuls orphelin(s) qui sont le seul nom de leur inode : conserves (donnees)."
	# Tous orphelins : qBittorrent ne voit sans doute pas les memes chemins
	# que l'hote (conteneur, montages differents) ; rien n'est propose.
	local total
	total="$(find "${liens[@]}" -type f 2>/dev/null | wc -l)"
	if [ "$total" -gt 0 ] && [ $((n + seuls)) -eq "$total" ]; then
		point_attention "nettoyage : tous les liens cross-seed ($total) sont orphelins : les chemins de qBittorrent ne sont pas ceux de l'hote ? Rien n'est propose."
		rm -f -- "$liste"
		return 0
	fi
	if [ "$n" -eq 0 ]; then
		log "Liens cross-seed : aucun orphelin a proposer."
		rm -f -- "$liste"
		return 0
	fi
	point_attention "nettoyage : $n lien(s) cross-seed orphelin(s) (torrent absent de qBittorrent, autre nom conserve) : liste du $(date '+%Y-%m-%d') dans $liste" \
		"$(printf 'while IFS= read -r -d %s f; do [ "$(stat -c %%h -- "$f" 2>/dev/null || echo 1)" -le 1 ] || rm -v -- "$f"; done <%q' "''" "$liste")" \
		"ces noms ne servent plus a aucun torrent : ils encombrent l'inventaire de cross-seed et des trackers, sans occuper d'espace (l'inode a un autre nom)" \
		"retire chaque nom liste dont l'inode a encore un autre nom au moment du retrait (reverifie fichier par fichier) ; aucune donnee n'est supprimee, un lien redevenu seul nom est garde"
}
if [ "$NETTOYAGE_XSEED" = oui ]; then
	liens_orphelins
else
	ignorer_etape "Liens cross-seed orphelins" "desactive"
fi

LIBRE_APRES="$(libre_ko "$HOME" /)"
GAIN_MO=$(((LIBRE_APRES - LIBRE_AVANT) / 1024))
[ "$GAIN_MO" -lt 0 ] && GAIN_MO=0
ok "Espace recupere : ~${GAIN_MO} Mo"

bilan_service "Bilan du nettoyage"
exit $?
