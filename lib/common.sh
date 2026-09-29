#!/bin/bash
# common.sh - Socle partage par tous les scripts de maintenance.
# Usage : source "${ACMECHANIC_HOME}/lib/common.sh"
#
# Fournit : couleurs, journalisation, verrou anti-concurrence,
# verification de dependances, execution d'etape avec timeout et statut.

# --- Garde-fou : ne pas sourcer deux fois ---
[ -n "${_COMMON_SH_LOADED:-}" ] && return 0
_COMMON_SH_LOADED=1

set -o pipefail

# Textes affiches dans la langue de l'utilisateur (t, tv : lib/i18n.sh).
# shellcheck source=i18n.sh
source "$(dirname "${BASH_SOURCE[0]}")/i18n.sh"

# --- Arret propre sur interruption (Ctrl+C) et fige ---
# Installe un trap INT/TERM et un watchdog. Le trap tue recursivement
# tous les descendants du script (sous-shells run_etape, docker compose,
# minuteries) sans jamais toucher au shell parent ni aux autres processus,
# puis libere le verrou et quitte. Le watchdog tue le script s'il depasse
# SEUIL_FIGE secondes (filet de securite contre un fige total).



# _maintenance_tuer_arbre <pid> : arrete (TERM) tous les DESCENDANTS du
# processus, du plus profond au plus proche, sans toucher au processus
# lui-meme. RESTAUREE 2026-09-27 : la fonction etait appelee mais n'etait
# plus definie (perdue avant le 2026-09-03) : sur Ctrl+C, Acmechanic quittait
# en laissant les services continuer en arriere-plan (constate : un service
# finissait sa mise a jour apres l'interruption).
_maintenance_tuer_arbre() {
	local enfant
	for enfant in $(pgrep -P "$1" 2>/dev/null); do
		_maintenance_tuer_arbre "$enfant"
		kill -TERM "$enfant" 2>/dev/null
	done
}

_maintenance_interrompre() {
	trap - INT TERM HUP   # desarme pour eviter la recursion du signal
	# Affichage fixe de Acmechanic actif : on le fige et on rend le curseur
	# AVANT d'ecrire, puis les messages repartent vers l'ecran.
	declare -F tableau_arreter >/dev/null && tableau_arreter
	ACMECHANIC_ETAT_FICHIER=""

	warn "Interruption (Ctrl+C ou terminal ferme). Arret des operations en cours..."
	_maintenance_tuer_arbre "$$"
	# Libere le verrou anti-concurrence (ferme le descripteur 9).
	exec 9>&- 2>/dev/null
	warn "Arret termine. Relancez le script pour finir : docker compose est idempotent."
	exit 130
}

# Filet de securite contre un fige total. Doit rester SUPERIEUR au pire
# cumul d'un service : pull 1200 + arret 120 + sauvegarde 600 +
# redemarrage 180 + verification 90 + nettoyage 300 = ~2490 s.
SEUIL_FIGE="${SEUIL_FIGE:-3600}"   # 1 h

# Delai accorde a un `compose pull`. 120 s etait irrealiste : une image
# de ~1,5 Go a demande pres de 15 min sur un Raspberry Pi,
# et l'ancien delai coupait le pull a mi-parcours (etape ECHEC, image
# partielle, service laisse tel quel). Un pull qui progresse ne coute
# rien a attendre ; une panne reseau fait echouer docker tout seul.
DELAI_PULL="${DELAI_PULL:-1200}"   # 20 min

# --- Limitation des ressources (CPU / RAM / IO) ---
# Sur une petite machine (peu de RAM, swap compresse), quand la memoire
# sature, kswapd tourne en boucle et TOUT se fige.
# La maintenance ne doit jamais pouvoir provoquer ca : chaque service
# tourne donc dans un cgroup borne (scope systemd utilisateur, si les
# controleurs cpu/memory/pids sont delegues), avec en
# plus une priorite CPU et IO basse pour laisser le bureau reactif.
#
# Reglable par variable d'environnement (ex. LIMITE_CPU=100% acmechanic.sh).
# LIMITES_RESSOURCES=non desactive tout (retour au comportement brut).
LIMITE_CPU="${LIMITE_CPU:-200%}"        # 2 coeurs sur 4
LIMITE_RAM_SOUPLE="${LIMITE_RAM_SOUPLE:-1G}"   # au-dela : recuperation
LIMITE_RAM_DURE="${LIMITE_RAM_DURE:-2G}"       # au-dela : OOM du scope
LIMITES_RESSOURCES="${LIMITES_RESSOURCES:-oui}"

# Detection UNE SEULE FOIS : un scope utilisateur est-il creable ?
# (sinon repli sur nice/ionice seuls, sans jamais relancer la commande
# deux fois : une double execution serait pire que l'absence de limite).
_scope_utilisable() {
	[ "$LIMITES_RESSOURCES" = oui ] || return 1
	command -v systemd-run >/dev/null 2>&1 || return 1
	systemd-run --user --scope --quiet --collect \
		-p CPUQuota=100% -p MemoryMax=64M /bin/true >/dev/null 2>&1
}
# Detection PARESSEUSE : seul Acmechanic appelle sous_ressources,
# mais la detection (creation d'un scope systemd de test) etait faite a
# CHAQUE chargement de common.sh, soit une fois par service. Elle est
# desormais faite au premier appel seulement.
_SCOPE_DISPO=""

# A appeler dans le shell PARENT avant de lancer des sous_ressources en
# arriere-plan (`&` = sous-shell : le resultat n'y serait pas memorise).
preparer_ressources() {
	[ -n "$_SCOPE_DISPO" ] && return 0
	if _scope_utilisable; then _SCOPE_DISPO=oui; else _SCOPE_DISPO=non; fi
}

# sous_ressources <commande...> : execute la commande sous plafonds.
sous_ressources() {
	local prio=(nice -n 10)
	command -v ionice >/dev/null 2>&1 && prio+=(ionice -c2 -n7)
	preparer_ressources
	if [ "$_SCOPE_DISPO" = oui ]; then
		systemd-run --user --scope --quiet --collect \
			-p CPUQuota="$LIMITE_CPU" -p CPUWeight=10 -p IOWeight=10 \
			-p MemoryHigh="$LIMITE_RAM_SOUPLE" -p MemoryMax="$LIMITE_RAM_DURE" \
			"${prio[@]}" "$@"
	else
		"${prio[@]}" "$@"
	fi
}

_maintenance_watchdog() {
	# $SECONDS est herite du parent et continue de compter : plus besoin
	# de lancer `date` toutes les 10 s (un fork de moins par iteration).
	local debut="$SECONDS"
	while true; do
		sleep 10
		# Le script parent est-il toujours en vie ? Sinon on s'arrete
		# (evite un processus orphelin qui tourne indefiniment).
		kill -0 "$$" 2>/dev/null || exit 0
		if [ $((SECONDS - debut)) -gt "$SEUIL_FIGE" ]; then
			# On ne peut pas appeler les fonctions du script parent (ce
			# watchdog tourne dans un sous-shell qui ne les herite pas).
			# On signale le script parent : son trap INT/TERM declenche
			# l'arret propre (_maintenance_interrompre).
			# Sortie standard fermee (voir lancement) : message vers le
			# terminal s'il existe.
			{ echo "Watchdog : script en cours depuis plus de $SEUIL_FIGE s, considere fige." >/dev/tty; } 2>/dev/null
			kill -TERM "$$" 2>/dev/null
			exit 0
		fi
	done
}

# Installe les protections uniquement quand common.sh est charge par un
# vrai script de maintenance (son nom se termine par .sh). Si l'utilisateur
# sourcait common.sh dans son terminal interactif ($0 = bash), on ne
# touche pas a son Ctrl+C. La detection par $- (flag interactif) est
# ignoree ici car certains contextes d'execution (pty) la posent a tort.
if [[ "$0" == *.sh ]]; then
	# Reset prealable : ecrase un eventuel heritage « ignore » de SIGINT
	# (certains contextes d'execution lancent les scripts en arriere-plan
	# et heritent SIGINT desactive). Sans cela le trap ci-dessous ne
	# s'activerait pas.
	trap - INT TERM HUP
	# HUP ajoute 2026-09-27 : fenetre de terminal fermee pendant Acmechanic.
	# Sans lui, Acmechanic mourait seul et les services continuaient orphelins
	# (constate : un service poursuivait sa mise a jour, et l'Acmechanic
	# suivant echouait sur son verrou).
	trap '_maintenance_interrompre' INT TERM HUP
	_DEBUT_SCRIPT="$(date +%s)"
	# 9>&- : le watchdog ne doit pas retenir le verrou. >/dev/null :
	# il ne doit pas retenir la sortie standard (sinon `acmechanic.sh --liste
	# | less` attendait jusqu'a 10 s apres la fin du script).
	_maintenance_watchdog 9>&- >/dev/null 2>&1 &
	_WATCHDOG_PID=$!
	# A la sortie (normale ou non) : arret immediat du watchdog et
	# suppression des fichiers temporaires declares via fichier_temp.
	_FICHIERS_TEMP=()
	_maintenance_sortie() {
		[ -n "${_WATCHDOG_PID:-}" ] && kill "$_WATCHDOG_PID" 2>/dev/null
		# Curseur toujours rendu, meme sur sortie imprevue.
		declare -F tableau_arreter >/dev/null && tableau_arreter
		[ ${#_FICHIERS_TEMP[@]} -gt 0 ] && rm -f "${_FICHIERS_TEMP[@]}" 2>/dev/null
		# Fichier de versions d'un script lance hors Acmechanic (voir
		# versions_fichier) : il s'accumulait dans /tmp.
		[ -z "${ACMECHANIC_VERSIONS_FICHIER:-}" ] &&
			rm -f "/tmp/acmechanic-versions-$$.txt" "/tmp/acmechanic-versions-$$.txt.lock" 2>/dev/null
		return 0
	}
	trap '_maintenance_sortie' EXIT
fi

# fichier_temp <var> [modele] : cree un fichier temporaire, le range
# dans <var> et le fait supprimer automatiquement a la sortie. Ne pas
# l'appeler dans $(...) : le sous-shell perdrait l'enregistrement.
fichier_temp() {
	local __var="$1" __f
	__f="$(mktemp "${2:-/tmp/maintenance-XXXXXX}")" || return 1
	_FICHIERS_TEMP+=("$__f" "$__f.lock")
	printf -v "$__var" '%s' "$__f"
}


# --- Couleurs (desactivees si la sortie n'est pas un terminal) ---
if [ -t 1 ]; then
	C_RED=$'\033[0;31m'
	C_GREEN=$'\033[0;32m'
	C_YELLOW=$'\033[1;33m'
	C_BLUE=$'\033[0;34m'
	C_CYAN=$'\033[0;36m'
	C_BOLD=$'\033[1m'
	C_OFF=$'\033[0m'
else
	C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_CYAN='' C_BOLD='' C_OFF=''
fi

# --- Nom du service courant, utilise pour les logs et les verrous ---
SERVICE_NAME="${SERVICE_NAME:-$(basename "${0%.sh}")}"
LOG_DIR="${LOG_DIR:-$HOME/logs/$SERVICE_NAME}"
LOG_FILE="${LOG_FILE:-$LOG_DIR/$SERVICE_NAME.log}"
mkdir -p "$LOG_DIR"

# --- Journalisation ---
# Le texte colore va au terminal (ou /dev/tty si la sortie est redirigee),
# le fichier de log recoit du texte brut.
_log_raw() {
    local prefix="$1" color="$2" msg="$3"
    local stamp tty_msg="$msg"
    # printf %()T est interne a bash : pas de fork de `date` par ligne.
    printf -v stamp '%(%Y-%m-%d %H:%M:%S)T' -1
    # Sous Acmechanic, les services tournent en parallele : leurs lignes se
    # melangent a l'ecran. On prefixe donc par le nom du service.
    [ -n "${ACMECHANIC_PARALLELE:-}" ] && tty_msg="[$SERVICE_NAME] $msg"
    if [ -n "${ACMECHANIC_ETAT_FICHIER:-}" ]; then
        # Affichage fixe de Acmechanic (lib/tableau.sh) : au lieu d'ecrire a
        # l'ecran, on remplace la « derniere action » de la ligne du
        # tableau ; les ATTENTION / ERREUR sont gardees pour le bilan.
        # Un intitule de liste (« Versions apres mise a jour : ») n'est
        # pas une action : on garde l'action precedente.
        case "$msg" in
        *:) ;;
        *) printf '%s\n' "$msg" >"$ACMECHANIC_ETAT_FICHIER" 2>/dev/null ;;
        esac
        case "$prefix" in
        ATTENTION | ERREUR) printf '%s %s\n' "$prefix" "$msg" >>"$ACMECHANIC_ETAT_FICHIER.alertes" 2>/dev/null ;;
        esac
        # Et dans la sortie standard (= <service>.sortie) : le detail
        # affiche dans le cadre du service melange ainsi, dans l'ordre,
        # les etapes et la sortie des commandes. Le niveau est encadre de
        # separateurs \x1f (invisibles) : le tableau en tire couleur et
        # icone, comme a l'ecran. Pas d'horodatage : le journal l'a.
        printf '\x1f%s\x1f%s\n' "$prefix" "$msg"
    # Ecrire au terminal meme si la sortie standard est redirigee
    elif [ -t 1 ]; then
        printf '%s%-9s %s%s\n' "$color" "$prefix" "$tty_msg" "$C_OFF"
    else
        # La sortie est redirigee, essayer d'ecrire a /dev/tty
        # Silencieusement : si /dev/tty n'est pas disponible, seul le fichier de log est ecrit
        { printf '%s%-9s %s%s\n' "$color" "$prefix" "$tty_msg" "$C_OFF" > /dev/tty; } 2>/dev/null || true
    fi
    printf '%s %-7s %s\n' "[$stamp]" "$prefix" "$msg" >>"$LOG_FILE"
}

log()  { _log_raw "INFO"   "$C_OFF"    "$1"; }
ok()   { _log_raw "OK"     "$C_GREEN"  "$1"; }
warn() { _log_raw "ATTENTION" "$C_YELLOW" "$1"; }
err()  { _log_raw "ERREUR" "$C_RED"    "$1"; }
step() { _log_raw "ETAPE"  "$C_BLUE"   "$1"; }
# Titre encadre, pour le debut d'un script.
titre() {
	local t="$1"
	printf '%s%s%s\n' "$C_BOLD$C_BLUE" "=============================================" "$C_OFF"
	printf '%s  %s%s\n' "$C_BOLD$C_BLUE" "$t" "$C_OFF"
	printf '%s%s%s\n' "$C_BOLD$C_BLUE" "=============================================" "$C_OFF"
	printf '[%s] ===== %s =====\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$t" >>"$LOG_FILE"
}

# --- Verrou : empeche deux executions simultanees du meme script ---
# Le descripteur 9 reste ouvert tant que le script tourne ; le noyau
# libere le verrou automatiquement a la sortie, meme en cas de kill -9.
#
# Important : les sous-processus heritent des descripteurs ouverts. Les
# etapes lancees par run_etape ferment donc explicitement le descripteur 9
# (voir 9>&- plus bas), sinon un processus enfant survivant continuerait
# de retenir le verrou apres la fin du script.
prendre_verrou() {
	local nom="${1:-$SERVICE_NAME}"
	local fichier="/tmp/maintenance-$nom.lock"
	exec 9>"$fichier" || return 0
	if ! flock -n 9; then
		local detenteur
		detenteur="$(fuser "$fichier" 2>/dev/null | tr -s ' ')"
		err "Une autre execution de $nom est deja en cours."
		err "Verrou : $fichier${detenteur:+ (processus :$detenteur)}"
		err "Attendez la fin de l'execution en cours, ou supprimez le verrou"
		err "si vous etes certain qu'aucune maintenance ne tourne."
		exit 1
	fi
	VERROU_ACTIF="$fichier"
}

# --- Verification de dependances ---
# Renvoie 1 si une commande manque, sans tuer le script : c'est a
# l'appelant de decider si l'absence est fatale ou non.
verifier_commandes() {
	local manquantes=()
	local cmd
	for cmd in "$@"; do
		command -v "$cmd" >/dev/null 2>&1 || manquantes+=("$cmd")
	done
	if [ ${#manquantes[@]} -gt 0 ]; then
		err "Commandes introuvables : ${manquantes[*]}"
		return 1
	fi
	return 0
}

# Verifie que sudo passe sans mot de passe. Indispensable : un sudo
# interactif dans un script non surveille bloque indefiniment.
sudo_disponible() {
	sudo -n true 2>/dev/null
}

# --- Compteurs de resultat, lus par le rapport final ---
NB_OK=0
NB_ECHEC=0
NB_IGNORE=0
NB_INCHANGE=0
NB_MAJ=0
declare -a RESULTATS=()

# --- Compteurs partages avec l'orchestrateur (Acmechanic) ---
# Acmechanic cree un fichier et l'exporte via ACMECHANIC_COMPTEURS_FICHIER. Les
# sous-scripts y totalisent leurs INCHANGE/IGNORE/statut pour que le
# bilan global de Acmechanic les reflete (sinon Acmechanic ne voit que le code de retour).
compteurs_fichier() {
	local f="${ACMECHANIC_COMPTEURS_FICHIER:-}"
	[ -n "$f" ] && echo "$f"
}

# Ecrit/remplace une cle=<valeur> dans le fichier de compteurs partage.
# Base commune a incrementer_compteur et maj_statut_service (DRY).
_sous_verrou() {
	# _sous_verrou <fichier> <commande...> : execute la commande en
	# tenant un flock exclusif sur <fichier>.lock. Acmechanic lance desormais
	# les services en parallele : sans verrou, deux scripts qui
	# reecrivent le meme fichier de compteurs/versions se marchent
	# dessus (lecture->ecriture non atomique = increments perdus).
	local fichier="$1"
	shift
	local verrou="$fichier.lock"
	(
		flock -x 9 2>/dev/null || return 1
		"$@"
	) 9>"$verrou"
}

# Ecrit une cle=valeur dans un fichier sous verrou.
ecrire_compteur() {
    local cle="$1" valeur="$2" f
    f="$(compteurs_fichier)"
    [ -z "$f" ] && return 0
    # Creer le fichier s'il n'existe pas
    touch "$f" 2>/dev/null || return 0
    _sous_verrou "$f" sh -c '
        touch "$3" 2>/dev/null || true
        sed -i "s/^$1=.*/$1=$2/" "$3" 2>/dev/null || true
        grep -q "^$1=" "$3" 2>/dev/null || printf "%s=%s\n" "$1" "$2" >> "$3" 2>/dev/null || true
    ' sh "$cle" "$valeur" "$f" || return 0
}
# Incremente un compteur de statut (INCHANGE, IGNORE, ...).
incrementer_compteur() {
    local statut="$1" f
    f="$(compteurs_fichier)"
    [ -z "$f" ] && return 0
    # Creer le fichier s'il n'existe pas
    touch "$f" 2>/dev/null || return 0
    # Lecture + ecriture dans le meme verrou : deux services en
    # parallele increments ne perdent plus d'increment.
    # CORRIGE 2026-09-26 : le script interne lisait le fichier dans $3
    # alors que seuls 2 arguments sont passes ($1=statut, $2=fichier).
    # Resultat : aucun INCHANGE/IGNORE n'etait jamais compte (« sh:
    # cannot create : Directory nonexistent » en silence) et le bilan de
    # Acmechanic affichait toujours « Inchangees : 0 ».
    _sous_verrou "$f" sh -c '
        current=$(grep "^$1=" "$2" 2>/dev/null | cut -d= -f2)
        [ -z "$current" ] && current=0
        new=$((current + 1))
        if grep -q "^$1=" "$2" 2>/dev/null; then
            sed -i "s/^$1=.*/$1=$new/" "$2"
        else
            printf "%s=%s\n" "$1" "$new" >> "$2"
        fi
    ' sh "$statut" "$f" 2>/dev/null || return 0
}


# ajouter_compteur <cle> <quantite> : ajoute une quantite a un compteur
# partage (sous verrou). Sert au total des etapes de tous les services.
ajouter_compteur() {
	local cle="$1" n="$2" f
	f="$(compteurs_fichier)"
	[ -z "$f" ] || [ "${n:-0}" -eq 0 ] && return 0
	touch "$f" 2>/dev/null || return 0
	_sous_verrou "$f" sh -c '
		v=$(grep "^$1=" "$3" 2>/dev/null | cut -d= -f2)
		v=$(( ${v:-0} + $2 ))
		if grep -q "^$1=" "$3"; then sed -i "s/^$1=.*/$1=$v/" "$3"
		else printf "%s=%s\n" "$1" "$v" >> "$3"; fi
	' sh "$cle" "$n" "$f" 2>/dev/null || return 0
}

# --- Points d'attention ---
# point_attention <message> [commande] : une action A FAIRE PAR
# L'UTILISATEUR (mise a jour a appliquer a la main, redemarrage...), a
# distinguer d'un simple avertissement de deroulement (warn). Journalise
# comme un warn, et repris a la fin :
#   - sous Acmechanic : dans le bloc « Points d'attention » du bilan
#     global (fichier partage ACMECHANIC_ATTENTION_FICHIER) ;
#   - script lance seul : a la fin de son bilan (bilan_service).
declare -a _ATTENTION_LOCALE=()
point_attention() {
	local msg="$1" cmd="${2:-}" f="${ACMECHANIC_ATTENTION_FICHIER:-}"
	warn "$msg${cmd:+ -> $cmd}"
	msg="${msg//|/ }" cmd="${cmd//|/ }"
	_ATTENTION_LOCALE+=("$SERVICE_NAME|$msg|$cmd")
	[ -n "$f" ] || return 0
	_sous_verrou "$f" sh -c 'printf "%s|%s|%s\n" "$1" "$2" "$3" >>"$4"' \
		sh "$SERVICE_NAME" "$msg" "$cmd" "$f" 2>/dev/null || true
}

# rapport_attention [fichier] : affiche les points d'attention, groupes
# par service (ceux du fichier partage, sinon ceux du script courant).
rapport_attention() {
	local f="${1:-}" nom msg cmd icone="!" fleche="->" gras="$C_BOLD" jaune="$C_YELLOW" terne="" raz="$C_OFF"
	local -a lignes=()
	if [ -n "$f" ]; then
		[ -s "$f" ] && mapfile -t lignes <"$f"
	else
		lignes=("${_ATTENTION_LOCALE[@]}")
	fi
	[ ${#lignes[@]} -gt 0 ] || return 0
	if declare -p _ICONE_STATUT >/dev/null 2>&1; then
		icone="${_ICONE_STATUT[ATTENTION]}" fleche="${_ICONE_STATUT[FLECHE]}" terne="$_T_TERNE"
	fi
	echo
	printf ' %s%s%s %s%s\n' "$gras" "$jaune" "$icone" "$(t titre_attention)" "$raz"
	for ligne in "${lignes[@]}"; do
		IFS='|' read -r nom msg cmd <<<"$ligne"
		printf '  %s%s%s %s%-14s%s %s\n' "$jaune" "$icone" "$raz" "$gras" "$nom" "$raz" "$msg"
		[ -n "$cmd" ] && printf '  %17s%s%s %s%s\n' "" "$terne" "$fleche" "$(t attention_commande "$cmd")" "$raz"
	done
	return 0
}

# Statut global du script de service, communique a l'orchestrateur (Acmechanic)
# via le fichier de compteurs partage. Acmechanic l'affiche dans son bilan a
# la place du vague « OK ».
#   MAJ       : au moins une image/service a ete reellement mise a jour
#   INCHANGE  : tout etait deja a jour, rien de recree
#   ECHEC     : au moins une etape en echec
statut_global_script() {
	local statut
	if [ "$NB_ECHEC" -gt 0 ]; then
		statut="ECHEC"
	elif [ "${NB_MAJ:-0}" -gt 0 ]; then
		statut="MAJ"
	else
		# Rien n'a ete recree et aucune erreur : tout etait deja a
		# jour (ou rien d'applicable). « OK » trop vague ; on dit
		# explicitement INCHANGE.
		statut="INCHANGE"
	fi
	ecrire_compteur "SERVICE_$SERVICE_NAME" "$statut"
	# Totaux d'etapes pour le bilan global (« Etapes : n reussies... »).
	ajouter_compteur ETAPES_OK "$NB_OK"
	ajouter_compteur ETAPES_ECHEC "$NB_ECHEC"
}

_enregistrer() {
	RESULTATS+=("$1|$2|$3")
}

# run_etape <libelle> <timeout_secondes> <commande...>
# Execute la commande, mesure la duree, enregistre le statut.
# Ne stoppe jamais le script : le rapport final fait le bilan.
#
# La commande peut etre un programme externe ou une fonction bash.
# La commande externe `timeout` ne sait pas lancer une fonction bash :
# on execute donc dans un sous-shell surveille par une minuterie.
run_etape() {
	local libelle="$1" limite="$2"
	shift 2
	step "$libelle"
	local debut fin duree code
	debut=$SECONDS

	# </dev/null : garantit qu'aucune commande ne peut attendre une saisie.
	# 9>&- : ferme le descripteur du verrou dans l'enfant. Sans cela,
	# l'enfant herite du verrou du parent et le maintient ouvert, ce qui
	# bloque les executions suivantes et empeche les scripts appeles de
	# prendre leur propre verrou.
	(
		"$@"
	) </dev/null 9>&- &
	local pid_tache=$!

	# Minuterie : tue la tache si elle depasse le delai accorde.
	# Elle ferme aussi le descripteur du verrou, sans quoi un `sleep`
	# survivant continuerait a retenir le verrou du parent.
	(
		sleep "$limite"
		kill -TERM "$pid_tache" 2>/dev/null
		sleep 5
		kill -KILL "$pid_tache" 2>/dev/null
	) >/dev/null 2>&1 9>&- &
	local pid_minuterie=$!

	if wait "$pid_tache" 2>/dev/null; then
		code=0
	else
		code=$?
	fi

	# La tache est finie : on arrete la minuterie ainsi que le `sleep`
	# qu'elle a lance. Tuer seulement le sous-shell laisserait le sleep
	# orphelin tourner jusqu'a son terme.
	pkill -P "$pid_minuterie" 2>/dev/null
	kill "$pid_minuterie" 2>/dev/null
	wait "$pid_minuterie" 2>/dev/null

	fin=$SECONDS
	duree=$((fin - debut))

	# 143 = SIGTERM, 137 = SIGKILL : c'est la minuterie qui a frappe.
	if [ $code -eq 0 ]; then
		ok "$libelle -- termine en ${duree}s"
		NB_OK=$((NB_OK + 1))
		_enregistrer "$libelle" "OK" "${duree}s"
	elif [ $code -eq 143 ] || [ $code -eq 137 ] || [ $code -eq 124 ]; then
		err "$libelle -- delai de ${limite}s depasse, etape abandonnee"
		NB_ECHEC=$((NB_ECHEC + 1))
		_enregistrer "$libelle" "TIMEOUT" "${duree}s"
	else
		err "$libelle -- echec (code $code) apres ${duree}s"
		NB_ECHEC=$((NB_ECHEC + 1))
		_enregistrer "$libelle" "ECHEC" "${duree}s"
	fi
	return 0
}

# Marque une etape dont l'image/service n'a pas change : pas de
# recréation, on a gagné du temps. Compte a part pour le bilan.
inchanger_etape() {
	local libelle="$1" raison="${2:-deja a jour}"
	step "$libelle"
	log "$libelle -- inchange ($raison)"
	NB_INCHANGE=$((NB_INCHANGE + 1))
	incrementer_compteur INCHANGE
	_enregistrer "$libelle" "INCHANGE" "$raison"
}

# Marque une etape volontairement non executee, avec la raison.
ignorer_etape() {
	local libelle="$1" raison="$2"
	warn "$libelle -- ignore : $raison"
	NB_IGNORE=$((NB_IGNORE + 1))
	incrementer_compteur IGNORE
	_enregistrer "$libelle" "IGNORE" "$raison"
}

# --- Rapport final ---
# Affiche le tableau des etapes et renvoie le nombre d'echecs,
# ce qui devient le code de sortie du script.
rapport_final() {
	local titre_rapport="${1:-Bilan}"
	local ligne libelle statut info couleur
	[ "${RAPPORT_COMPACT:-}" = oui ] || echo
	# RAPPORT_COMPACT=oui : affichage fixe d'Acmechanic, qui dessine son
	# propre bilan (tableau_bilan) : rien a l'ecran, tout au journal.
	if [ "${RAPPORT_COMPACT:-}" != oui ]; then
		printf '%s%s%s\n' "$C_BOLD" "--- $titre_rapport ---" "$C_OFF"
		printf '%-42s %-9s %s\n' "ETAPE" "STATUT" "DUREE"
		printf '%s\n' "-------------------------------------------------------------------"
		for ligne in "${RESULTATS[@]}"; do
			IFS='|' read -r libelle statut info <<<"$ligne"
			case "$statut" in
			OK | MAJ) couleur="$C_GREEN" ;;
			INCHANGE) couleur="$C_CYAN" ;;
			IGNORE) couleur="$C_YELLOW" ;;
			*) couleur="$C_RED" ;;
			esac
			printf '%-42s %s%-9s%s %s\n' "$libelle" "$couleur" "$statut" "$C_OFF" "$info"
		done
		printf '%s\n' "-------------------------------------------------------------------"
		printf 'Etapes reussies : %s%d%s   Ignorees : %s%d%s   Inchangees : %s%d%s   En echec : %s%d%s\n' \
			"$C_GREEN" "$NB_OK" "$C_OFF" \
			"$C_YELLOW" "$NB_IGNORE" "$C_OFF" \
			"$C_CYAN" "$NB_INCHANGE" "$C_OFF" \
			"$C_RED" "$NB_ECHEC" "$C_OFF"
		echo "Journal complet : $LOG_FILE"
	fi
	{
		echo "--- $titre_rapport : $NB_OK reussies, $NB_IGNORE ignorees, $NB_INCHANGE inchangees, $NB_ECHEC en echec"
		for ligne in "${RESULTATS[@]}"; do
			IFS='|' read -r libelle statut info <<<"$ligne"
			printf '    %-42s %-9s %s\n' "$libelle" "$statut" "$info"
		done
	} >>"$LOG_FILE"
	return "$NB_ECHEC"
}

# --- Attente de disponibilite d'un service HTTP ---
# Considere le service vivant des qu'il repond un code HTTP attendu.
# 401/403 comptent comme vivant : le serveur repond, il demande juste
# une authentification.
attendre_http() {
	local url="$1" essais="${2:-20}" delai="${3:-3}"
	local i statut
	for ((i = 1; i <= essais; i++)); do
		statut="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 3 --max-time 10 "$url" 2>/dev/null)"
		case "$statut" in
		200 | 301 | 302 | 401 | 403)
			ok "Service joignable sur $url (code HTTP $statut, tentative $i)"
			return 0
			;;
		esac
		sleep "$delai"
	done
	err "Service injoignable sur $url apres $essais tentatives (dernier code : ${statut:-aucune reponse})"
	return 1
}

# --- Choix du tag d'image : pointe, avec repli sur latest ---
# Les services utilisent des tags de pointe (edge, develop, unstable,
# nightly) pour suivre les dernieres versions. Mais il arrive qu'un canal
# de pointe soit plus ancien que "latest" (maintenance en retard, build
# casse). Dans ce cas on rebascule automatiquement sur "latest" : autant
# avoir la version la plus recente.
#
# choisir_tag <image:tag_pointe>
#   Renvoie le tag a utiliser. On compare les dates de derniere mise a
#   jour publiees par le registre Docker Hub.
#   - si le tag de pointe est plus recent ou aussi recent que latest -> pointe
#   - sinon -> latest
#   - si le registre est injoignable, on garde le tag de pointe (on ne
#     prend pas le risque d'un repli errone)
# --- Cache disque des interrogations du registre ---
# Les deux questions posees a l'API Docker Hub (date de publication d'un
# tag, digest d'un tag) sont mises en cache sur disque. Raison mesuree :
# Acmechanic lance les services en parallele, chacun interrogeant l'API ; sous
# cette rafale l'API depasse parfois `--max-time 15`, la reponse est
# alors vide et le garde-fou « registre injoignable » declenche un pull
# inutile de ~60 s. Le cache lisse la rafale et rend les runs rapproches
# quasi instantanes.
#
# Format d'un fichier de cache : « <epoch_ecriture> <valeur> ».
# Chaque valeur est validee (motif) avant d'etre servie : un fichier
# tronque ou corrompu est ignore, pas propage.
CACHE_REGISTRE_DIR="${CACHE_REGISTRE_DIR:-$HOME/.cache/acmechanic-registre}"
TTL_DATE_TAG="${TTL_DATE_TAG:-21600}"     # 6 h : le choix de tag bouge peu
TTL_DIGEST_TAG="${TTL_DIGEST_TAG:-1800}"  # 30 min : detection de MAJ

_cache_registre_fichier() {
	printf '%s/%s' "$CACHE_REGISTRE_DIR" \
		"$(printf '%s' "$1" | md5sum | cut -d' ' -f1)"
}

# cache_registre_lire <cle> <ttl> <motif_de_validation>
cache_registre_lire() {
	local cle="$1" ttl="$2" motif="$3" f ligne age valeur
	f="$(_cache_registre_fichier "$cle")"
	[ -f "$f" ] || return 1
	ligne="$(cat "$f" 2>/dev/null)" || return 1
	age="${ligne%% *}"
	valeur="${ligne#* }"
	[[ "$age" =~ ^[0-9]+$ ]] || return 1
	[[ "$valeur" =~ $motif ]] || return 1
	[ $(( $(date +%s) - age )) -lt "$ttl" ] || return 1
	echo "$valeur"
}

# cache_registre_ecrire <cle> <valeur> : ecriture sous flock (les
# services tournent en parallele et peuvent viser la meme cle).
cache_registre_ecrire() {
	local cle="$1" valeur="$2" f
	[ -n "$valeur" ] || return 0
	f="$(_cache_registre_fichier "$cle")"
	mkdir -p "$CACHE_REGISTRE_DIR" 2>/dev/null || return 0
	(
		flock -x 9 2>/dev/null
		printf '%s %s\n' "$(date +%s)" "$valeur" >"$f"
	) 9>"$f.lock" 2>/dev/null
	return 0
}

# hub_tag_info <repo> <tag> : UNE requete a l'API Docker Hub, qui
# renseigne les DEUX caches (date de publication ET digest du tag).
# Auparavant tag_date et digest_registre interrogeaient chacun la meme
# URL : 3 requetes par image (pointe, latest, puis digest du tag
# retenu), soit ~25 requetes simultanees au lancement de Acmechanic, d'ou des
# reponses > 15 s (jusqu'a ~40 s pour resoudre un seul tag). Desormais : une
# requete par tag, et Acmechanic prechauffe le cache avant de lancer les
# services (prechauffer_registre).
hub_tag_info() {
	local json
	json="$(curl -s --max-time 15 "$(_hub_url "$1" "$2")" 2>/dev/null)" || return 1
	_hub_analyser "$1" "$2" "$json"
}

_hub_url() {
	local repo="$1"
	[[ "$repo" == */* ]] || repo="library/$repo"
	printf 'https://hub.docker.com/v2/repositories/%s/tags/%s' "$repo" "$2"
}

# _hub_analyser <repo> <tag> <json> : extrait date et digest d'une
# reponse de l'API et les range dans le cache.
_hub_analyser() {
	local repo="$1" tag="$2" json="$3" date digest
	[ -n "$json" ] || return 1
	if command -v jq >/dev/null 2>&1; then
		date="$(jq -r '.last_updated // empty' <<<"$json" 2>/dev/null)"
		digest="$(jq -r '.digest // empty' <<<"$json" 2>/dev/null)"
	else
		# Sans jq : last_updated est unique ; le digest top-level est
		# le DERNIER « digest » de la reponse (il suit images[]).
		date="$(grep -o '"last_updated":"[^"]*"' <<<"$json" | head -1 | sed 's/.*:"//; s/"$//')"
		digest="$(sed -n 's/.*"digest":"\([^"]*\)".*/\1/p' <<<"$json")"
	fi
	digest="${digest#sha256:}"
	[[ "$date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]] && cache_registre_ecrire "date:$repo:$tag" "$date"
	[[ "$digest" =~ ^[0-9a-f]{64}$ ]] && cache_registre_ecrire "digest:$repo:$tag" "$digest"
	return 0
}

tag_date() {
	local repo="$1" tag="$2" out
	out="$(cache_registre_lire "date:$repo:$tag" "$TTL_DATE_TAG" \
		'^[0-9]{4}-[0-9]{2}-[0-9]{2}T')" && { echo "$out"; return; }

	# API web de Docker Hub (~0,2 s), qui remplit aussi le cache du digest.
	hub_tag_info "$repo" "$tag"
	out="$(cache_registre_lire "date:$repo:$tag" "$TTL_DATE_TAG" \
		'^[0-9]{4}-[0-9]{2}-[0-9]{2}T')" && { echo "$out"; return; }

	# Repli : skopeo (plus lent, borne par timeout) s'il est installe.
	if command -v skopeo >/dev/null 2>&1; then
		out="$(timeout 30 skopeo inspect "docker://registry-1.docker.io/$repo:$tag" 2>/dev/null |
			grep -m1 '"Created"' | sed 's/.*: *"//; s/".*//')"
		[ -n "$out" ] || return 0
		cache_registre_ecrire "date:$repo:$tag" "$out"
		echo "$out"
	fi
}

# prechauffer_registre <image:tag>... : remplit le cache (date + digest)
# du tag demande ET de « latest » pour chaque image, avant le lancement
# parallele des services. Les entrees encore valides ne sont pas
# redemandees.
#
# Toutes les requetes manquantes partent dans UN SEUL appel curl : une
# seule resolution DNS, une seule poignee de main TLS, connexion
# reutilisee (keep-alive). Mesure 2026-09-26 : 17 requetes = ~20 s en
# appels separes (resolution DNS a 5 s une fois sur trois, voir
# README « DNS »), contre ~1 s ainsi.
prechauffer_registre() {
	local img repo tag t dossier i=0 args=() cles=()
	for img in "$@"; do
		repo="${img%:*}"; tag="${img##*:}"
		[ "$tag" = "$img" ] && tag=latest
		[[ "$repo" == */* ]] || continue   # images officielles : non utilisees ici
		for t in "$tag" latest; do
			if ! cache_registre_lire "date:$repo:$t" "$TTL_DATE_TAG" '^[0-9]{4}-' >/dev/null ||
				! cache_registre_lire "digest:$repo:$t" "$TTL_DIGEST_TAG" '^[0-9a-f]{64}$' >/dev/null; then
				cles+=("$repo|$t")
			fi
			[ "$t" = latest ] && break
		done
	done
	[ ${#cles[@]} -gt 0 ] || return 0
	dossier="$(mktemp -d /tmp/acmechanic-hub-XXXXXX)" || return 0
	for i in "${!cles[@]}"; do
		args+=(-o "$dossier/$i.json" "$(_hub_url "${cles[i]%|*}" "${cles[i]#*|}")")
	done
	curl -s --max-time 60 "${args[@]}" 2>/dev/null
	for i in "${!cles[@]}"; do
		[ -s "$dossier/$i.json" ] &&
			_hub_analyser "${cles[i]%|*}" "${cles[i]#*|}" "$(cat "$dossier/$i.json")"
	done
	rm -rf "$dossier"
	return 0
}

# images_des_projets : images (tags par defaut resolus) de tous les
# projets compose connus du daemon. Sert au prechauffage du cache.
images_des_projets() {
	local fichier
	docker compose ls -a --format json 2>/dev/null |
		grep -o '"ConfigFiles":"[^"]*"' | sed 's/.*:"//; s/"$//' | tr ',' '\n' |
		while IFS= read -r fichier; do
			[ -f "$fichier" ] || continue
			docker compose -f "$fichier" config --images 2>/dev/null
		done | sort -u
}

choisir_tag() {
	local image="$1"
	local repo="${image%:*}" tag_pointe="${image##*:}"
	# Pas de tag dans l'image : c'est deja latest.
	[ "$tag_pointe" = "$image" ] && tag_pointe="latest"
	[ "$tag_pointe" = "latest" ] && { echo latest; return; }

	local date_pointe date_latest
	# Les deux appels skopeo sont lents (jusqu'a 30 s chacun). On les
	# lance en parallele dans des fichiers temporaires, puis on lit les
	# resultats : le temps total reste borne a ~30 s au lieu de ~60 s.
	local f_p f_l
	f_p="$(mktemp)"; f_l="$(mktemp)"
	tag_date "$repo" "$tag_pointe" >"$f_p" 2>/dev/null &
	tag_date "$repo" latest >"$f_l" 2>/dev/null &
	wait
	date_pointe="$(cat "$f_p" 2>/dev/null)"
	date_latest="$(cat "$f_l" 2>/dev/null)"
	rm -f "$f_p" "$f_l"

	if [ -z "$date_pointe" ] || [ -z "$date_latest" ]; then
		echo "$tag_pointe"
		return
	fi

	# Les dates ISO UTC se comparent lexicographiquement :
	# "2026-08-11T..." > "2026-04-05T...".
	if [ "$date_pointe" \> "$date_latest" ] || [ "$date_pointe" = "$date_latest" ]; then
		echo "$tag_pointe"
	else
		echo latest
	fi
}

# --- Suivi des versions avant/apres mise a jour ---
# Chaque script de service enregistre la version de ce qu'il met a jour
# (avant le pull, puis apres le redemarrage). Acmechanic agrege ces informations
# et affiche un bloc « Versions » en fin de compte-rendu.
#
# Le fichier de collecte est partage via ACMECHANIC_VERSIONS_FICHIER (cree par
# Acmechanic et exporte vers les scripts fils). En dehors de Acmechanic, les scripts
# ecrivent dans un fichier temporaire propre a leur PID.
versions_fichier() {
	local f="${ACMECHANIC_VERSIONS_FICHIER:-/tmp/acmechanic-versions-$$.txt}"
	[ -f "$f" ] || touch "$f" 2>/dev/null
	echo "$f"
}

#enregistrer_version <service> <avant> <apres>
# Une seule ligne par service (on ecrase l'existante). L'ecriture est
# serialisee : Acmechanic lance les services en parallele, et deux services
# qui reecrivent la version en meme temps se perdaient l'un l'autre.

# On passe par _sous_verrou (voir compteurs) : flock sur <fichier>.lock
# pour que lecture->ecriture reste indivisible.

enregistrer_version() {
    local service="$1" avant="$2" apres="$3"
    local f
    # Robustesse : une ligne = un service. Une valeur multi-lignes
    # (ex. `cmd | premiere_ligne || echo "?"` qui, sous pipefail,
    # imprime une ligne vide PUIS « ? ») corrompait le fichier avec
    # des enregistrements fantomes. On aplatit, on retire le
    # separateur, et le vide devient « ? ».
    avant="$(printf '%s' "$avant" | tr '\n|' '  ')"
    apres="$(printf '%s' "$apres" | tr '\n|' '  ')"
    [ -n "${avant//[[:space:]]/}" ] || avant="?"
    [ -n "${apres//[[:space:]]/}" ] || apres="?"
    f="$(versions_fichier)"
    # Creer le fichier s'il n'existe pas
    touch "$f" 2>/dev/null || return 0
    # Format : « service|avant|apres » (celui que lit rapport_versions).
    # CORRIGE 2026-09-26 : l'ecriture produisait « service: avant ->
    # apres » alors que la lecture decoupait sur « | » : le bloc
    # Versions affichait la ligne entiere suivie de « -> » vide. Et la
    # ligne existante du service est remplacee (plus de doublons).
    _sous_verrou "$f" sh -c '
        grep -v "^$1|" "$4" > "$4.tmp" 2>/dev/null
        printf "%s|%s|%s\n" "$1" "$2" "$3" >> "$4.tmp"
        cat "$4.tmp" > "$4" && rm -f "$4.tmp"
    ' sh "$service" "$avant" "$apres" "$f" 2>/dev/null || return 0
}


# rapport_versions : affiche le bloc « Versions » a partir du fichier.
rapport_versions() {
	local f
	f="$(versions_fichier)"
	[ -s "$f" ] || return 0
	echo
	printf '%s%s%s\n' "$C_BOLD" "--- Versions (avant -> apres) ---" "$C_OFF"
	printf '%-16s %s\n' "SERVICE" "VERSION"
	printf '%s\n' "--------------------------------"
	local ligne service avant apres
	while IFS='|' read -r service avant apres; do
		[ -z "$service" ] && continue
		if [ "$avant" = "$apres" ] && [ -n "$avant" ]; then
			printf '%-16s %s (inchangee)\n' "$service" "$avant"
		else
			printf '%-16s %s -> %s\n' "$service" "$avant" "$apres"
		fi
	done <"$f"
}

# premiere_ligne : renvoie la premiere ligne de l'entree standard, sans
# risque de SIGPIPE. `... | head -1` sous pipefail provoque un SIGPIPE
# (head ferme le pipe avant la fin) qui vide la substitution ; on lit tout
# puis on ne garde que la premiere ligne.
premiere_ligne() {
	local v
	v="$(cat)"
	echo "${v%%$'\n'*}"
}

# version_commande <commande...> : premiere ligne de la sortie de la
# commande, ou « ? » si elle echoue / ne dit rien.
#
# Remplace l'idiome `cmd | premiere_ligne || echo "?"` : sous `pipefail`
# (actif dans tous les scripts), l'echec de `cmd` fait echouer TOUTE la
# pipeline, donc `premiere_ligne` imprime deja une ligne vide ET `echo
# "?"` s'execute => valeur sur deux lignes qui corrompait le fichier
# des versions (« service| » suivi de « ?| » et « ? »).
version_commande() {
	local sortie
	sortie="$("$@" 2>/dev/null | premiere_ligne)"
	[ -n "${sortie//[[:space:]]/}" ] || sortie="?"
	echo "$sortie"
}

# version_docker <conteneur> : image + date de build lisible.
# Exemple : « app:latest (build 2026-08-11) ». La date de build est
# plus parlante qu'un hash de tag de pointe (nightly/edge/...).
version_docker() {
	local c="$1" image id date
	# CORRIGE 2026-09-26 : la date lue etait celle du CONTENEUR
	# (.Created du conteneur = date de recreation), pas celle de
	# l'IMAGE : apres une simple recreation, tout affichait « build »
	# du jour. On lit maintenant la date de construction de l'image.
	IFS='|' read -r image id < <(docker inspect -f '{{.Config.Image}}|{{.Image}}' "$c" 2>/dev/null)
	[ -z "$image" ] && { echo "?"; return; }
	date="$(docker image inspect -f '{{.Created}}' "$id" 2>/dev/null | cut -dT -f1)"
	echo "${image} (build ${date})"
}

# digest_image <image:tag> : digest court de l'image LOCALE.
# Sert a detecter si un `compose pull` a reellement change l'image
# (les tags de pointe pointent vers des digests qui bougent).
digest_image() {
	local img="$1" repo
	[ -z "$img" ] && return 1
	repo="${img%:*}"
	# Images officielles : Docker range « library/nginx » et
	# « docker.io/nginx » sous le nom court « nginx@sha256:... ».
	repo="${repo#docker.io/}"
	repo="${repo#library/}"
	# Digest du manifest-list LOCAL (champ RepoDigests, qui est
	# l'empreinte du manifest-list, pas d'une plateforme isolee).
	# Une image peut porter PLUSIEURS RepoDigests (ex. docker.io et
	# lscr.io pour les images linuxserver) : on prend celui du depot
	# demande, sinon la comparaison avec digest_registre compare deux
	# depots differents et declenche un pull inutile.
	# Format court (sans prefixe sha256:), comparable directement
	# a digest_registre.
	docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$img" 2>/dev/null |
		{ grep -m1 "^${repo}@" || true; } |
		sed 's/.*@//; s/^sha256://'
}

# digest_registre <image:tag> : digest du manifest-list COTE REGISTRE.
# Utilise l'API publique Docker Hub (aucune auth requise pour les
# images publiques), qui expose le digest top-level du tag dans le
# champ `.digest` de la reponse. Ce digest est IDENTIQUE au champ
# `.RepoDigests` local des images multi-arch (verifie : digest_api
# == digest_local pour les images linuxserver.io). On peut donc savoir si
# l'image locale est a jour SANS pull (le pull est l'etape
# couteuse, 1-85 s selon le registre et le jour).

# Teste uniquement Docker Hub (hub.docker.com) ; pour un autre
# registre ou une indisponibilite, renvoie vide => l'appelant fera
# le pull (garde-fou : jamais de fausse decision « a jour »).
digest_registre() {
	local img="$1"
	local repo="${img%:*}" tag="${img##*:}" out
	[ "$tag" = "$img" ] && tag="latest"
	repo="${repo#docker.io/}"
	# Autre registre (ghcr.io/..., lscr.io/..., hote:port/...) : non gere,
	# l'appelant fera le pull. Les images officielles (« nginx ») sont
	# sur Docker Hub (_hub_url ajoute library/).
	[[ "$repo" == */* && "${repo%%/*}" == *[.:]* ]] && return 1

	# Cache court (TTL_DIGEST_TAG, 30 min par defaut), prechauffe par
	# Acmechanic ; sinon une requete hub_tag_info (qui remplit aussi la date).
	out="$(cache_registre_lire "digest:$repo:$tag" "$TTL_DIGEST_TAG" \
		'^[0-9a-f]{64}$')" && { echo "$out"; return 0; }
	hub_tag_info "$repo" "$tag"
	out="$(cache_registre_lire "digest:$repo:$tag" "$TTL_DIGEST_TAG" \
		'^[0-9a-f]{64}$')" && { echo "$out"; return 0; }
	return 1
}
version_flatpak() {
	local appid="$1"
	flatpak info "$appid" 2>/dev/null | grep -i '^ *Version:' |
		sed 's/.*Version:[[:space:]]*//; s/[[:space:]]*$//'
}

# --- Aide docker compose ---
# Execute docker compose dans le dossier du projet indique.
# Les variables d'environnement du shell (ex. UN_TAG resolues par
# choisir_tag) sont lues par compose : ${VAR:-defaut} dans le fichier.
compose() {
	local projet="$1"
	shift
	# COMPOSE_FICHIER : fichier compose non standard (ex. docker-compose.app.yml).
	docker compose --project-directory "$projet" -f "${COMPOSE_FICHIER:-$projet/docker-compose.yml}" "$@"
}

# --- Maintenance generique d'un service Docker (DRY) ---
# Tous les scripts de service suivaient le meme pattern : pull, comparer
# le digest pour decider si l'image a change, et seulement si oui :
# sauvegarde + arret + redemarrage + verification + nettoyage. Cette
# fonction centralise tout ca pour UN service/conteneur.
#
# maintenir_service_docker <projet> <service> <url> <image> <sauvegarder> <source> <elements...>
#   projet      : dossier contenant docker-compose.yml
#   service     : nom du service dans le compose (= nom du conteneur)
#   url         : URL testee apres redemarrage (vide = pas de verification)
#   image       : image:tag resolue (ex. editeur/app:latest), sert a
#                 comparer le digest local avant/apres pull
#   sauvegarder : "oui" pour sauvegarder avant recréation, "non" sinon
#                 (utile quand un meme dossier est partage par 2 services,
#                 ex. un hub et son agent : on sauvegarde une fois)
#   source      : dossier source de la sauvegarde
#   elements    : chemins relatifs a <source> a inclure dans l'archive

# Un conteneur arrete ou absent est TOUJOURS recree, meme si son image
# est a jour : sans ce test, un service disparu (arret manuel, prune,
# demarrage rate) restait eteint indefiniment pendant que le script
# annoncait « image deja a jour » (cas observe pendant plusieurs jours).
conteneur_actif() {
	docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$1"
}

# conteneur_a_jour <conteneur> <image:tag> : vrai si le conteneur tourne
# EXACTEMENT l'image locale que designe ce tag (comparaison des ID
# d'image, pas des tags : un tag de pointe est reattribue a chaque
# publication).
#
# Indispensable a la gate : l'image locale peut etre a jour alors que le
# conteneur tourne encore l'ancienne (pull deja telecharge mais jamais
# suivi d'une recreation). Cas vecu : un gros pull coupe par le delai
# d'etape s'est termine cote daemon ; au run suivant « local == registre »
# etait vrai, le service etait annonce a jour, et le conteneur tournait
# toujours l'ancienne image.
conteneur_a_jour() {
	local conteneur="$1" image="$2" id_conteneur id_image
	id_conteneur="$(docker inspect -f '{{.Image}}' "$conteneur" 2>/dev/null)"
	id_image="$(docker image inspect -f '{{.Id}}' "$image" 2>/dev/null)"
	[ -n "$id_conteneur" ] && [ -n "$id_image" ] && [ "$id_conteneur" = "$id_image" ]
}

# --- Indicateurs de sante Docker (ajout 2026-09-26) ---
#
# etat_sante <conteneur> : healthy | unhealthy | starting | aucun | absent
#   « aucun » = conteneur sans HEALTHCHECK (on ne peut rien conclure).
etat_sante() {
	local s
	s="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}aucun{{end}}' "$1" 2>/dev/null)" ||
		{ echo absent; return; }
	echo "${s:-absent}"
}

# attendre_sante <conteneur> [delai_s] : attend que Docker declare le
# conteneur « healthy ». C'est un controle plus juste que attendre_http :
# il execute la sonde DEFINIE PAR LE SERVICE (ex. /ping,
# /healthz, ou une commande interne de l'application) depuis l'interieur du
# conteneur. Sans HEALTHCHECK, on se contente de « running ».
# Les compose declarent `start_interval: 5s` : pendant le demarrage la
# sonde passe toutes les 5 s au lieu de 60 s, d'ou une reponse rapide.
attendre_sante() {
	local c="$1" delai="${2:-120}" debut=$SECONDS etat
	while [ $((SECONDS - debut)) -lt "$delai" ]; do
		etat="$(etat_sante "$c")"
		case "$etat" in
		healthy)
			ok "$c : sain selon Docker (apres $((SECONDS - debut))s)"
			return 0 ;;
		aucun)
			if [ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" = true ]; then
				ok "$c : en marche (pas de HEALTHCHECK defini)"
				return 0
			fi ;;
		esac
		sleep 3
	done
	err "$c : etat « $etat » apres ${delai}s (attendu : healthy)"
	docker inspect -f '{{range .State.Health.Log}}{{printf "%.200s" .Output}}{{"\n"}}{{end}}' "$c" 2>/dev/null |
		tail -2 | sed 's/^/    sonde : /'
	return 1
}

# config_a_jour <projet> <service> [fichier_compose] : vrai si le
# conteneur a ete cree avec la configuration ACTUELLE du compose.
# Compare l'empreinte calculee par compose (`config --hash`) a
# l'etiquette com.docker.compose.config-hash posee sur le conteneur.
# Sans ce test, une modification du compose (healthcheck, limites,
# volumes...) n'etait appliquee qu'a la prochaine NOUVELLE image : le
# script annoncait « inchange » alors que le conteneur tournait une
# configuration perimee. En cas de doute (erreur), on repond « a jour »
# pour ne jamais provoquer de recreation injustifiee.
config_a_jour() {
	local projet="$1" service="$2" fichier="${3:-${COMPOSE_FICHIER:-$1/docker-compose.yml}}"
	local h_compose h_conteneur conteneur
	h_compose="$(docker compose --project-directory "$projet" -f "$fichier" \
		config --hash "$service" 2>/dev/null | awk '{print $2}')"
	conteneur="$(docker compose --project-directory "$projet" -f "$fichier" \
		ps -a -q "$service" 2>/dev/null | head -1)"
	[ -n "$h_compose" ] && [ -n "$conteneur" ] || return 0
	h_conteneur="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.config-hash"}}' "$conteneur" 2>/dev/null)"
	[ -z "$h_conteneur" ] || [ "$h_compose" = "$h_conteneur" ]
}

# nettoyer_images : `docker image prune` SERIALISE entre services.
# Acmechanic lance les services en parallele ; deux prune simultanes font
# repondre au second « a prune operation is already running » (erreur
# 409) et l'etape passait en ECHEC a tort.
nettoyer_images() {
	flock -w 300 /tmp/maintenance-docker-prune.lock docker image prune -f
}

maintenir_service_docker() {
	local projet="$1" service="$2" url="$3" image="$4" sauvegarder="$5" source="$6"
	shift 6
	local elements=("$@")
	local ver_avant d_avant d_registre d_apres actif=false a_jour=false
	local sante config_ok=true

	conteneur_actif "$service" && actif=true
	conteneur_a_jour "$service" "$image" && a_jour=true
	ver_avant="$(version_docker "$service" 2>/dev/null || echo "?")"
	d_avant="$(digest_image "$image")"
	sante="$(etat_sante "$service")"
	[ "$actif" = true ] && ! config_a_jour "$projet" "$service" && config_ok=false

	# Gate : rien a faire si CINQ conditions sont reunies :
	#   1. le conteneur tourne,
	#   2. il tourne bien l'image locale de ce tag,
	#   3. cette image locale est deja la derniere du registre,
	#   4. il a ete cree avec la configuration actuelle du compose,
	#   5. sa sonde de sante n'est pas en echec (unhealthy).
	# digest_registre (API Docker Hub, ~0,2 s, mise en cache) renvoie le
	# digest du manifest-list distant : on evite alors pull ET
	# recreation, c'est le gros gain de temps (le pull coute 1 a 900 s
	# selon l'image).
	# En cas de registre injoignable / non-Hub, digest_registre est
	# vide et on retombe sur l'ancien flux (pull puis comparaison).
	d_registre="$(digest_registre "$image")"
	if [ "$actif" = true ] && [ "$a_jour" = true ] && [ -n "$d_registre" ] &&
		[ -n "$d_avant" ] && [ "$d_registre" = "$d_avant" ]; then
		if [ "$config_ok" = true ] && [ "$sante" != unhealthy ]; then
			inchanger_etape "$service" "derniere image registre deja en local (build ${ver_avant##*build }, sante : $sante)"
			enregistrer_version "$service" "$ver_avant" "$ver_avant"
			return 0
		fi
		# Image a jour mais conteneur a reprendre : recreation SANS pull
		# ni sauvegarde (l'image ne change pas, les volumes persistent).
		if [ "$config_ok" != true ]; then
			warn "$service : docker-compose.yml modifie depuis la creation du conteneur, recreation."
		else
			warn "$service : sonde de sante en echec (unhealthy), recreation."
		fi
		run_etape "$service : recreation" 180 compose "$projet" up -d --force-recreate "$service"
		run_etape "$service : verification de la sante" 180 attendre_sante "$service" 170
		NB_MAJ=$((NB_MAJ + 1))
		enregistrer_version "$service" "$ver_avant" "$ver_avant"
		return 0
	fi

	if [ "$actif" != true ]; then
		warn "$service : conteneur arrete ou absent, il sera (re)cree."
	elif [ "$a_jour" != true ]; then
		warn "$service : le conteneur tourne une image plus ancienne que l'image locale, recreation."
	fi

	if [ -n "$d_registre" ] && [ -z "$d_avant" ] && [ "$ver_avant" = "?" ]; then
		# Conteneur absent (image jamais tiree) : pull + creation sans
		# sauvegarde (rien a proteger : pas de version precedente, les
		# volumes de config persistent de toute facon).
		run_etape "$service : pull de l'image" "$DELAI_PULL" compose "$projet" pull "$service"
		run_etape "$service : redemarrage" 180 compose "$projet" up -d --remove-orphans "$service"
		_verifier_apres_demarrage "$service" "$url"
		NB_MAJ=$((NB_MAJ + 1))
		enregistrer_version "$service" "$ver_avant" "$(version_docker "$service" 2>/dev/null || echo "?")"
		return 0
	fi

	# Digest inconnu ou different : pull, puis comparaison avant/apres.
	run_etape "$service : pull de l'image" "$DELAI_PULL" compose "$projet" pull "$service"

	d_apres="$(digest_image "$image")"
	if [ "$actif" = true ] && [ "$a_jour" = true ] && [ "$d_avant" = "$d_apres" ] &&
		[ -n "$d_avant" ] && [ "$config_ok" = true ] && [ "$sante" != unhealthy ]; then
		inchanger_etape "$service" "image deja a jour (build ${ver_avant##*build }, sante : $sante)"
		enregistrer_version "$service" "$ver_avant" "$ver_avant"
		return 0
	fi

	# L'image a change : on met a jour pour de vrai.
	# On arrete d'abord (base au repos pendant la copie, surtout pour
	# les bases SQLite embarquees), puis on sauvegarde, puis on
	# relance.
	run_etape "$service : arret" 120 compose "$projet" down "$service"
	if [ "$sauvegarder" = "oui" ]; then
		run_etape "$service : sauvegarde" 600 creer_sauvegarde "$service" "$source" "${elements[@]}"
	fi
	run_etape "$service : redemarrage" 180 compose "$projet" up -d --remove-orphans "$service"
	_verifier_apres_demarrage "$service" "$url"
	run_etape "$service : nettoyage images orphelines" 300 nettoyer_images
	NB_MAJ=$((NB_MAJ + 1))
	enregistrer_version "$service" "$ver_avant" "$(version_docker "$service" 2>/dev/null || echo "?")"
}

# Verification apres (re)demarrage : d'abord la sonde Docker (controle
# interne au conteneur), puis l'URL depuis l'hote (controle du port
# publie). Une fois le conteneur « healthy », l'URL repond du premier coup.
_verifier_apres_demarrage() {
	local service="$1" url="$2"
	run_etape "$service : verification de la sante" 180 attendre_sante "$service" 170
	if [ -n "$url" ]; then
		run_etape "$service : verification HTTP" 90 attendre_http "$url" 20 3
	fi
}
bilan_service() {
	local titre="${1:-Bilan}"
	statut_global_script
	if [ -z "${ACMECHANIC_VERSIONS_FICHIER:-}" ]; then
		rapport_versions
	fi
	# Lance seul : ses points d'attention a la fin. Sous Acmechanic, ils
	# sont regroupes dans le bilan global.
	[ -z "${ACMECHANIC_ATTENTION_FICHIER:-}" ] && rapport_attention ""
	rapport_final "$titre"
}
