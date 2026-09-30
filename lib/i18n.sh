# shellcheck shell=bash
################################################################################
# i18n.sh - Textes affiches par Acmechanic, dans la langue de l'utilisateur.
#
# Catalogues : locale/<langue>.sh, un tableau associatif MSG[cle]=texte.
#   - locale/fr.sh est la REFERENCE (toujours chargee, donc toujours
#     complete) ; la langue choisie ecrase ensuite ses cles.
#   - Langue : ACMECHANIC_LANGUE (local.conf), sinon LC_ALL / LC_MESSAGES /
#     LANG ; sans catalogue pour cette langue, anglais.
#   - Ajouter une langue : copier locale/en.sh en locale/<xx>.sh et
#     traduire. tests/run_tests.sh verifie que chaque catalogue a
#     exactement les cles de la reference.
#
# Themes : locale/themes/<theme>/<langue>.sh remplacent seulement les
# textes « fun » (statuts, onomatopees, titres, fin). ACMECHANIC_THEME
# (local.conf) ; sans fichier pour la langue, la version anglaise du theme.
# ACMECHANIC_THEME=hasard / ACMECHANIC_LANGUE=hasard : tirage au sort a
# chaque passage.
#
# Les textes peuvent contenir des %s / %d (format printf) : t les remplit.
# Les journaux (log/ok/warn/err) restent en francais : voir ROADMAP.md.
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Jean-Philippe Reculeau — voir LICENSE
################################################################################

[ -n "${_I18N_SH_LOADED:-}" ] && return 0
_I18N_SH_LOADED=1

declare -gA MSG=()
_I18N_DOSSIER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../locale" && pwd)"

# i18n_langue : code de langue retenu (fr, en, ...).
i18n_langue() {
	local l="${ACMECHANIC_LANGUE:-${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}}"
	l="${l%%[_.@-]*}"
	case "$l" in "" | C | POSIX) l=en ;; esac
	[ -r "$_I18N_DOSSIER/$l.sh" ] || l=en
	echo "$l"
}

# i18n_charger : (re)charge les catalogues. Appele au chargement, puis par
# config.sh une fois local.conf lu (ACMECHANIC_LANGUE peut y etre fixee).
# _i18n_tirer <variable> <commande> : range dans <variable> une ligne
# au hasard de la sortie de <commande>.
_i18n_tirer() {
	local -n _tirage="$1"
	local -a l
	mapfile -t l < <("$2")
	_tirage="${l[RANDOM % ${#l[@]}]}"
}

# i18n_langues : codes des langues disponibles, un par ligne.
i18n_langues() {
	local f
	for f in "$_I18N_DOSSIER"/*.sh; do basename "$f" .sh; done
}

# hasard (ou random, aleatoire) : langue et/ou theme tires au sort UNE fois
# par passage ; le tirage est exporte, donc identique pour tout le passage
# (rechargements, services lances par Acmechanic).
_i18n_hasard() {
	case "${1:-}" in hasard | random | aleatoire | aléatoire) return 0 ;; esac
	return 1
}

i18n_charger() {
	local l
	if _i18n_hasard "${ACMECHANIC_LANGUE:-}"; then
		_i18n_tirer ACMECHANIC_LANGUE i18n_langues
		export ACMECHANIC_LANGUE
	fi
	if _i18n_hasard "${ACMECHANIC_THEME:-}"; then
		_i18n_tirer ACMECHANIC_THEME i18n_themes
		export ACMECHANIC_THEME
	fi
	l="$(i18n_langue)"
	MSG=()
	# shellcheck source=../locale/fr.sh
	source "$_I18N_DOSSIER/fr.sh"
	# shellcheck source=/dev/null
	[ "$l" != fr ] && source "$_I18N_DOSSIER/$l.sh"
	I18N_LANGUE="$l"
	# Theme (facultatif) par-dessus la langue.
	local th="${ACMECHANIC_THEME:-}" d
	I18N_THEME=""
	case "$th" in "" | acme) return 0 ;; esac
	d="$_I18N_DOSSIER/themes/$th"
	if [ -r "$d/$l.sh" ]; then
		# shellcheck source=/dev/null
		source "$d/$l.sh"
	elif [ -r "$d/en.sh" ]; then
		# shellcheck source=/dev/null
		source "$d/en.sh"
	else
		return 0
	fi
	I18N_THEME="$th"
}

# i18n_themes : noms des themes disponibles, un par ligne.
i18n_themes() {
	local d
	echo acme
	for d in "$_I18N_DOSSIER"/themes/*/; do
		[ -d "$d" ] && basename "$d"
	done
}

# t <cle> [valeurs...] : texte traduit, rempli par printf. Une cle
# inconnue s'affiche telle quelle (visible, jamais bloquant).
t() {
	local f="${MSG[$1]:-$1}"
	shift
	# shellcheck disable=SC2059 # le format vient du catalogue (fichier du depot)
	printf -- "$f" "$@"
}

# tv <variable> <cle> [valeurs...] : comme t, sans sous-shell (boucle
# d'affichage).
tv() {
	local -n _tv_dest="$1"
	local f="${MSG[$2]:-$2}"
	shift 2
	# shellcheck disable=SC2059
	printf -v _tv_dest -- "$f" "$@"
}

i18n_charger
