#!/usr/bin/env bash
# acmefrag.sh - AcmeFrag (defragmenteur XFS/EXT4 de la famille ACME).
#
# Trois operations courtes, jamais de defragmentation ici : elle peut
# durer des heures et doit rester dans sa propre tache planifiee (la
# nuit, bridee par AcmeFrag lui-meme).
#   1. mise a jour d'AcmeFrag depuis son depot (avance rapide seulement)
#   2. tests d'AcmeFrag (make test) apres une mise a jour
#   3. mesure SANS modification (--auto --dry-run) sur ACMEFRAG_CIBLE,
#      si elle est definie : rapport consultable dans ses journaux
#
# https://github.com/jpreculeau/AcmeFrag
# Installation : ln -s "$PWD/bibliotheque/acmefrag" services/acmefrag
#
# SPDX-License-Identifier: GPL-3.0-or-later

set -uo pipefail

SERVICE_NAME="acmefrag"
: "${ACMECHANIC_HOME:=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)}"
# shellcheck source=../../lib/service.sh
source "${ACMECHANIC_HOME}/lib/service.sh"

# --- Reglages (surchargeables dans local.conf) ---------------------------------
: "${ACMEFRAG_DOSSIER:=$HOME/acmefrag}"   # clone du depot AcmeFrag
: "${ACMEFRAG_CIBLE:=}"                   # dossier mesure (vide = pas de mesure)
: "${ACMEFRAG_DELAI_MESURE:=1500}"        # s ; un gros disque est long a scanner
# -------------------------------------------------------------------------------

titre "ACMEFRAG"
AF="$ACMEFRAG_DOSSIER/AcmeFrag.sh"

if [ ! -x "$AF" ]; then
	ignorer_etape "AcmeFrag" "introuvable dans $ACMEFRAG_DOSSIER (git clone https://github.com/jpreculeau/AcmeFrag)"
	bilan_service "Bilan AcmeFrag"
	exit $?
fi

# --- 1. Mise a jour --------------------------------------------------------------
avant="$(version_commande "$AF" --version)"
MIS_A_JOUR=non
if ! git -C "$ACMEFRAG_DOSSIER" rev-parse -q --verify '@{u}' >/dev/null 2>&1; then
	ignorer_etape "AcmeFrag : mise a jour" "pas un clone git suivant une branche amont"
elif etape "AcmeFrag : recherche de nouveautes" 90 git -C "$ACMEFRAG_DOSSIER" fetch -q; then
	n="$(git -C "$ACMEFRAG_DOSSIER" rev-list --count 'HEAD..@{u}')"
	if [ "$n" -eq 0 ]; then
		inchanger_etape "AcmeFrag" "a jour ($avant)"
	elif [ -n "$(git -C "$ACMEFRAG_DOSSIER" status --porcelain --untracked-files=no)" ]; then
		point_attention "AcmeFrag : $n commit(s) disponible(s), non appliques : modifications locales" \
			"git -C $ACMEFRAG_DOSSIER status"
	elif etape "AcmeFrag : mise a jour ($n commit(s))" 120 \
		git -C "$ACMEFRAG_DOSSIER" merge -q --ff-only '@{u}'; then
		MIS_A_JOUR=oui
		NB_MAJ=$((NB_MAJ + 1))
	fi
fi
enregistrer_version "acmefrag" "$avant" "$(version_commande "$AF" --version)"

# --- 2. Tests apres mise a jour --------------------------------------------------
if [ "$MIS_A_JOUR" = oui ] && [ -f "$ACMEFRAG_DOSSIER/Makefile" ] && command -v make >/dev/null 2>&1; then
	run_etape "AcmeFrag : tests" 300 make -C "$ACMEFRAG_DOSSIER" -s test
fi

# --- 3. Mesure sans modification -------------------------------------------------
if [ -z "$ACMEFRAG_CIBLE" ]; then
	ignorer_etape "AcmeFrag : mesure" "ACMEFRAG_CIBLE non definie"
elif [ ! -d "$ACMEFRAG_CIBLE" ]; then
	ignorer_etape "AcmeFrag : mesure" "dossier absent : $ACMEFRAG_CIBLE (disque debranche ?)"
else
	# Codes AcmeFrag : 3 = refus de securite (SSD, FS racine...), 4 = deja
	# en cours (la defragmentation planifiee tourne) : pas des echecs.
	step "AcmeFrag : mesure de $ACMEFRAG_CIBLE (simulation)"
	timeout "$ACMEFRAG_DELAI_MESURE" "$AF" "$ACMEFRAG_CIBLE" --auto --dry-run </dev/null
	case $? in
	0) ok "AcmeFrag : mesure terminee (rapport dans les journaux d'AcmeFrag)." ;;
	3) ignorer_etape "AcmeFrag : mesure" "refus de securite d'AcmeFrag (SSD, FS racine...)" ;;
	4) ignorer_etape "AcmeFrag : mesure" "AcmeFrag deja en cours" ;;
	124) err "AcmeFrag : mesure trop longue (> ${ACMEFRAG_DELAI_MESURE}s)"; NB_ECHEC=$((NB_ECHEC + 1)) ;;
	*) err "AcmeFrag : mesure en echec"; NB_ECHEC=$((NB_ECHEC + 1)) ;;
	esac
fi

bilan_service "Bilan AcmeFrag"
exit $?
