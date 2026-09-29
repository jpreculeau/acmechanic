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
# -------------------------------------------------------------------------------

titre "NETTOYAGE"

# Espace libre (Ko) sur la partition de $HOME et sur /.
libre_ko() { df -Pk "$@" 2>/dev/null | awk 'NR>1 && !vu[$1]++ {s+=$4} END {print s+0}'; }
LIBRE_AVANT="$(libre_ko "$HOME" /)"

# --- Docker --------------------------------------------------------------------
if [ "$NETTOYAGE_DOCKER" = oui ] && command -v docker >/dev/null 2>&1; then
	# Meme verrou que nettoyer_images (lib/common.sh) : pas deux prune en meme temps.
	run_etape "Docker : images sans etiquette" 300 \
		flock -w 300 /tmp/maintenance-docker-prune.lock docker image prune -f
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
	run_etape "Vignettes > $NETTOYAGE_VIGNETTES_JOURS jours" 120 \
		find "$HOME/.cache/thumbnails" -type f -atime +"$NETTOYAGE_VIGNETTES_JOURS" -delete
else
	ignorer_etape "Vignettes" "desactive ou aucun cache"
fi

LIBRE_APRES="$(libre_ko "$HOME" /)"
GAIN_MO=$(((LIBRE_APRES - LIBRE_AVANT) / 1024))
[ "$GAIN_MO" -lt 0 ] && GAIN_MO=0
ok "Espace recupere : ~${GAIN_MO} Mo"
enregistrer_version "nettoyage" "-" "${GAIN_MO} Mo liberes"

bilan_service "Bilan du nettoyage"
exit $?
