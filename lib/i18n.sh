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
i18n_charger() {
	local l
	l="$(i18n_langue)"
	MSG=()
	# shellcheck source=../locale/fr.sh
	source "$_I18N_DOSSIER/fr.sh"
	# shellcheck source=/dev/null
	[ "$l" != fr ] && source "$_I18N_DOSSIER/$l.sh"
	I18N_LANGUE="$l"
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
