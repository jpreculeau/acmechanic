#!/usr/bin/env bash
# flatpak.sh - Maintenance des applications Flatpak.
#
# Meme traitement que les services Docker : sauvegarde de la configuration
# avant mise a jour, mise a jour, puis verification.
#
# Les donnees d'une application Flatpak vivent dans
# ~/.var/app/<identifiant>/ : config (parametres), data (etat de
# l'application) et cache (jetable, non sauvegarde).
#
# Les applications a sauvegarder sont declarees dans FLATPAK_SAUVEGARDES
# (voir config.sh / local.conf). Les autres sont simplement mises a jour.
#
# Installation : ln -s ../bibliotheque/flatpak services/flatpak
#
# SPDX-License-Identifier: GPL-3.0-or-later

set -uo pipefail

SERVICE_NAME="flatpak"
: "${ACMECHANIC_HOME:=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)}"
# shellcheck source=../../lib/service.sh
source "${ACMECHANIC_HOME}/lib/service.sh"

titre "MAINTENANCE DES APPLICATIONS FLATPAK"

if ! command -v flatpak >/dev/null 2>&1; then
	err "Flatpak n'est pas installe, rien a faire."
	exit 0
fi

# --- Suivi des applications tuées pour la sauvegarde ---
# flatpak.sh ferme (flatpak kill) les applications declarees qui
# tournaient, afin de copier leur configuration a froid. On retient
# ici celles qu'ON a reellement tuees, pour les relancer a la fin.
TYPES_APPS_TUEES=()

# Capture des versions avant mise a jour (par application declaree).
declare -A VER_AVANT
for entree in "${FLATPAK_SAUVEGARDES[@]}"; do
	nom="${entree%%:*}"
	appid="${entree##*:}"
	VER_AVANT[$nom]="$(version_flatpak "$appid" 2>/dev/null || echo "?")"
done

# --- Inventaire ---
log "Applications installees :"
flatpak list --app --columns=application,version,branch 2>/dev/null | sed 's/^/    /'

# =====================================================================
# 0. Y a-t-il quelque chose a mettre a jour ?
# =====================================================================
# Fermer les applications declarees (sauvegarde a froid) puis les
# relancer coute ~50-90 s a CHAQUE run, meme quand rien n'a change.
# On demande donc d'abord au registre s'il existe des mises a jour :
# sinon on saute sauvegarde (donc la fermeture des applications), mise a
# jour, nettoyage et verification.
#
# `remote-ls --updates` liste ce qui a une version plus recente, runtimes
# inclus (un runtime obsolete peut empecher une application de
# demarrer). Sortie vide ou erreur (hors ligne) => rien
# a faire, et de toute facon `flatpak update` echouerait.
# Les deux interrogations (utilisateur / systeme) sont independantes :
# lancees en parallele, le temps d'attente est divise par 2.
fichier_temp _MAJ_USER
fichier_temp _MAJ_SYS
timeout 60 flatpak remote-ls --updates --user >"$_MAJ_USER" 2>/dev/null &
_pid_user=$!
timeout 60 flatpak remote-ls --updates --system >"$_MAJ_SYS" 2>/dev/null &
_pid_sys=$!
wait "$_pid_user" "$_pid_sys"
MAJ_LISTE="$(cat "$_MAJ_USER" "$_MAJ_SYS")"
if [ -n "${MAJ_LISTE//[[:space:]]/}" ]; then
	MAJ_DISPONIBLE=true
	log "Mises a jour Flatpak disponibles :"
	echo "$MAJ_LISTE" | sed '/^[[:space:]]*$/d; s/^/    /'
else
	MAJ_DISPONIBLE=false
	log "Aucune mise a jour Flatpak disponible."
fi

# Une mise a jour de RUNTIME ne justifie pas de fermer une application :
# on ne ferme (et donc sauvegarde a froid) que si la mise a jour concerne
# une application declaree dans FLATPAK_SAUVEGARDES.
MAJ_APPS_DECLAREES=false
for entree in "${FLATPAK_SAUVEGARDES[@]}"; do
	if echo "$MAJ_LISTE" | grep -qF "${entree##*:}"; then
		MAJ_APPS_DECLAREES=true
		break
	fi
done
if [ "$MAJ_DISPONIBLE" = true ] && [ "$MAJ_APPS_DECLAREES" != true ]; then
	log "Mises a jour limitees aux runtimes : aucune application n'est fermee."
fi

# =====================================================================
# 1. Sauvegarde des applications declarees
# =====================================================================
# Les identifiants Flatpak contiennent des points, inutilisables comme
# nom de service : on utilise le nom court declare dans FLATPAK_SAUVEGARDES.
sauvegarder_applications() {
	local entree nom appid dossier
	for entree in "${FLATPAK_SAUVEGARDES[@]}"; do
		nom="${entree%%:*}"
		appid="${entree##*:}"
		dossier="$HOME/.var/app/$appid"

		if ! flatpak info "$appid" >/dev/null 2>&1; then
			ignorer_etape "$nom : sauvegarde" "application $appid non installee"
			continue
		fi

		if [ ! -d "$dossier" ]; then
			ignorer_etape "$nom : sauvegarde" "aucune donnee dans $dossier"
			continue
		fi

		# L'application doit etre fermee : ses fichiers de configuration
		# sont reecrits a la fermeture, une copie a chaud peut etre incoherente.
		if flatpak ps --columns=application 2>/dev/null | grep -qx "$appid"; then
			log "$nom est en cours d'execution, fermeture pour la sauvegarde..."
			flatpak kill "$appid" 2>/dev/null
			sleep 3
			if flatpak ps --columns=application 2>/dev/null | grep -qx "$appid"; then
				warn "$nom ne s'est pas ferme : la sauvegarde peut etre incoherente."
			else
				ok "$nom ferme"
				# On l'a tuee : on la relancera a la fin de la maintenance.
				TYPES_APPS_TUEES+=("$nom|$appid")
			fi
		fi

		# cache exclu : entierement reconstructible.
		# ipc-socket et lockfile exclus : fichiers de session sans interet.
		BACKUP_EXCLURE=(
			'cache'
			'*/ipc-socket'
			'*/lockfile'
		)

		run_etape "$nom : sauvegarde de la configuration" 600 \
			creer_sauvegarde "$nom" "$dossier" config data
	done
}

# =====================================================================
# 2. Verification de l'integrite
# =====================================================================
verifier_integrite() {
	# flatpak repair --dry-run signale les installations incoherentes
	# sans rien modifier. C'est une verification, pas une reparation.
	local sortie
	sortie="$(flatpak repair --user --dry-run 2>&1)"
	if echo "$sortie" | grep -qiE 'wrong|invalid|missing|corrupt'; then
		warn "Anomalies signalees par flatpak :"
		# shellcheck disable=SC2001 # indentation de chaque ligne
		echo "$sortie" | sed 's/^/    /'
		return 1
	fi
	log "Aucune anomalie signalee."
	return 0
}

# =====================================================================
# 3. Mise a jour, nettoyage, verification
# =====================================================================
mettre_a_jour_flatpak() {
	echo
	# Les applications installees pour l'utilisateur : aucun privilege requis.
	run_etape "Mise a jour des applications utilisateur" 1800 \
		flatpak update -y --noninteractive --user

	# Celles installees pour tout le systeme : sudo necessaire.
	if sudo_disponible; then
		run_etape "Mise a jour des applications systeme" 1800 \
			sudo -n flatpak update -y --noninteractive --system
	else
		ignorer_etape "Mise a jour des applications systeme" "sudo indisponible sans mot de passe"
	fi

	run_etape "Suppression des dependances inutilisees" 900 \
		flatpak uninstall --unused -y --noninteractive --user

	if sudo_disponible; then
		run_etape "Suppression des dependances systeme inutilisees" 900 \
			sudo -n flatpak uninstall --unused -y --noninteractive --system
	fi

	run_etape "Verification de l'integrite des installations" 300 verifier_integrite
}

if [ "$MAJ_APPS_DECLAREES" = true ]; then
	# Une application declaree va etre mise a jour : sauvegarde a froid
	# (donc fermeture) avant de toucher a quoi que ce soit.
	sauvegarder_applications
else
	ignorer_etape "Sauvegarde des applications declarees" \
		"aucune mise a jour les concernant (laissees en place)"
fi

if [ "$MAJ_DISPONIBLE" = true ]; then
	mettre_a_jour_flatpak
else
	ignorer_etape "Mise a jour des applications Flatpak" \
		"tout est deja a jour"
fi

# Rappel des versions apres mise a jour.
echo
log "Versions apres mise a jour :"
flatpak list --app --columns=application,version 2>/dev/null | sed 's/^/    /'

# Enregistrement des versions avant -> apres pour le bilan Acmechanic.
for entree in "${FLATPAK_SAUVEGARDES[@]}"; do
	nom="${entree%%:*}"
	appid="${entree##*:}"
	ver_apres="$(version_flatpak "$appid" 2>/dev/null || echo "?")"
	enregistrer_version "$nom" "${VER_AVANT[$nom]:-?}" "$ver_apres"
	# Une application a ete mise a jour si sa version a change.
	if [ "${VER_AVANT[$nom]:-?}" != "$ver_apres" ]; then
		NB_MAJ=$((NB_MAJ + 1))
	fi
done

# =====================================================================
# 5. Relance des applications fermees pour la sauvegarde
# =====================================================================
# flatpak.sh a ferme (flatpak kill) les applications declarees qui
# tournaient, afin de copier leur configuration a froid. Sans cette
# etape de relance, elles resteraient eteintes apres Acmechanic.
# On ne relance que celles qu'ON a
# reellement tuees et qui ne tournent pas deja (relance manuelle
# entre-temps, ou redemarrage par un autre script).
relancer_applications() {
	[ ${#TYPES_APPS_TUEES[@]} -gt 0 ] || return 0
	echo
	log "Relance des applications fermees pour la sauvegarde :"
	local entree nom appid i total actif
	for entree in "${TYPES_APPS_TUEES[@]}"; do
		nom="${entree%%|*}"
		appid="${entree##*|}"
		# Deja relancee (par l'utilisateur, ou redemarree entre-temps) ?
		# On teste les deux : une app lancee normalement est vue par
		# `flatpak ps`, une app relancee via setsid (hors session
		# Flatpak) ne l'est pas mais son binaire tourne (pgrep).
		local binaire_deja="${appid##*.}"
		if flatpak ps --columns=application 2>/dev/null | grep -qx "$appid" \
		   || pgrep -x "$binaire_deja" >/dev/null 2>&1; then
			log "  $nom : deja active, rien a faire."
			continue
		fi
		# Nettoyage des fichiers de session residuels d'un lancement
		# avorte (lockfile / ipc-socket) qui empecheraient le demarrage.
		rm -f "$HOME/.var/app/$appid/config/"*"/lockfile" \
		      "$HOME/.var/app/$appid/config/"*"/ipc-socket" 2>/dev/null
		# setsid -f : setsid fork immediatement ; le processus setsid
		# parent meurt tout de suite, laissant l'enfant (flatpak run)
		# deja dans sa propre session. 9>&- ferme le descripteur du
		# verrou de flatpak.sh dans l'enfant (sinon flatpak run
		# herite du flock et peut echouer). </dev/null evite toute
		# attente de saisie sur le terminal.
		setsid -f flatpak run "$appid" >/dev/null 2>&1 </dev/null 9>&- & disown
		# Critere de reussite : le binaire tourne. On n'utilise pas
		# `flatpak ps` car le lancement via setsid sort le process de
		# la session Flatpak, et `flatpak ps` ne le verrait plus — alors
		# que l'application tourne reellement (verifiable via ps).
		# Le montage du runtime Flatpak (bwrap) est lent sur ARM :
		# une application peut mettre 50-90 s a apparaitre (une
		# fenetre de 50 s concluait a tort a un echec alors que
		# l'application demarrait bien). On attend donc
		# jusqu'a ~100 s, en s'arretant des que le binaire est vu.
		local binaire="${appid##*.}"
		actif=false; total=0
		for i in 3 4 4 5 5 6 7 8 8 10 12 15 20; do
			sleep "$i"; total=$((total + i))
			if pgrep -x "$binaire" >/dev/null 2>&1; then
				actif=true; break
			fi
		done
		if [ "$actif" = true ]; then
			ok "$nom relance (apres ~${total}s)"
		else
			# Best-effort : la relance peut echouer si le script tourne
			# hors d'une session graphique (DISPLAY/Wayland/D-Bus
			# absents). Dans ce cas l'application ne demarre pas toute
			# seule ; on le dit explicitement avec la commande a lancer.
			warn "$nom relancee mais non confirmee active apres ${total}s."
			warn "  Si elle ne revient pas, relance-la a la main : flatpak run $appid"
		fi
	done
}

relancer_applications

bilan_service "Bilan de la maintenance Flatpak"
exit $?
