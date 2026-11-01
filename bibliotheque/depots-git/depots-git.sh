#!/usr/bin/env bash
# depots-git.sh - Mise a jour de vos scripts et outils installes par git.
#
# Pour chaque depot de DEPOTS_GIT : recherche des nouveautes (git fetch),
# puis avance rapide (--ff-only) si l'arbre de travail est propre. Des
# modifications locales ou un historique divergent ne sont JAMAIS
# ecrases : le script le signale et passe au suivant. L'avance rapide est
# aussi reportee tant qu'une unite systemd declaree pour ce depot tourne
# (DEPOTS_GIT_UNITES) ; apres elle, les services declares sont redemarres
# (DEPOTS_GIT_RELANCER).
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
# Unites systemd --user qui executent le code d'un depot : tant que l'une
# tourne, l'avance rapide est reportee au passage suivant (le fetch a lieu).
# Declarer le .service qui execute le code, pas son .timer (toujours actif) ;
# un service permanent bloquerait l'avance a chaque passage.
# ex. declare -A DEPOTS_GIT_UNITES=(["$HOME/outils/mon-script"]="mon-script.service")
if ! declare -p DEPOTS_GIT_UNITES >/dev/null 2>&1; then declare -A DEPOTS_GIT_UNITES=(); fi
# Services permanents qui executent le code d'un depot : redemarres
# (try-restart : jamais demarres s'ils sont arretes) apres une avance rapide,
# sinon ils garderaient l'ancien code en memoire.
# ex. declare -A DEPOTS_GIT_RELANCER=(["$HOME/outils/mon-script"]="mon-script-web.service")
if ! declare -p DEPOTS_GIT_RELANCER >/dev/null 2>&1; then declare -A DEPOTS_GIT_RELANCER=(); fi
: "${DEPOTS_APPLIQUER:=oui}"       # non = signaler seulement
: "${CHEZMOI_VERIFIER:=oui}"       # non = ignorer chezmoi
# -------------------------------------------------------------------------------

titre "MISE A JOUR DES DEPOTS GIT"
verifier_commandes git || { err "git absent, arret."; exit 1; }
# Sans -A, ${TABLEAU[chemin]} serait un calcul d'indice : aucune unite ne
# serait trouvee, et le code avancerait sous un processus en cours ou
# resterait ancien dans un service jamais redemarre.
for tableau in DEPOTS_GIT_UNITES DEPOTS_GIT_RELANCER; do
	if [[ "$(declare -p "$tableau")" != "declare -A"* ]]; then
		err "$tableau doit etre un tableau associatif (declare -A dans local.conf), arret."
		exit 1
	fi
done

# retard <depot> : nombre de commits de l'amont absents localement.
retard() { git -C "$1" rev-list --count 'HEAD..@{u}' 2>/dev/null || echo 0; }

# unites_du_depot <tableau> <depot> : unites declarees pour ce depot dans le
# tableau associatif nomme, separees par des espaces (toutes les cles qui le
# designent). Les cles se comparent apres readlink -f (« / » final, lien
# symbolique) ; maj_depot a deja verifie que le depot existe.
unites_du_depot() {
	local -n _unites_tab="$1"
	local cle cible
	cible="$(readlink -f "$2")"
	for cle in "${!_unites_tab[@]}"; do
		[ "$(readlink -f "$cle")" = "$cible" ] && printf '%s ' "${_unites_tab[$cle]}"
	done
}

# unite_en_cours <depot> : affiche « <unite> en cours (<etat>) » pour la
# premiere unite de DEPOTS_GIT_UNITES qui n'est ni inactive ni en echec ;
# code 1 si aucune. L'etat affiche fait foi, pas le code : `is-active` rend 3
# pour un service oneshot en cours (« activating »). Un etat illisible bloque
# aussi (on ne change pas un code peut-etre en execution).
unite_en_cours() {
	local unite etat unites
	read -ra unites <<<"$(unites_du_depot DEPOTS_GIT_UNITES "$1")"
	for unite in "${unites[@]}"; do
		etat="$(timeout 10 systemctl --user is-active -- "$unite" 2>/dev/null)"
		case "$etat" in
			inactive | failed) ;;
			"") echo "$unite : etat illisible (systemctl --user injoignable ?)"; return 0 ;;
			*) echo "$unite en cours ($etat)"; return 0 ;;
		esac
	done
	return 1
}

maj_depot() {
	local depot="$1" nom n avant apres occupe unite relancer
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
		point_attention "$nom : $n commit(s) disponible(s), non appliques (DEPOTS_APPLIQUER=non)" \
			"git -C $depot pull --ff-only" \
			"le depot reste en retard sur sa branche suivie" \
			"avance rapide du depot ; refus sans rien toucher s'il a diverge ou si des modifications locales touchent les memes fichiers"
		return
	fi
	if [ -n "$(git -C "$depot" status --porcelain --untracked-files=no)" ]; then
		point_attention "$nom : $n commit(s) disponible(s), non appliques : modifications locales" \
			"git -C $depot status" \
			"la mise a jour automatique est bloquee par des modifications locales" \
			"affiche les fichiers modifies, sans rien changer ; a committer ou ecarter vous-meme"
		return
	fi
	# Une unite peut demarrer entre ce controle et le merge : fenetre assumee
	# (quelques millisecondes, contre des minutes pour un passage).
	if occupe="$(unite_en_cours "$depot")"; then
		ignorer_etape "$nom" "avance rapide reportee : $occupe, $n commit(s) en attente"
		return
	fi
	if etape "$nom : avance rapide ($n commit(s))" 120 git -C "$depot" merge -q --ff-only '@{u}'; then
		apres="$(git -C "$depot" rev-parse --short HEAD)"
		NB_MAJ=$((NB_MAJ + 1))
		enregistrer_version "$nom" "$avant" "$apres"
		git -C "$depot" log --oneline "$avant..$apres" 2>/dev/null | head -10 | sed 's/^/    /'
		read -ra relancer <<<"$(unites_du_depot DEPOTS_GIT_RELANCER "$depot")"
		# 200 s : arret puis demarrage, chacun borne a 90 s par defaut par systemd.
		# Une unite aux delais plus longs est vue en echec au-dela, alors que
		# systemd poursuit le redemarrage. Un echec n'est pas retente : au
		# passage suivant, le depot est a jour.
		for unite in "${relancer[@]}"; do
			etape "$nom : redemarrage de $unite" 200 systemctl --user try-restart -- "$unite" ||
				point_attention "$nom : $unite non redemarre apres l'avance rapide ($avant -> $apres)" \
					"systemctl --user restart -- $unite" \
					"le service est arrete ou tourne sur l'ancien code, et les passages suivants ne le relanceront pas (depot a jour)" \
					"redemarre le service sur le nouveau code ; s'il echoue encore : journalctl --user-unit $unite, ou retour arriere par git -C $depot reset --keep $avant puis systemctl --user restart -- $unite, en retirant le depot de DEPOTS_GIT le temps de corriger (sinon le passage suivant refait l'avance)"
		done
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
		point_attention "chezmoi : $n commit(s) en attente dans le depot source" "chezmoi update" \
			"les fichiers de la machine ne suivent pas les derniers commits de la source" \
			"tire le depot source puis applique ses fichiers (chezmoi demande avant d'ecraser un fichier modifie)"
	else
		inchanger_etape "chezmoi" "depot source a jour"
	fi
	if [ -n "$(chezmoi status 2>/dev/null)" ]; then
		point_attention "chezmoi : des fichiers different de la source" "chezmoi status" \
			"la machine et la source divergent : un chezmoi apply alignerait ces fichiers sur la source (en demandant pour un fichier modifie a la main)" \
			"liste les fichiers en ecart, sans rien changer"
	fi
}

if [ ${#DEPOTS_GIT[@]} -eq 0 ]; then
	ignorer_etape "Depots git" "aucun depot declare (DEPOTS_GIT dans local.conf)"
fi
# verifier_unites <tableau> : une cle sans depot (faute de frappe, « ~ » non
# developpe) ou une unite inconnue ne sert a rien, un .timer attendu bloque
# toujours : le dire plutot que de laisser croire a une protection.
verifier_unites() {
	local -n _verif_tab="$1"
	local cle chemin depot trouve unite liste effet
	case "$1" in
		DEPOTS_GIT_UNITES) effet="l'avance rapide n'attend pas" ;;
		*) effet="une avance rapide ne redemarre pas" ;;
	esac
	for cle in "${!_verif_tab[@]}"; do
		trouve=non chemin="$(readlink -f "$cle")"
		for depot in "${DEPOTS_GIT[@]}"; do
			[ -n "$chemin" ] && [ "$chemin" = "$(readlink -f "$depot")" ] && trouve=oui
		done
		[ "$trouve" = oui ] ||
			point_attention "$1 : $cle ne correspond a aucun depot de DEPOTS_GIT, ses unites sont sans effet" "" \
				"$effet ses unites" "corriger la cle dans local.conf (chemin ecrit comme dans DEPOTS_GIT)"
		read -ra liste <<<"${_verif_tab[$cle]}"
		for unite in "${liste[@]}"; do
			case "$1:$unite" in
				DEPOTS_GIT_UNITES:*.timer) point_attention "$1 : $unite est un timer, toujours actif" "" \
					"l'avance rapide de $cle sera reportee a chaque passage" "declarer le .service qu'il declenche" ;;
			esac
			[ "$(timeout 10 systemctl --user show -p LoadState --value -- "$unite" 2>/dev/null)" = not-found ] &&
				point_attention "$1 : unite $unite inconnue de systemd --user" "" \
					"$effet cette unite" "corriger le nom de l'unite dans local.conf"
		done
	done
}
verifier_unites DEPOTS_GIT_UNITES
verifier_unites DEPOTS_GIT_RELANCER
for depot in "${DEPOTS_GIT[@]}"; do
	maj_depot "$depot"
done

if [ "$CHEZMOI_VERIFIER" = oui ] && command -v chezmoi >/dev/null 2>&1; then
	verifier_chezmoi
fi

bilan_service "Bilan des depots git"
exit $?
