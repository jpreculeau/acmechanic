#!/usr/bin/env bash
# micrologiciel.sh - Signale les mises a jour de micrologiciel, sans les
# appliquer : un flash rate sans surveillance peut rendre la machine
# indemarrable. La commande a lancer vous-meme est indiquee.
#
#   Raspberry Pi  rpi-eeprom-update (chargeur d'amorcage EEPROM)
#   PC            fwupdmgr (LVFS : BIOS/UEFI, SSD, docks...)
#
# Installation : ln -s "$PWD/bibliotheque/micrologiciel" services/micrologiciel
#
# SPDX-License-Identifier: GPL-3.0-or-later

set -uo pipefail

SERVICE_NAME="micrologiciel"
: "${ACMECHANIC_HOME:=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)}"
# shellcheck source=../../lib/service.sh
source "${ACMECHANIC_HOME}/lib/service.sh"

# --- Reglages (surchargeables dans local.conf) ---------------------------------
: "${MICROLOGICIEL_FWUPD_RAFRAICHIR:=oui}"   # telecharger les metadonnees LVFS
# -------------------------------------------------------------------------------

titre "MICROLOGICIEL"
TROUVE=non

# --- Raspberry Pi : EEPROM -------------------------------------------------------
# rpi-eeprom-update sans option ne fait que comparer : code 0 = a jour,
# 1 = mise a jour disponible, autre = erreur.
if command -v rpi-eeprom-update >/dev/null 2>&1; then
	TROUVE=oui
	step "EEPROM du Raspberry Pi : verification"
	sortie="$(timeout 60 rpi-eeprom-update 2>&1)"
	code=$?
	actuelle="$(sed -n 's/^ *CURRENT: *//p' <<<"$sortie" | head -1)"
	derniere="$(sed -n 's/^ *LATEST: *//p' <<<"$sortie" | head -1)"
	case "$code" in
	0)
		inchanger_etape "EEPROM" "a jour (${actuelle%% (*})"
		enregistrer_version "eeprom" "${actuelle%% (*}" "${actuelle%% (*}"
		;;
	1)
		point_attention "EEPROM : mise a jour disponible (${actuelle%% (*} -> ${derniere%% (*})" \
			"sudo rpi-eeprom-update -a && sudo reboot"
		enregistrer_version "eeprom" "${actuelle%% (*}" "${actuelle%% (*}"
		;;
	*)
		err "EEPROM : verification impossible (code $code)."
		tail -5 <<<"$sortie" | sed 's/^/    /'
		NB_ECHEC=$((NB_ECHEC + 1))
		;;
	esac
fi

# --- PC : fwupd / LVFS ---------------------------------------------------------
# get-updates : code 0 = mises a jour listees, 2 = rien a faire.
if command -v fwupdmgr >/dev/null 2>&1; then
	TROUVE=oui
	if [ "$MICROLOGICIEL_FWUPD_RAFRAICHIR" = oui ]; then
		step "fwupd : metadonnees LVFS"
		timeout 120 fwupdmgr refresh --force >/dev/null 2>&1 ||
			warn "fwupd : metadonnees non rafraichies (hors ligne ?), verification sur l'existant."
	fi
	step "fwupd : verification"
	sortie="$(timeout 120 fwupdmgr get-updates --no-unreported-check 2>&1)"
	code=$?
	case "$code" in
	0)
		grep -E '│|├|└|New version|Nouvelle version' <<<"$sortie" | head -20 | sed 's/^/    /'
		point_attention "fwupd : micrologiciel(s) a mettre a jour (detail : fwupdmgr get-updates)" \
			"sudo fwupdmgr update"
		;;
	2) inchanger_etape "fwupd" "aucune mise a jour" ;;
	*)
		err "fwupd : verification impossible (code $code)."
		tail -5 <<<"$sortie" | sed 's/^/    /'
		NB_ECHEC=$((NB_ECHEC + 1))
		;;
	esac
fi

[ "$TROUVE" = oui ] || ignorer_etape "Micrologiciel" "ni rpi-eeprom-update ni fwupdmgr"

bilan_service "Bilan micrologiciel"
exit $?
