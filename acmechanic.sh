#!/usr/bin/env bash
################################################################################
# ACMECHANIC - Le mecano ACME de votre serveur maison
# Mise a jour globale de la machine, en une seule commande.
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Jean-Philippe Reculeau — voir LICENSE
################################################################################
#
# Enchaine, dans cet ordre :
#   1. maintenance des services (sauvegarde + mise a jour + relance)
#   2. mise a jour du systeme (Nala, ou APT en repli)
#
# DECOUVERTE AUTOMATIQUE DES SERVICES
# Tout script `<nom>/<nom>.sh` place sous services/ est detecte et
# execute automatiquement, sans aucune declaration prealable. Il suffit
# de creer le dossier et le script, et de le rendre executable.
#
# L'ordre d'execution est libre : creer un lien symbolique numerote dans
# ordre.d/ impose une position precise (10-xxx passe
# avant 20-yyy). Les scripts non lies passent ensuite, par ordre
# alphabetique.
#
# Chaque etape est independante : un echec n'interrompt pas la suite.
# Un tableau recapitulatif est affiche a la fin, et le code de sortie
# correspond au nombre d'etapes en echec (0 = tout s'est bien passe).
#
# Usage :
#   ./acmechanic.sh              tout mettre a jour
#   ./acmechanic.sh --services   uniquement les services
#   ./acmechanic.sh --systeme    uniquement le systeme
#   ./acmechanic.sh --liste      afficher ce qui serait fait, sans rien faire
#   ./acmechanic.sh --version    afficher la version
#   ./acmechanic.sh --aide       afficher l'aide

# Pas de `set -e` : chaque etape est independante, un echec est compte
# (run_etape) et n'interrompt pas la suite.
set -uo pipefail

readonly ACMECHANIC_VERSION="1.1.0"
# readlink -f : fonctionne aussi via un lien symbolique (/usr/local/bin/acmechanic)
ACMECHANIC_HOME="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# Exporte : les scripts de service le lisent pour trouver lib/.
export ACMECHANIC_HOME

afficher_aide() {
	cat <<EOF
ACMECHANIC v${ACMECHANIC_VERSION} — le mecano ACME de votre serveur maison

UTILISATION
    acmechanic [OPTION]

OPTIONS
    (aucune)      services puis systeme
    --services    uniquement les services
    --systeme     uniquement le systeme (Nala, ou APT)
    --liste       ce qui serait fait, sans rien faire
    --version     version
    --aide, -h    cette aide

Configuration : ${ACMECHANIC_HOME}/config.sh (defauts), local.conf (surcharges)
EOF
}

case "${1:-}" in
--version) echo "acmechanic ${ACMECHANIC_VERSION}"; exit 0 ;;
--aide | --help | -h) afficher_aide; exit 0 ;;
esac

SERVICE_NAME="acmechanic"
# Le watchdog de common.sh tue le script au-dela de SEUIL_FIGE (1 h par
# defaut, calibre pour UN service). Acmechanic enchaine services (jusqu'a
# DELAI_SERVICE = 3000 s) puis systeme (jusqu'a 600+1800+600 s) : 1 h
# pouvait le tuer en plein `nala upgrade`. 2 h 30 couvre le pire cas.
SEUIL_FIGE="${SEUIL_FIGE:-9000}"
# shellcheck source=lib/common.sh
source "${ACMECHANIC_HOME}/lib/common.sh"
# shellcheck source=config.sh
source "${ACMECHANIC_HOME}/config.sh"
# shellcheck source=lib/tableau.sh
source "${ACMECHANIC_HOME}/lib/tableau.sh"

# Dossiers et delais : voir config.sh (SERVICES_DIR, ORDRE_DIR,
# SERVICES_EXTRA_DIRS, DELAI_SERVICE, DELAI_SYSTEME, EXCLUS).
DOSSIER_ORDRE="$ORDRE_DIR"

# ---------------------------------------------------------------------
# decouvrir_services
#
# Construit la liste ordonnee des scripts de service a executer.
# Ecrit le resultat dans le tableau SERVICES_TROUVES sous la forme
# "origine|nom|chemin".
#
# CRITERE DE RECONNAISSANCE
# Un script est reconnu comme service de maintenance s'il utilise la
# bibliotheque commune (lib/common.sh). C'est la signature du cadre :
# tout script ecrit sur ce modele est detecte automatiquement, et les
# autres scripts presents sur la machine (outils, interfaces
# interactives, anciens utilitaires) sont ignores sans risque.
#
# Deux sources :
#   1. les liens de docker-updates/ (ordre impose par leur prefixe)
#   2. tout script <dossier>/<meme-nom>.sh sous SERVICES_DIR (ou un
#      dossier de SERVICES_EXTRA_DIRS) utilisant lib/common.sh et non deja pris en compte
# ---------------------------------------------------------------------
decouvrir_services() {
	SERVICES_TROUVES=()
	SERVICES_ECARTES=()
	local deja_vus=()

	est_exclu() {
		local nom="$1" e
		for e in "${EXCLUS[@]}"; do
			[ "$nom" = "$e" ] && return 0
		done
		return 1
	}

	deja_pris() {
		local chemin="$1" d
		for d in "${deja_vus[@]}"; do
			[ "$d" = "$chemin" ] && return 0
		done
		return 1
	}

	# Un script de maintenance source la bibliotheque commune.
	utilise_la_bibliotheque() {
		grep -qE '(source|\.)[[:space:]].*lib/(common|service)\.sh' "$1" 2>/dev/null
	}

	# --- 1. Ordre impose par les liens numerotes ---
	if [ -d "$DOSSIER_ORDRE" ]; then
		local lien nom cible
		for lien in "$DOSSIER_ORDRE"/*.sh; do
			[ -e "$lien" ] || continue
			cible="$(readlink -f "$lien")"
			nom="$(basename "$lien" .sh)"
			# On retire le prefixe numerique du nom affiche.
			nom="${nom#[0-9][0-9]-}"
			if [ ! -f "$cible" ]; then
				SERVICES_TROUVES+=("lien|$nom|MANQUANT:$cible")
				continue
			fi
			SERVICES_TROUVES+=("lien|$nom|$cible")
			deja_vus+=("$cible")
		done
	fi

	# --- 2. Decouverte automatique ---
	local candidats=() script nom
	while IFS= read -r script; do
		[ -n "$script" ] && candidats+=("$script")
	done < <(
		for racine in "$SERVICES_DIR" "${SERVICES_EXTRA_DIRS[@]}"; do
			[ -d "$racine" ] || continue
			find -L "$racine" -mindepth 2 -maxdepth 2 -name '*.sh' -type f 2>/dev/null
		done | sort -u
	)

	for script in "${candidats[@]}"; do
		nom="$(basename "$script" .sh)"
		# Le script doit porter le nom de son dossier.
		[ "$(basename "$(dirname "$script")")" = "$nom" ] || continue
		est_exclu "$nom" && continue
		deja_pris "$script" && continue
		# Les bibliotheques ne sont pas des services.
		[ "$(basename "$(dirname "$script")")" = "lib" ] && continue

		if utilise_la_bibliotheque "$script"; then
			SERVICES_TROUVES+=("auto|$nom|$script")
			deja_vus+=("$script")
		else
			# Signale sans executer : c'est peut-etre un service en
			# cours d'ecriture, ou un simple outil sans rapport.
			SERVICES_ECARTES+=("$nom|$script")
		fi
	done
}

faire_services=true
faire_systeme=true

case "${1:-}" in
--services) faire_systeme=false ;;
--systeme) faire_services=false ;;
--liste)
	titre "ETAPES PREVUES PAR ACMECHANIC"
	decouvrir_services
	echo "1. Services detectes :"
	if [ ${#SERVICES_TROUVES[@]} -eq 0 ]; then
		echo "     (aucun)"
	else
		for entree in "${SERVICES_TROUVES[@]}"; do
			IFS='|' read -r origine nom chemin <<<"$entree"
			if [ "$origine" = "lien" ]; then
				marque="ordre impose"
			else
				marque="detecte automatiquement"
			fi
			printf '     %-14s %-26s %s\n' "$nom" "$marque" "$chemin"
		done
	fi
	echo
	if [ ${#SERVICES_ECARTES[@]} -gt 0 ]; then
		echo "Scripts ecartes (ils n'utilisent pas lib/common.sh, donc ce ne"
		echo "sont pas des scripts de maintenance) :"
		for entree in "${SERVICES_ECARTES[@]}"; do
			IFS='|' read -r nom chemin <<<"$entree"
			printf '     %-14s %s\n' "$nom" "$chemin"
		done
		echo
	fi
	echo "2. Systeme : $(command -v nala >/dev/null && echo 'Nala' || echo 'APT')"
	echo
	echo "Pour qu'un nouveau service soit detecte automatiquement :"
	echo "  - le placer dans $SERVICES_DIR/<nom>/<nom>.sh"
	echo "    ou lier un service de la bibliotheque :"
	echo "    ln -s $ACMECHANIC_HOME/bibliotheque/<nom> $SERVICES_DIR/<nom>"
	echo "  - y ecrire :  source \"\${ACMECHANIC_HOME}/lib/service.sh\""
	echo "  - le rendre executable :  chmod +x"
	echo "Pour imposer sa position dans l'ordre d'execution :"
	echo "  ln -s $SERVICES_DIR/<nom>/<nom>.sh $DOSSIER_ORDRE/NN-<nom>.sh"
	echo
	echo "Journal : $LOG_FILE"
	exit 0
	;;
"") ;;
*)
	err "Option inconnue : $1"
	echo "Options : --services, --systeme, --liste, --version, --aide"
	exit 1
	;;
esac

prendre_verrou acmechanic

titre "MISE A JOUR GLOBALE (ACMECHANIC)"
log "Machine : $(hostname)   Utilisateur : $(whoami)"
log "Journal de cette execution : $LOG_FILE"

# --- Fichiers d'echange avec les scripts de service ---
# Versions (avant -> apres) et compteurs partages (INCHANGE / IGNORE /
# statut par service). Supprimes automatiquement a la sortie
# (fichier_temp, lib/common.sh) : ils s'accumulaient dans /tmp.
#
# Ils sont transmis aux FILS uniquement (env, au lancement), jamais
# exportes dans le shell de Acmechanic : sinon les ignorer_etape de Acmechanic
# lui-meme etaient ecrits dans le fichier PUIS relus au bilan, donc
# comptes deux fois.
fichier_temp FICHIER_VERSIONS /tmp/acmechanic-versions-XXXXXX
fichier_temp FICHIER_COMPTEURS /tmp/acmechanic-compteurs-XXXXXX
# Points d'attention (point_attention) : ceux des services ET d'Acmechanic.
fichier_temp FICHIER_ATTENTION /tmp/acmechanic-attention-XXXXXX
ACMECHANIC_ATTENTION_FICHIER="$FICHIER_ATTENTION"
# rapport_versions (lib/common.sh) lit ACMECHANIC_VERSIONS_FICHIER : variable
# locale a Acmechanic, non exportee.
ACMECHANIC_VERSIONS_FICHIER="$FICHIER_VERSIONS"

# Sortie detaillee de chaque service (tableaux, sorties de docker,
# flatpak, nala...). En parallele, ces sorties s'entremelaient a
# l'ecran ; elles vont desormais dans un fichier par service, et seules
# les lignes de progression (prefixees [service]) s'affichent en direct.
DOSSIER_SORTIES="$LOG_DIR/services"
mkdir -p "$DOSSIER_SORTIES"

# --- Verification prealable de sudo ---
# Les mises a jour systeme en ont besoin. Sans sudo utilisable sans mot
# de passe, ces etapes bloqueraient : on les annonce comme ignorees.
if sudo_disponible; then
	SUDO_OK=true
	log "sudo est utilisable sans mot de passe : mises a jour systeme possibles."
else
	SUDO_OK=false
	warn "sudo demande un mot de passe : les mises a jour systeme seront ignorees."
	warn "Lancez d'abord : sudo -v"
fi

# --- Rafraichissement des depots ANTICIPE ---
# `nala update` ne fait que telecharger les listes de paquets : aucun
# conflit possible avec la maintenance des services. On le lance donc
# des maintenant, en arriere-plan, pendant les services (gain mesure :
# 10 a 13 s). La MISE A JOUR des paquets, elle, reste apres les
# services : elle peut redemarrer dockerd.
# Etat de chaque ligne de l'affichage fixe (voir lib/tableau.sh).
# Remis a zero a chaque run.
DOSSIER_ETAT="$LOG_DIR/etat"
mkdir -p "$DOSSIER_ETAT"
rm -f "$DOSSIER_ETAT"/* "$DOSSIER_ETAT"/.dessine

PID_RAFRAICHISSEMENT=""
if [ "$faire_systeme" = true ] && [ "$SUDO_OK" = true ] && command -v nala >/dev/null 2>&1; then
	fichier_temp FICHIER_RAFRAICHISSEMENT /tmp/acmechanic-nala-update-XXXXXX
	echo "Depots : rafraichissement en arriere-plan" >"$DOSSIER_ETAT/systeme"
	(
		timeout 600 sudo -n env DEBIAN_FRONTEND=noninteractive nala update \
			>"$FICHIER_RAFRAICHISSEMENT" 2>&1
		code_maj=$?
		# Message AVANT le code : une fois le code ecrit, la section
		# systeme peut demarrer et ecrire ses propres etapes.
		echo "Depots rafraichis (code $code_maj), en attente des services" >"$DOSSIER_ETAT/systeme"
		echo "CODE=$code_maj" >>"$FICHIER_RAFRAICHISSEMENT"
	) </dev/null 9>&- &
	PID_RAFRAICHISSEMENT=$!
fi

# attendre_rafraichissement : attend la fin du `nala update` anticipe et
# renvoie son code (appele via run_etape, donc dans un sous-shell :
# on ne peut pas `wait` sur le PID, on lit le code dans le fichier).
attendre_rafraichissement() {
	while ! grep -q '^CODE=' "$FICHIER_RAFRAICHISSEMENT" 2>/dev/null; do
		sleep 1
	done
	sed '$d' "$FICHIER_RAFRAICHISSEMENT" >>"$LOG_FILE"
	return "$(sed -n 's/^CODE=//p' "$FICHIER_RAFRAICHISSEMENT" | tail -1)"
}

# =====================================================================
# Affichage fixe
# =====================================================================
# Une ligne par service (+ une pour le systeme), redessinee en place au
# lieu d'empiler les journaux (lib/tableau.sh). Pendant ce temps, la
# sortie de Acmechanic lui-meme et celle de nala vont dans des fichiers de
# $DOSSIER_SORTIES ; les ATTENTION / ERREUR sont reprises au bilan.
# Sortie non-terminal (cron, pipe) ou ACMECHANIC_TABLEAU=non : affichage
# ligne a ligne comme avant.
LIGNES_TABLEAU=()
if [ "$faire_services" = true ]; then
	decouvrir_services
	for entree in "${SERVICES_TROUVES[@]}"; do
		IFS='|' read -r _ nom _ <<<"$entree"
		LIGNES_TABLEAU+=("$nom")
	done
fi
# Du plus rapide au plus lent (durees reelles du run precedent) ; le
# systeme passe toujours en dernier : il attend la fin des services.
FICHIER_DUREES="$LOG_DIR/durees"
if [ ${#LIGNES_TABLEAU[@]} -gt 1 ]; then
	mapfile -t LIGNES_TABLEAU < <(tableau_ordonner "$FICHIER_DUREES" "${LIGNES_TABLEAU[@]}")
fi
[ "$faire_systeme" = true ] && LIGNES_TABLEAU+=(systeme)

TABLEAU=non
SERVICES_EN_ECHEC=()
if [ ${#LIGNES_TABLEAU[@]} -gt 0 ] && tableau_possible "${#LIGNES_TABLEAU[@]}"; then
	TABLEAU=oui
	# Ecran nettoye (sans effacer l'historique de defilement) : le
	# tableau part du haut de la fenetre et peut en occuper toute la
	# hauteur. Le titre et les INFO de depart restent dans le journal.
	printf '\033[H\033[J'
	tableau_demarrer "$DOSSIER_ETAT" "$DOSSIER_SORTIES" "${LIGNES_TABLEAU[@]}"
	exec 5>&1 6>&2 >"$DOSSIER_SORTIES/acmechanic.sortie" 2>&1
	ACMECHANIC_ETAT_FICHIER="$DOSSIER_ETAT/acmechanic"
fi

# recolter_termines : recolte TOUS les services termines a cet instant
# (statut, duree, compteurs). Appelee pendant les lancements ET ensuite
# toutes les 0,5 s : un service fini tot n'attend plus la fin des
# lancements pour etre affiche termine (2026-09-27). Un service termine
# n'existe plus (bash l'a deja recolte) : `wait <pid>` rend son code.
NB_SVC_OK=0 NB_SVC_ECHEC=0 NB_SVC_TIMEOUT=0
recolter_termines() {
	local svc_pid svc_code nom svc_duree svc_statut
	for svc_pid in "${!SVC_NOM[@]}"; do
		kill -0 "$svc_pid" 2>/dev/null && continue
		if wait "$svc_pid"; then
			svc_code=0
		else
			svc_code=$?
		fi
		nom="${SVC_NOM[$svc_pid]}"
		unset 'SVC_NOM[$svc_pid]'
		svc_duree=$((SECONDS - SVC_DEBUT[$svc_pid]))
		svc_restants=$((svc_restants - 1))

		if [ "$svc_code" -eq 124 ] || [ "$svc_code" -eq 137 ]; then
			err "$nom -- delai de ${DELAI_SERVICE}s depasse, etape abandonnee"
			svc_statut="TIMEOUT"
			NB_SVC_TIMEOUT=$((NB_SVC_TIMEOUT + 1))
		else
			svc_statut="$(grep "^SERVICE_$nom=" "$FICHIER_COMPTEURS" 2>/dev/null | cut -d= -f2 | head -1)"
			if [ -z "$svc_statut" ]; then
				if [ "$svc_code" -eq 0 ]; then
					svc_statut="OK"
				else
					svc_statut="ECHEC"
				fi
			fi
			if [ "$svc_code" -eq 0 ]; then
				ok "$nom -- $svc_statut en ${svc_duree}s"
			else
				err "$nom -- echec (code $svc_code) apres ${svc_duree}s"
			fi
		fi
		# En cas d'echec, on montre la fin de la sortie detaillee :
		# c'est la qu'est l'explication.
		# Avec l'affichage fixe, elle est montree apres le tableau.
		echo "$svc_statut|${svc_duree}s" >"$DOSSIER_ETAT/$nom.fin"
		if [ "$svc_code" -ne 0 ]; then
			if [ "$TABLEAU" = oui ]; then
				SERVICES_EN_ECHEC+=("$nom")
			else
				warn "Fin de la sortie de $nom ($DOSSIER_SORTIES/$nom.sortie) :"
				tail -n 20 "$DOSSIER_SORTIES/$nom.sortie" 2>/dev/null | sed 's/^/    /'
			fi
		fi

		_enregistrer "$nom" "$svc_statut" "${svc_duree}s"
		# Comptabilite identique a run_etape : une etape « reussie »
		# = sous-script sorti en 0 (INCHANGE/IGNORE sont totalises
		# separement, plus bas, depuis le fichier de compteurs).
		if [ "$svc_code" -eq 0 ]; then
			NB_OK=$((NB_OK + 1))
			NB_SVC_OK=$((NB_SVC_OK + 1))
		else
			NB_ECHEC=$((NB_ECHEC + 1))
			NB_SVC_ECHEC=$((NB_SVC_ECHEC + 1))
		fi
	done
}

# =====================================================================
# 1. Services
# =====================================================================
if [ "$faire_services" = true ]; then
	echo
	printf '%s### 1. Services ###%s\n' "$C_BOLD$C_BLUE" "$C_OFF"

	if [ ${#SERVICES_TROUVES[@]} -eq 0 ]; then
		ignorer_etape "Services" "aucun script de service detecte"
	else
		log "${#SERVICES_TROUVES[@]} service(s) detecte(s), lancement en parallele."
		log "Sortie detaillee de chaque service : $DOSSIER_SORTIES/<service>.sortie"
		# --- Lancement en parallele ---
		# Chaque service est independant : verrou propre (prendre_verrou),
		# projet compose propre, et ecritures compteurs/versions rendues
		# atomiques par flock (voir _sous_verrou dans lib/common.sh).
		# Le mur total passe donc de la SOMME des durees au MAXIMUM des
		# durees.
		#
		# CORRIGE 2026-09-26 : la boucle de recolte etait imbriquee DANS
		# la boucle de lancement (le `done` du `for` etait place apres le
		# `while`). Chaque service etait donc attendu avant de lancer le
		# suivant : Acmechanic tournait en SEQUENTIEL malgre le commentaire
		# (visible dans le journal : chaque service demarrait a la fin du
		# precedent).
		#
		# On n'utilise pas run_etape ici : lance en arriere-plan, il
		# compterait dans un sous-shell et ses compteurs seraient perdus.
		# La minuterie est donc deleguee a `timeout` et la comptabilite
		# est refaite a la recolte, a l'identique de run_etape.
		declare -A SVC_NOM=() SVC_DEBUT=()
		svc_restants=0
		# Detection du cgroup faite UNE fois ici, dans le shell parent
		# (en arriere-plan, sous_ressources la referait a chaque service).
		preparer_ressources
		# Prechauffage du cache du registre (date + digest de chaque
		# tag), en serie : les services le liront au lieu de bombarder
		# ensemble l'API Docker Hub, qui repondait alors en > 15 s.
		prechauffage_debut=$SECONDS
		mapfile -t IMAGES_CONNUES < <(images_des_projets)
		prechauffer_registre "${IMAGES_CONNUES[@]}"
		log "Cache du registre prechauffe : ${#IMAGES_CONNUES[@]} image(s) en $((SECONDS - prechauffage_debut))s"
		for entree in "${SERVICES_TROUVES[@]}"; do
			IFS='|' read -r origine nom chemin <<<"$entree"

			if [[ "$chemin" == MANQUANT:* ]]; then
				ignorer_etape "$nom" "cible du lien introuvable : ${chemin#MANQUANT:}"
				echo "IGNORE|-" >"$DOSSIER_ETAT/$nom.fin"
				continue
			fi
			if [ ! -x "$chemin" ]; then
				ignorer_etape "$nom" "script non executable (chmod +x $chemin)"
				echo "IGNORE|-" >"$DOSSIER_ETAT/$nom.fin"
				continue
			fi

			[ "$origine" = "auto" ] && log "Service detecte automatiquement : $nom"
			step "$nom : lancement"
			# </dev/null : aucune saisie possible. 9>&- : le verrou de
			# Acmechanic (fd 9) n'est pas herite par le fils (meme convention
			# que run_etape).
			# sous_ressources : chaque service tourne dans un cgroup
			# borne (CPU/RAM/IO) et en priorite basse. Avec une dizaine de services
			# en parallele sur une petite machine, c'est ce qui
			# garantit que la maintenance ne fige jamais le bureau.
			# Ordre important : sous_ressources est une FONCTION bash,
			# `timeout` (binaire externe) ne saurait pas l'executer.
			# C'est donc le scope qui englobe timeout, qui englobe le
			# script : la minuterie tue le script a l'interieur du cgroup.
			echo "$EPOCHSECONDS" >"$DOSSIER_ETAT/$nom.debut"
			etat_service=""
			[ "$TABLEAU" = oui ] && etat_service="$DOSSIER_ETAT/$nom"
			sous_ressources env \
				ACMECHANIC_ETAT_FICHIER="$etat_service" \
				RAPPORT_COMPACT="$([ "$TABLEAU" = oui ] && echo oui)" \
				ACMECHANIC_VERSIONS_FICHIER="$FICHIER_VERSIONS" \
				ACMECHANIC_COMPTEURS_FICHIER="$FICHIER_COMPTEURS" \
				ACMECHANIC_ATTENTION_FICHIER="$FICHIER_ATTENTION" \
				ACMECHANIC_PARALLELE=1 \
				timeout "$DELAI_SERVICE" bash "$chemin" \
				</dev/null >"$DOSSIER_SORTIES/$nom.sortie" 2>&1 9>&- &
			SVC_NOM[$!]="$nom"
			SVC_DEBUT[$!]="$SECONDS"
			svc_restants=$((svc_restants + 1))
			# Petit decalage entre lancements : sans lui, les services
			# interrogent l'API du registre dans la meme seconde et
			# celle-ci ralentit (reponses > 15 s = garde-fou declenche =
			# pull inutile).
			sleep 1
			recolter_termines
		done

		# --- Recolte ---
		# Scrutation toutes les 0,5 s plutot que `wait -n` (2026-09-27) :
		# bloque dans `wait -n`, Acmechanic ne traitait un Ctrl+C qu'a la fin
		# du service suivant (25 s mesurees). Ici le trap passe en
		# moins d'une demi-seconde. Un service termine n'existe plus
		# (bash l'a deja recolte) : `wait <pid>` rend alors son code.
		# Le statut REEL (MAJ / INCHANGE / ECHEC) est lu dans le fichier
		# de compteurs, ecrit par le sous-script.
		while [ "$svc_restants" -gt 0 ]; do
			recolter_termines
			[ "$svc_restants" -gt 0 ] && sleep 0.5
		done
	fi
fi

# =====================================================================
# 2. Systeme
# =====================================================================
if [ "$faire_systeme" = true ]; then
	echo "$EPOCHSECONDS" >"$DOSSIER_ETAT/systeme.debut"
	debut_systeme=$SECONDS
	echecs_avant_systeme=$NB_ECHEC
	if [ "$TABLEAU" = oui ]; then
		# Sortie de nala (tableaux, telechargements) vers son fichier ;
		# les etapes s'affichent sur la ligne « systeme ».
		exec >"$DOSSIER_SORTIES/systeme.sortie" 2>&1
		ACMECHANIC_ETAT_FICHIER="$DOSSIER_ETAT/systeme"
	fi
	echo
	printf '%s### 2. Mise a jour du systeme ###%s\n' "$C_BOLD$C_BLUE" "$C_OFF"

	if [ "$SUDO_OK" != true ]; then
		ignorer_etape "Mise a jour du systeme" "sudo indisponible sans mot de passe"
	elif command -v nala >/dev/null 2>&1; then
		# DEBIAN_FRONTEND=noninteractive : aucune question posee pendant
		# l'installation, indispensable sans surveillance.
		if [ -n "$PID_RAFRAICHISSEMENT" ]; then
			run_etape "Nala : rafraichissement des depots (anticipe)" 600 \
				attendre_rafraichissement
		else
			run_etape "Nala : rafraichissement des depots" 600 \
				sudo -n env DEBIAN_FRONTEND=noninteractive nala update
		fi
		run_etape "Nala : mise a jour des paquets" "$DELAI_SYSTEME" \
			sudo -n env DEBIAN_FRONTEND=noninteractive nala upgrade -y
		run_etape "Nala : suppression des paquets inutiles" 600 \
			sudo -n env DEBIAN_FRONTEND=noninteractive nala autoremove -y
	elif command -v apt-get >/dev/null 2>&1; then
		run_etape "APT : rafraichissement des depots" 600 \
			sudo -n env DEBIAN_FRONTEND=noninteractive apt-get update
		run_etape "APT : mise a jour des paquets" "$DELAI_SYSTEME" \
			sudo -n env DEBIAN_FRONTEND=noninteractive apt-get -y full-upgrade
		run_etape "APT : suppression des paquets inutiles" 600 \
			sudo -n env DEBIAN_FRONTEND=noninteractive apt-get -y autoremove
	else
		ignorer_etape "Mise a jour du systeme" "ni Nala ni APT trouve"
	fi

	# Signale un redemarrage necessaire, sans jamais le declencher.
	if [ -f /var/run/reboot-required ]; then
		paquets="$(tr '\n' ' ' </var/run/reboot-required.pkgs 2>/dev/null)"
		point_attention "$(t att_redemarrage "${paquets:-?}")" "sudo reboot"
	fi
	if [ "$NB_ECHEC" -gt "$echecs_avant_systeme" ]; then
		statut_systeme=ECHEC
	elif [ "$SUDO_OK" != true ]; then
		statut_systeme=IGNORE
	else
		statut_systeme=OK
	fi
	echo "$statut_systeme|$((SECONDS - debut_systeme))s" >"$DOSSIER_ETAT/systeme.fin"
fi

# ---------------------------------------------------------------------
# auto_mise_a_jour : Acmechanic se met a jour lui-meme, EN FIN de run
# (jamais pendant : les services en cours liraient un melange de deux
# versions de lib/). Avance rapide seulement, arbre propre seulement ;
# la nouvelle version sert au prochain lancement. Ce qui n'est pas
# applique devient un point d'attention.
# ACMECHANIC_AUTO_MAJ : oui (defaut) | signaler | non
# ---------------------------------------------------------------------
auto_mise_a_jour() {
	local mode="${ACMECHANIC_AUTO_MAJ:-oui}" d="$ACMECHANIC_HOME" n avant raison=""
	[ "$mode" = non ] && return 0
	git -C "$d" rev-parse -q --verify '@{u}' >/dev/null 2>&1 || return 0
	if ! timeout 60 git -C "$d" fetch -q 2>/dev/null; then
		warn "Acmechanic : depot distant injoignable, auto-mise a jour sautee."
		return 0
	fi
	n="$(git -C "$d" rev-list --count 'HEAD..@{u}' 2>/dev/null || echo 0)"
	[ "$n" -eq 0 ] && return 0
	avant="$(git -C "$d" rev-parse --short HEAD)"
	if [ "$mode" != oui ]; then
		raison="$(t raison_signaler)"
	elif [ -n "$(git -C "$d" status --porcelain --untracked-files=no)" ]; then
		raison="$(t raison_modifs)"
	elif git -C "$d" merge -q --ff-only '@{u}' 2>/dev/null; then
		ok "Acmechanic mis a jour ($avant -> $(git -C "$d" rev-parse --short HEAD), $n commit(s)) : actif au prochain lancement."
		enregistrer_version acmechanic "$avant" "$(git -C "$d" rev-parse --short HEAD)"
		return 0
	else
		raison="$(t raison_divergent)"
	fi
	point_attention "$(t att_auto_maj "$n" "$raison")" "git -C $d pull --ff-only"
}

# Fin de l'affichage fixe : dernier dessin, retour a l'ecran normal.
if [ "$TABLEAU" = oui ]; then
	tableau_arreter
	exec 1>&5 2>&6 5>&- 6>&-
	ACMECHANIC_ETAT_FICHIER=""
	RAPPORT_COMPACT=oui
fi
# Durees reelles de ce run : ordre des cadres au prochain lancement.
TABLEAU_DOSSIER="$DOSSIER_ETAT" tableau_memoriser_durees "$FICHIER_DUREES"

auto_mise_a_jour

# =====================================================================
# Bilan
# =====================================================================
# Totaux des sous-scripts (ils ecrivent dans le fichier de compteurs,
# qu'Acmechanic seul ne voit pas : il ne lit que leur code de retour).
compteur() { grep "^$1=" "$FICHIER_COMPTEURS" 2>/dev/null | cut -d= -f2 | head -1; }
c_inch="$(compteur INCHANGE)" c_ign="$(compteur IGNORE)"
c_ok="$(compteur ETAPES_OK)" c_ech="$(compteur ETAPES_ECHEC)"
NB_INCHANGE=$((NB_INCHANGE + ${c_inch:-0}))
NB_IGNORE=$((NB_IGNORE + ${c_ign:-0}))
# Etapes de tous les services + etapes systeme d'Acmechanic lui-meme ;
# un service coupe par son delai compte pour une etape en echec.
ETAPES_OK=$((${c_ok:-0} + NB_OK - NB_SVC_OK))
ETAPES_ECHEC=$((${c_ech:-0} + NB_ECHEC - NB_SVC_ECHEC + NB_SVC_TIMEOUT))

rapport_final "Bilan de la mise a jour globale"
code=$?

if [ "$TABLEAU" = oui ]; then
	# Points d'attention, erreurs, fin de sortie des services en echec.
	rapport_attention "$FICHIER_ATTENTION"
	erreurs="$(tableau_erreurs)"
	if [ -n "$erreurs" ]; then
		echo
		printf ' %s%s %s%s\n' "$_T_GRAS$_T_ROUGE" "${_ICONE_STATUT[ERREUR]}" "${MSG[titre_erreurs]}" "$_T_RAZ"
		printf '%s\n' "$erreurs"
	fi
	for nom in "${SERVICES_EN_ECHEC[@]}"; do
		echo
		warn "Fin de la sortie de $nom ($DOSSIER_SORTIES/$nom.sortie) :"
		tail -n 20 "$DOSSIER_SORTIES/$nom.sortie" 2>/dev/null | tr -d '\037' | sed 's/^/    /'
	done
	tableau_bilan "$ETAPES_OK" "$NB_IGNORE" "$ETAPES_ECHEC"
	printf ' %s%s %s%s\n' "$_T_TERNE" "${_ICONE_STATUT[DOSSIER]}" "$(t sorties "$DOSSIER_SORTIES/")" "$_T_RAZ"
	printf ' %s%s %s%s\n' "$_T_TERNE" "${_ICONE_STATUT[DOSSIER]}" "$(t journal "$LOG_FILE")" "$_T_RAZ"
	tableau_versions "$FICHIER_VERSIONS"
	tableau_fin "$code"
	# Memes informations dans le journal que l'affichage classique.
	{
		printf '[%(%Y-%m-%d %H:%M:%S)T] %-7s %s\n' -1 INFO "Fin de Acmechanic : $code etape(s) en echec"
		printf '[%(%Y-%m-%d %H:%M:%S)T] %-7s %s\n' -1 INFO "Espace disque : $(df -h "$HOME" | awk 'NR==2 {print $4" libres ("$5" utilises)"}')"
	} >>"$LOG_FILE"
	exit "$code"
fi
rapport_versions
rapport_attention "$FICHIER_ATTENTION"

echo
if [ "$code" -eq 0 ]; then
	ok "Tout s'est bien passe."
else
	err "$code etape(s) en echec. Details ci-dessus et dans $LOG_FILE"
	err "Pour restaurer un service a partir d'une sauvegarde : $ACMECHANIC_HOME/restore.sh"
fi

# Rappel d'occupation disque : les sauvegardes s'accumulent.
libre="$(df -h "$HOME" | awk 'NR==2 {print $4}')"
usage="$(df -h "$HOME" | awk 'NR==2 {print $5}')"
log "Espace disque restant : $libre libre ($usage utilise)"
log "Sauvegardes : $(du -sh "$BACKUP_ROOT" 2>/dev/null | cut -f1) dans $BACKUP_ROOT"

exit "$code"
