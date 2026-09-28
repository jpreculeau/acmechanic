# shellcheck shell=bash
################################################################################
# CONFIGURATION - Acmechanic
#
# Ne modifiez pas ce fichier pour vos réglages machine : créez plutôt
#   /etc/acmechanic.conf               (réglages système)
#   <dossier Acmechanic>/local.conf    (réglages locaux, ignoré par git)
# en y définissant les variables à surcharger (modèle : local.conf.example).
# Priorité : local.conf > /etc/acmechanic.conf > variables d'env > défauts ci-dessous.
#
# Sourcé par acmechanic.sh, restore.sh et chaque script de service.
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Jean-Philippe Reculeau — voir LICENSE
################################################################################

[ -n "${_CONFIG_SH_LOADED:-}" ] && return 0
_CONFIG_SH_LOADED=1

: "${ACMECHANIC_HOME:=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

# --- Surcharges optionnelles (chargées AVANT les défauts) --------------------
for _conf in /etc/acmechanic.conf "${ACMECHANIC_HOME}/local.conf"; do
	# shellcheck source=/dev/null
	[[ -r "$_conf" ]] && source "$_conf"
done
unset _conf

# --- Découverte des services -------------------------------------------------
# Tout script <nom>/<nom>.sh qui source lib/common.sh est un service.
: "${SERVICES_DIR:=${ACMECHANIC_HOME}/services}"
# Dossiers supplémentaires scannés (même règle), ex. ("$HOME/scripts").
if [[ -z "${SERVICES_EXTRA_DIRS+x}" ]]; then SERVICES_EXTRA_DIRS=(); fi
# Liens NN-<nom>.sh imposant l'ordre d'exécution (10-x avant 20-y).
: "${ORDRE_DIR:=${ACMECHANIC_HOME}/ordre.d}"
# Noms de scripts à ne jamais exécuter comme service (outils).
if [[ -z "${EXCLUS+x}" ]]; then EXCLUS=(acmechanic restore); fi

# --- Délais (secondes) -------------------------------------------------------
# Par service : doit couvrir un gros pull (DELAI_PULL, lib/common.sh)
# + arrêt + sauvegarde + redémarrage + vérification (~2500 s au pire).
: "${DELAI_SERVICE:=3000}"
: "${DELAI_SYSTEME:=1800}"             # upgrade Nala / APT

# --- Sauvegardes -------------------------------------------------------------
: "${BACKUP_ROOT:=$HOME/backups}"      # un sous-dossier par service
: "${BACKUP_GARDER:=5}"                # archives conservées par service

# --- Services restaurables (restore.sh) --------------------------------------
# À déclarer dans local.conf (voir local.conf.example).
if [[ -z "${SERVICES_CONNUS+x}" ]]; then SERVICES_CONNUS=(); fi
# Applications Flatpak dont la configuration est sauvegardée
# (format « nom-court:identifiant.flatpak »).
if [[ -z "${FLATPAK_SAUVEGARDES+x}" ]]; then FLATPAK_SAUVEGARDES=(); fi

# config_service <service> <clé> : décrit un service restaurable.
#   type      : docker | flatpak | fichiers
#   cible     : dossier où les données sont restaurées
#   projet    : (docker) dossier contenant docker-compose.yml
#   conteneur : (docker) nom du service dans le compose
#   url       : (docker) adresse testée après redémarrage
#   appid     : (flatpak) identifiant Flatpak
# Redéfinissez-la dans local.conf ; par défaut, aucun service connu.
if ! declare -F config_service >/dev/null; then
	config_service() { echo ""; }
fi
