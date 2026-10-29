#!/usr/bin/env bash
# acmefrag.sh - AcmeFrag (defragmenteur XFS/EXT4 de la famille ACME).
#
# Operations courtes, jamais de defragmentation ici : elle peut
# durer des heures et doit rester dans sa propre tache planifiee (la
# nuit, bridee par AcmeFrag lui-meme).
#   1. mise a jour d'AcmeFrag depuis son depot (avance rapide seulement)
#   2. tests d'AcmeFrag (make test) apres une mise a jour
#   3. mesure SANS modification (--auto --dry-run) sur ACMEFRAG_CIBLE,
#      si elle est definie : rapport consultable dans ses journaux
#   4. sante du disque (--sante) qui porte ACMEFRAG_SANTE_CIBLE : lecture
#      SMART seule, sans reveiller un disque en veille ; une degradation
#      devient un point d'attention (une fois : au passage qui la constate)
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
: "${ACMEFRAG_SANTE_CIBLE=$ACMEFRAG_CIBLE}" # dossier dont le disque est surveille (vide = rien)
: "${ACMEFRAG_DELAI_SANTE:=120}"          # s ; une lecture SMART prend quelques secondes
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
			"git -C $ACMEFRAG_DOSSIER status" \
			"la mise a jour automatique est bloquee par des modifications locales" \
			"affiche les fichiers modifies, sans rien changer ; a committer ou ecarter vous-meme"
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
	# Choix de configuration, pas un incident : simple mention au journal.
	log "AcmeFrag : mesure desactivee (ACMEFRAG_CIBLE non definie)."
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

# --- 4. Sante du disque -----------------------------------------------------------
# Apres la mesure : celle-ci reveille le disque ; --sante, qui ne reveille
# pas un disque en veille, aboutit alors au lieu d'etre ignore.
# Codes de --sante : 0 pas de nouvelle degradation, 6 alerte, 7 mesure
# impossible (SMART indisponible, disque en veille), 2 option inconnue
# (AcmeFrag < 3.1). La derniere ligne « BILAN SANTÉ : ... » resume le
# resultat ; sortie d'un autre processus : caracteres de controle retires
# (le fichier d'attention est separe par \x1f), longueur bornee.
if [ -z "$ACMEFRAG_SANTE_CIBLE" ]; then
	log "AcmeFrag : sante du disque non surveillee (ACMEFRAG_SANTE_CIBLE vide)."
elif [ ! -d "$ACMEFRAG_SANTE_CIBLE" ]; then
	ignorer_etape "AcmeFrag : sante du disque" "dossier absent : $ACMEFRAG_SANTE_CIBLE (disque debranche ?)"
elif [ "$(id -u)" -ne 0 ] && ! sudo_disponible; then
	# AcmeFrag se relance par sudo : sans droit sans mot de passe, il
	# attendrait une saisie jusqu'au delai.
	ignorer_etape "AcmeFrag : sante du disque" "sudo demande un mot de passe (AcmeFrag lit SMART en root)"
else
	step "AcmeFrag : sante du disque de $ACMEFRAG_SANTE_CIBLE"
	sortie="$(timeout "$ACMEFRAG_DELAI_SANTE" "$AF" "$ACMEFRAG_SANTE_CIBLE" --sante </dev/null 2>&1)"
	code=$?
	printf '%s\n' "$sortie"
	bilan="$(printf '%s\n' "$sortie" | LC_ALL=C sed -n 's/^.*BILAN SANT[^ ]* : //p' | tail -n 1 |
		LC_ALL=C tr -d '\000-\037\177')"
	bilan="${bilan:0:300}"
	case $code in
	0)
		# Bilan autre que PASSED : deja mauvais (FAILED connu, signale a son
		# apparition) ou NA (pont sans statut SMART) : mention au journal,
		# jamais un OK.
		case $bilan in
		*"(bilan PASSED)") ok "AcmeFrag : $bilan" ;;
		*) log "AcmeFrag : sante du disque : ${bilan:-pas de nouvelle degradation}" ;;
		esac ;;
	6) point_attention "AcmeFrag : sante du disque : ${bilan:-degradation signalee par AcmeFrag}" \
		"$(printf '%q %q --sante' "$AF" "$ACMEFRAG_SANTE_CIBLE")" \
		"le disque se degrade : ses donnees sont en danger tant qu'elles n'ont pas d'autre copie" \
		"relit SMART sans rien ecrire sur le disque surveille et affiche les valeurs du jour ; l'evolution complete est dans l'historique sante des rapports d'AcmeFrag. Ensuite : sauvegarder, puis remplacer le disque" ;;
	2) case $sortie in
		*"Option inconnue : --sante"*)
			ignorer_etape "AcmeFrag : sante du disque" "AcmeFrag 3.1 ou plus requis (option --sante inconnue)" ;;
		*) err "AcmeFrag : sante du disque en echec (code 2 : configuration d'AcmeFrag ?)"; NB_ECHEC=$((NB_ECHEC + 1)) ;;
		esac ;;
	7) ignorer_etape "AcmeFrag : sante du disque" "${bilan:-mesure impossible}" ;;
	124) err "AcmeFrag : sante du disque trop longue (> ${ACMEFRAG_DELAI_SANTE}s)"; NB_ECHEC=$((NB_ECHEC + 1)) ;;
	*) err "AcmeFrag : sante du disque en echec (code $code)"; NB_ECHEC=$((NB_ECHEC + 1)) ;;
	esac
fi

bilan_service "Bilan AcmeFrag"
exit $?
