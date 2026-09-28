#!/usr/bin/env bash
################################################################################
# restore.sh - Restauration interactive d'une sauvegarde Acmechanic.
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Jean-Philippe Reculeau — voir LICENSE
################################################################################
#
# Fonctionne pour les services Docker comme pour les applications Flatpak.
#
# Usage :
#   ./restore.sh                 liste les services sauvegardes
#   ./restore.sh <service>       liste les archives et propose un choix
#   ./restore.sh <service> <N>   restaure directement l'archive numero N
#
# Le service est arrete, restaure, puis relance et verifie.
# L'etat precedent est toujours mis de cote avant ecrasement : aucune
# restauration n'est definitive.

set -uo pipefail

SERVICE_NAME="restore"
ACMECHANIC_HOME="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
export ACMECHANIC_HOME
# shellcheck source=lib/common.sh
source "${ACMECHANIC_HOME}/lib/common.sh"
# shellcheck source=config.sh
source "${ACMECHANIC_HOME}/config.sh"
# shellcheck source=lib/backup.sh
source "${ACMECHANIC_HOME}/lib/backup.sh"

service="${1:-}"

# --- Sans argument : on montre ce qui est disponible ---
if [ -z "$service" ]; then
	titre "SAUVEGARDES DISPONIBLES"
	printf '%-14s %-9s %s\n' "SERVICE" "TYPE" "SAUVEGARDES"
	printf '%s\n' "----------------------------------------------"
	for s in "${SERVICES_CONNUS[@]}"; do
		nb=$(find "$BACKUP_ROOT/$s" -maxdepth 1 -name "${s}_*.tar.gz" -type f 2>/dev/null | wc -l)
		type_s="$(config_service "$s" type)"
		if [ "$nb" -gt 0 ]; then
			printf '%s%-14s%s %-9s %s archive(s)\n' "$C_GREEN" "$s" "$C_OFF" "$type_s" "$nb"
		else
			printf '%s%-14s%s %-9s aucune\n' "$C_YELLOW" "$s" "$C_OFF" "$type_s"
		fi
	done
	echo
	echo "Pour restaurer :  $0 <service>"
	exit 0
fi

# --- Verification que le service est connu ---
connu=false
for s in "${SERVICES_CONNUS[@]}"; do
	[ "$s" = "$service" ] && connu=true
done
if [ "$connu" != true ]; then
	err "Service inconnu : $service"
	echo "Services connus : ${SERVICES_CONNUS[*]}"
	exit 1
fi

type_service="$(config_service "$service" type)"
cible="$(config_service "$service" cible)"

titre "RESTAURATION DE $service"

lister_sauvegardes "$service" || exit 1

# --- Choix de l'archive ---
choix="${2:-}"
if [ -z "$choix" ]; then
	echo
	read -r -p "Numero de l'archive a restaurer (Entree pour annuler) : " choix
	if [ -z "$choix" ]; then
		log "Restauration annulee par l'utilisateur."
		exit 0
	fi
fi

if ! [[ "$choix" =~ ^[0-9]+$ ]] || [ "$choix" -lt 1 ] || [ "$choix" -gt ${#ARCHIVES_TROUVEES[@]} ]; then
	err "Numero invalide : $choix (attendu entre 1 et ${#ARCHIVES_TROUVEES[@]})"
	exit 1
fi

archive="${ARCHIVES_TROUVEES[$((choix - 1))]}"
manifeste="${archive%.tar.gz}.manifest"

echo
printf '%sArchive selectionnee%s\n' "$C_BOLD" "$C_OFF"
if [ -f "$manifeste" ]; then
	sed 's/^/  /' "$manifeste"
else
	warn "Aucun manifeste : origine et integrite non documentees."
fi

echo
printf '%sCe qui va se passer :%s\n' "$C_BOLD" "$C_OFF"
if [ "$type_service" = "flatpak" ]; then
	appid="$(config_service "$service" appid)"
	echo "  1. Fermeture de l'application  : $appid"
elif [ "$type_service" = "fichiers" ]; then
	echo "  1. Aucun service a arreter (restauration de fichiers)"
else
	projet="$(config_service "$service" projet)"
	conteneur="$(config_service "$service" conteneur)"
	echo "  1. Arret du service            : $conteneur"
fi
echo "  2. Mise de cote de l'etat actuel dans $cible/.avant-restauration-<date>"
echo "  3. Extraction de l'archive dans $cible"
if [ "$type_service" = "flatpak" ]; then
	echo "  4. Verification des fichiers restaures"
	echo "     (l'application n'est pas relancee : lancez-la vous-meme)"
elif [ "$type_service" = "fichiers" ]; then
	echo "  4. Verification des fichiers restaures"
	echo "     (si une application utilise ces fichiers, relancez-la ensuite)"
else
	echo "  4. Redemarrage et verification que le service repond"
fi
echo

read -r -p "Confirmer la restauration ? (tapez oui) : " reponse
if [ "$reponse" != "oui" ]; then
	log "Restauration annulee : confirmation non donnee."
	exit 0
fi

# =====================================================================
# Cas d'une application Flatpak
# =====================================================================
if [ "$type_service" = "flatpak" ]; then
	appid="$(config_service "$service" appid)"

	# 1. Fermeture de l'application.
	if flatpak ps --columns=application 2>/dev/null | grep -qx "$appid"; then
		step "Fermeture de $appid"
		flatpak kill "$appid" 2>/dev/null
		sleep 3
		if flatpak ps --columns=application 2>/dev/null | grep -qx "$appid"; then
			err "L'application ne se ferme pas. Fermez-la manuellement puis relancez."
			exit 1
		fi
		ok "Application fermee"
	else
		log "L'application n'est pas en cours d'execution."
	fi

	# 2 et 3. Restauration.
	if ! restaurer_sauvegarde "$archive" "$cible"; then
		err "La restauration a echoue. Consultez $LOG_FILE"
		exit 1
	fi

	# 4. Verification : les fichiers de configuration attendus sont-ils la ?
	step "Verification des fichiers restaures"
	if [ -d "$cible/config" ]; then
		nb="$(find "$cible/config" -type f | wc -l)"
		ok "Configuration restauree ($nb fichier(s) dans config/)"
	else
		warn "Pas de dossier config apres restauration : verifiez le contenu de l'archive."
	fi

	echo
	ok "Restauration terminee pour $service."
	log "Lancez l'application pour verifier :  flatpak run $appid"

# =====================================================================
# Cas d'une restauration de fichiers (ni Docker ni Flatpak)
# =====================================================================
elif [ "$type_service" = "fichiers" ]; then
	if ! restaurer_sauvegarde "$archive" "$cible"; then
		err "La restauration a echoue. Consultez $LOG_FILE"
		exit 1
	fi

	step "Verification des fichiers restaures"
	nb="$(find "$cible" -maxdepth 2 -type f 2>/dev/null | wc -l)"
	ok "$nb fichier(s) presents dans $cible"

	echo
	ok "Restauration terminee pour $service."
	log "Relancez l'application concernee pour qu'elle relise ses fichiers."

# =====================================================================
# Cas d'un service Docker
# =====================================================================
else
	projet="$(config_service "$service" projet)"
	conteneur="$(config_service "$service" conteneur)"
	url="$(config_service "$service" url)"

	# 1. Arret du service.
	if [ -n "$projet" ] && [ -d "$projet" ]; then
		step "Arret de $conteneur"
		if compose "$projet" stop "$conteneur" 2>>"$LOG_FILE"; then
			ok "Service arrete"
		else
			warn "L'arret via docker compose a echoue, tentative directe..."
			if docker stop "$conteneur" >/dev/null 2>&1; then
				ok "Conteneur arrete"
			else
				warn "Le conteneur n'etait peut-etre pas demarre"
			fi
		fi
	else
		warn "Pas de projet docker declare : aucun arret effectue"
	fi

	# 2 et 3. Restauration.
	if ! restaurer_sauvegarde "$archive" "$cible"; then
		err "La restauration a echoue. Le service reste arrete."
		err "Pour le relancer :"
		err "  docker compose --project-directory $projet up -d $conteneur"
		exit 1
	fi

	# 4. Redemarrage et verification.
	if [ -n "$projet" ] && [ -d "$projet" ]; then
		step "Redemarrage de $conteneur"
		if compose "$projet" up -d "$conteneur" 2>>"$LOG_FILE"; then
			ok "Conteneur relance"
		else
			err "Echec du redemarrage. Relancez a la main :"
			err "  docker compose --project-directory $projet up -d $conteneur"
			exit 1
		fi

		if [ -n "$url" ]; then
			step "Verification que le service repond"
			if attendre_http "$url" 20 3; then
				echo
				ok "Restauration reussie : $service fonctionne avec les donnees restaurees."
			else
				err "Le service ne repond pas apres restauration."
				err "Journal du conteneur :"
				compose "$projet" logs --tail=20 "$conteneur" 2>&1 | sed 's/^/    /'
				err "Pour revenir en arriere, les donnees precedentes sont dans :"
				err "  $cible/.avant-restauration-*"
				exit 1
			fi
		fi
	fi
fi

echo
log "Pense-bete : une fois $service verifie de votre cote, vous pouvez supprimer"
log "le dossier $cible/.avant-restauration-* pour recuperer de l'espace disque."
exit 0
