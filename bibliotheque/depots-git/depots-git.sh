#!/usr/bin/env bash
# depots-git.sh - Mise a jour de vos scripts et outils installes par git.
#
# Pour chaque depot de DEPOTS_GIT : recherche des nouveautes (git fetch),
# puis avance rapide (--ff-only) si l'arbre de travail est propre. Des
# modifications locales ou un historique divergent ne sont JAMAIS
# ecrases : le script le signale et passe au suivant.
#
# Acmechanic lui-meme n'est pas traite ici : il se met a jour seul, en fin
# de run (ACMECHANIC_AUTO_MAJ), pour ne pas modifier des scripts en cours
# d'execution.
#
# chezmoi (si present) : les nouveautes du depot source sont SIGNALEES,
# jamais appliquees (un `chezmoi update` peut ecraser des fichiers).
#
# Installation : ln -s "$PWD/bibliotheque/depots-git" services/depots-git
#
# SPDX-License-Identifier: GPL-3.0-or-later

set -uo pipefail

SERVICE_NAME="depots-git"
: "${ACMECHANIC_HOME:=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)}"
# shellcheck source=../../lib/service.sh
source "${ACMECHANIC_HOME}/lib/service.sh"

# --- Reglages (surchargeables dans local.conf) ---------------------------------
# Depots a suivre, ex. DEPOTS_GIT=("$HOME/acmefrag" "$HOME/outils/mon-script")
if [[ -z "${DEPOTS_GIT+x}" ]]; then DEPOTS_GIT=(); fi
: "${DEPOTS_APPLIQUER:=oui}"       # non = signaler seulement
: "${CHEZMOI_VERIFIER:=oui}"       # non = ignorer chezmoi
# -------------------------------------------------------------------------------

titre "MISE A JOUR DES DEPOTS GIT"
verifier_commandes git || { err "git absent, arret."; exit 1; }

# retard <depot> : nombre de commits de l'amont absents localement.
retard() { git -C "$1" rev-list --count 'HEAD..@{u}' 2>/dev/null || echo 0; }

maj_depot() {
	local depot="$1" nom n avant apres
	nom="$(basename "$depot")"
	if ! git -C "$depot" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		ignorer_etape "$nom" "pas un depot git : $depot"
		return
	fi
	if [ "$(readlink -f "$depot")" = "$(readlink -f "$ACMECHANIC_HOME")" ]; then
		ignorer_etape "$nom" "Acmechanic se met a jour lui-meme en fin de run"
		return
	fi
	if ! git -C "$depot" rev-parse -q --verify '@{u}' >/dev/null 2>&1; then
		ignorer_etape "$nom" "aucune branche amont suivie"
		return
	fi
	etape "$nom : recherche de nouveautes" 90 git -C "$depot" fetch -q || return
	n="$(retard "$depot")"
	avant="$(git -C "$depot" rev-parse --short HEAD)"
	if [ "$n" -eq 0 ]; then
		inchanger_etape "$nom" "a jour ($avant)"
		enregistrer_version "$nom" "$avant" "$avant"
		return
	fi
	if [ "$DEPOTS_APPLIQUER" != oui ]; then
		warn "$nom : $n commit(s) disponible(s), non appliques (DEPOTS_APPLIQUER=non)."
		return
	fi
	if [ -n "$(git -C "$depot" status --porcelain --untracked-files=no)" ]; then
		warn "$nom : $n commit(s) disponible(s), non appliques : modifications locales."
		return
	fi
	if etape "$nom : avance rapide ($n commit(s))" 120 git -C "$depot" merge -q --ff-only '@{u}'; then
		apres="$(git -C "$depot" rev-parse --short HEAD)"
		NB_MAJ=$((NB_MAJ + 1))
		enregistrer_version "$nom" "$avant" "$apres"
		git -C "$depot" log --oneline "$avant..$apres" 2>/dev/null | head -10 | sed 's/^/    /'
	fi
}

verifier_chezmoi() {
	local source n
	source="$(chezmoi source-path 2>/dev/null)" || return 0
	# source-path peut designer un sous-dossier (.chezmoiroot) : on remonte
	# a la racine du depot.
	source="$(git -C "$source" rev-parse --show-toplevel 2>/dev/null)" || return 0
	git -C "$source" rev-parse -q --verify '@{u}' >/dev/null 2>&1 || return 0
	etape "chezmoi : recherche de nouveautes" 90 git -C "$source" fetch -q || return
	n="$(retard "$source")"
	if [ "$n" -gt 0 ]; then
		warn "chezmoi : $n commit(s) en attente dans le depot source. A appliquer a la main : chezmoi update"
	else
		inchanger_etape "chezmoi" "depot source a jour"
	fi
	if [ -n "$(chezmoi status 2>/dev/null)" ]; then
		warn "chezmoi : des fichiers different de la source (voir : chezmoi status)."
	fi
}

if [ ${#DEPOTS_GIT[@]} -eq 0 ]; then
	ignorer_etape "Depots git" "aucun depot declare (DEPOTS_GIT dans local.conf)"
fi
for depot in "${DEPOTS_GIT[@]}"; do
	maj_depot "$depot"
done

if [ "$CHEZMOI_VERIFIER" = oui ] && command -v chezmoi >/dev/null 2>&1; then
	verifier_chezmoi
fi

bilan_service "Bilan des depots git"
exit $?
