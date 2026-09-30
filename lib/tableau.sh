#!/bin/bash
# tableau.sh - Affichage fixe de Acmechanic : un tableau redessine en place.
# Usage : source "${ACMECHANIC_HOME}/lib/tableau.sh" (par acmechanic.sh seulement).
#
# Principe : au lieu d'empiler les journaux de N services
# paralleles, chaque service ecrit sa DERNIERE action dans un petit
# fichier d'etat (voir _log_raw dans common.sh, variable
# ACMECHANIC_ETAT_FICHIER). Un processus d'affichage relit ces fichiers deux
# fois par seconde et redessine le tableau au meme endroit de l'ecran.
#
# Fichiers d'etat, dans le dossier passe a tableau_demarrer :
#   <ligne>          derniere action (ecrit par le service)
#   <ligne>.debut    instant de lancement (epoch), ecrit par Acmechanic
#   <ligne>.fin      « STATUT|duree », ecrit par Acmechanic a la fin
#   <ligne>.alertes  lignes ATTENTION / ERREUR (lues au bilan)
#
# Rien n'est affiche si la sortie n'est pas un terminal, si le terminal
# est trop petit, ou si ACMECHANIC_TABLEAU=non : Acmechanic retombe alors sur
# l'affichage ligne a ligne.

[ -n "${_TABLEAU_SH_LOADED:-}" ] && return 0
_TABLEAU_SH_LOADED=1

# shellcheck source=i18n.sh
source "$(dirname "${BASH_SOURCE[0]}")/i18n.sh"

TABLEAU_PID=""
TABLEAU_DOSSIER=""
TABLEAU_SORTIES="" # dossier des <ligne>.sortie (detail des services)
TABLEAU_LIGNES=()
_TABLEAU_SPIN=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
TABLEAU_DEBUT=""

# --- Icones (police Nerd Font, 2026-09-27) ---
# Codes Font Awesome 4 (U+F000-F2E0) et logos Linux de Nerd Fonts : les
# plus stables d'une version de Nerd Fonts a l'autre. Ecrits en octets
# UTF-8 (\xNN) et non en \uNNNN : ce dernier depend de la locale au
# chargement (C/POSIX sous cron ou ssh = icone illisible). Chaque icone est
# suivie d'une espace : avec une police Nerd non « Mono », le glyphe
# deborde sur la cellule suivante. ACMECHANIC_ICONES=non : jeu Unicode simple.
declare -A _ICONE_SERVICE _ICONE_STATUT
if [ "${ACMECHANIC_ICONES:-oui}" = oui ]; then
	# Services de la bibliotheque ; les votres : ICONES_SERVICES (local.conf).
	_ICONE_SERVICE=(
		[systeme]=$'\xef\x8c\x95' [defaut]=$'\xef\x80\x93' [docker]=$'\xef\x88\x9e'
		[jellyfin]=$'\xef\x80\x88' [plex]=$'\xef\x80\x88' [audiobookshelf]=$'\xef\x80\xa5'
		[arr]=$'\xef\x89\xac' [cross-seed]=$'\xef\x83\xac' [syncthing]=$'\xef\x80\xa1'
		[vaultwarden]=$'\xef\x80\xa3' [uptime-kuma]=$'\xef\x88\x9e' [forgejo]=$'\xef\x84\xa6'
		[portainer]=$'\xef\x82\xae' [beszel]=$'\xef\x82\x80' [open-webui]=$'\xef\x83\xa6'
		[depots-git]=$'\xef\x87\x93' [outils-ia]=$'\xef\x83\x90' [micrologiciel]=$'\xef\x8b\x9b'
		[nettoyage]=$'\xef\x87\xb8' [acmefrag]=$'\xef\x82\xa0' [flatpak]=$'\xef\x86\xb3' [bureau]=$'\xef\x84\x88'
	)
	_ICONE_STATUT=(
		[OK]=$'\xef\x81\x98' [INCHANGE]=$'\xef\x81\x98' [MAJ]=$'\xef\x82\xaa'
		[IGNORE]=$'\xef\x81\x96' [ATTENTE]=$'\xef\x89\x90' [TIMEOUT]=$'\xef\x80\x97'
		[ECHEC]=$'\xef\x81\x97' [ATTENTION]=$'\xef\x81\xb1' [ERREUR]=$'\xef\x81\xaa'
		[TITRE]=$'\xef\x80\xa1' [HORLOGE]=$'\xef\x80\x97' [MACHINE]=$'\xef\x8c\x95'
		[VERSIONS]=$'\xef\x80\xac' [DISQUE]=$'\xef\x82\xa0' [SAUVEGARDE]=$'\xef\x86\x87'
		[DOSSIER]=$'\xef\x81\xbc' [FLECHE]=$'\xef\x81\xa1' [ETOILE]=$'\xef\x80\x85'
	)
else
	_ICONE_SERVICE=([defaut]="•")
	_ICONE_STATUT=(
		[OK]="✓" [INCHANGE]="✓" [MAJ]="↑" [IGNORE]="–" [ATTENTE]="·"
		[TIMEOUT]="⌛" [ECHEC]="✗" [ATTENTION]="!" [ERREUR]="✗"
		[TITRE]="»" [HORLOGE]="" [MACHINE]="" [VERSIONS]="»" [DISQUE]=""
		[SAUVEGARDE]="" [DOSSIER]="" [FLECHE]="→" [ETOILE]="*"
	)
fi

# Icones ajoutees par l'utilisateur (local.conf) :
#   declare -A ICONES_SERVICES=([mon-app]=$'\xef\x80\x95')
if declare -p ICONES_SERVICES >/dev/null 2>&1; then
	for _k in "${!ICONES_SERVICES[@]}"; do _ICONE_SERVICE[$_k]="${ICONES_SERVICES[$_k]}"; done
	unset _k
fi

# Couleurs du THEME du terminal (2026-09-28) : uniquement les 16 couleurs
# ANSI (30-37, 90-97) et la video inverse. Elles suivent le theme choisi
# dans kitty / LXTerminal, au lieu de teintes 256 couleurs figees.
_T_RAZ=$'\033[0m' _T_GRAS=$'\033[1m' _T_ITAL=$'\033[3m' _T_INV=$'\033[7m'
_T_TERNE=$'\033[90m' _T_TRAIT=$'\033[90m' _T_BLEU=$'\033[94m'
_T_ROUGE=$'\033[91m' _T_JAUNE=$'\033[93m' _T_VERT=$'\033[92m'
_T_CYAN=$'\033[96m' _T_MAGENTA=$'\033[95m'
# Arc-en-ciel : une couleur par service (cadre pendant le travail) et
# pour la barre d'avancement.
_T_ARC=($'\033[95m' $'\033[96m' $'\033[93m' $'\033[92m' $'\033[94m' $'\033[91m'
	$'\033[35m' $'\033[36m' $'\033[33m' $'\033[32m')

# Onomatopees de dessin anime, pour le seul plaisir des yeux : le bas de
# chaque cadre en affiche une selon l'etat du service.
# Textes : catalogue de la langue (lib/i18n.sh, locale/).
IFS='|' read -r -a _T_ONOMATOPEES <<<"${MSG[bruit_travail]}"

# _tableau_style <statut> [indice] : fixe _COUL (cadre et titre),
# _LIBELLE, _ICONE et _BRUIT (onomatopee du bas de cadre).
_tableau_style() {
	local i="${2:-0}"
	case "$1" in
	"EN COURS")
		_COUL="${_T_ARC[$((i % ${#_T_ARC[@]}))]}" _LIBELLE="${MSG[statut_travail]}" _ICONE="$_SPIN"
		_BRUIT="${_T_ONOMATOPEES[$(((EPOCHSECONDS / 2 + i) % ${#_T_ONOMATOPEES[@]}))]}" ;;
	MAJ) _COUL="$_T_VERT" _LIBELLE="${MSG[statut_maj]}" _ICONE="${_ICONE_STATUT[MAJ]}" _BRUIT="${MSG[bruit_maj]}" ;;
	OK) _COUL=$'\033[32m' _LIBELLE="${MSG[statut_ok]}" _ICONE="${_ICONE_STATUT[OK]}" _BRUIT="${MSG[bruit_ok]}" ;;
	INCHANGE) _COUL=$'\033[32m' _LIBELLE="${MSG[statut_inchange]}" _ICONE="${_ICONE_STATUT[INCHANGE]}" _BRUIT="${MSG[bruit_ok]}" ;;
	IGNORE) _COUL="$_T_JAUNE" _LIBELLE="${MSG[statut_ignore]}" _ICONE="${_ICONE_STATUT[IGNORE]}" _BRUIT="${MSG[bruit_ignore]}" ;;
	"EN ATTENTE") _COUL="$_T_TERNE" _LIBELLE="${MSG[statut_attente]}" _ICONE="${_ICONE_STATUT[ATTENTE]}" _BRUIT="${MSG[bruit_attente]}" ;;
	TIMEOUT) _COUL="$_T_ROUGE" _LIBELLE="${MSG[statut_timeout]}" _ICONE="${_ICONE_STATUT[TIMEOUT]}" _BRUIT="${MSG[bruit_timeout]}" ;;
	*) _COUL="$_T_ROUGE" _LIBELLE="${MSG[statut_echec]}" _ICONE="${_ICONE_STATUT[ECHEC]}" _BRUIT="${MSG[bruit_echec]}" ;;
	esac
}

# _tableau_utf8 : les longueurs et coupes de chaines (${#v}, ${v:0:n})
# comptent en caracteres seulement sous une locale UTF-8 ; sous C/POSIX
# (cron, ssh) elles compteraient en octets et couperaient un « é ».
_tableau_utf8() {
	case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
	*UTF-8* | *utf8* | *UTF8* | *utf-8*) ;;
	*) export LC_ALL=C.UTF-8 ;;
	esac
}

# _tableau_cadrer <texte> <largeur> -> _CADRE : texte complete d'espaces
# a gauche-justifie. `printf %-10s` compte en OCTETS (« inchangé » ferait
# une colonne de moins) : on complete donc a la main, en caracteres.
_tableau_cadrer() {
	local t="${1:0:$2}" esp
	printf -v esp '%*s' $(($2 - ${#t})) ''
	_CADRE="$t$esp"
}

# _tableau_duree <secondes> -> _DUREE : « 42s » ou « 2m05s ».
_tableau_duree() {
	local s="${1%s}"
	[[ "$s" =~ ^[0-9]+$ ]] || { _DUREE="$1"; return; }
	if [ "$s" -ge 60 ]; then
		printf -v _DUREE '%dm%02ds' $((s / 60)) $((s % 60))
	else
		_DUREE="${s}s"
	fi
}
# Derniere action lue par ligne : un fichier lu pendant sa reecriture
# peut paraitre vide un instant, on garde alors la valeur precedente.
declare -A _TABLEAU_DERNIER=()

# tableau_demarrer <dossier_etat> <dossier_sorties> <ligne>... : lance
# l'affichage.
tableau_demarrer() {
	TABLEAU_DOSSIER="$1"
	TABLEAU_SORTIES="$2"
	shift 2
	TABLEAU_LIGNES=("$@")
	TABLEAU_DEBUT="$EPOCHSECONDS"
	rm -f "$TABLEAU_DOSSIER/.dessine"
	printf '\033[?25l' >/dev/tty # curseur masque pendant l'affichage
	# Ascenseur a la molette et au clavier : terminal en mode caractere
	# (sans echo, Ctrl+C garde) et suivi de la souris (SGR 1006). Tout est
	# remis en etat par tableau_arreter, y compris sur interruption.
	_TABLEAU_STTY=""
	if [ "${ACMECHANIC_SOURIS:-oui}" = oui ] && _TABLEAU_STTY="$(stty -g </dev/tty 2>/dev/null)"; then
		stty -icanon -echo min 1 time 0 </dev/tty 2>/dev/null
		printf '\033[?1000h\033[?1006h' >/dev/tty
	fi
	_tableau_boucle </dev/null >/dev/tty 2>/dev/null 9>&- &
	TABLEAU_PID=$!
}

# tableau_liberer_terminal : fin du suivi de la souris, mode normal.
tableau_liberer_terminal() {
	[ -n "${_TABLEAU_STTY:-}" ] || return 0
	printf '\033[?1000l\033[?1006l' >/dev/tty 2>/dev/null
	stty "$_TABLEAU_STTY" </dev/tty 2>/dev/null
	_TABLEAU_STTY=""
}

# tableau_arreter : arrete l'affichage, dessine l'etat final, rend le
# curseur. Sans effet si le tableau n'est pas actif (idempotent).
tableau_arreter() {
	if [ -n "$TABLEAU_PID" ]; then
		kill -TERM "$TABLEAU_PID" 2>/dev/null
		wait "$TABLEAU_PID" 2>/dev/null
		TABLEAU_PID=""
		(_tableau_utf8 && _tableau_dessiner final) >/dev/tty 2>/dev/null
		printf '\033[?25h' >/dev/tty 2>/dev/null
	fi
	# Terminal rendu APRES l'arret de l'affichage : un `read` interrompu
	# remet en partant les reglages qu'il avait trouves (mode caractere).
	# Toujours execute, meme si l'affichage est deja mort.
	tableau_liberer_terminal
}

# Boucle d'affichage. SIGTERM ne l'interrompt qu'ENTRE deux images :
# une image coupee en deux decalerait le curseur et casserait la
# suivante.
_tableau_boucle() {
	local fin=""
	_tableau_utf8
	shopt -s extglob # motif de suppression des sequences ANSI
	trap 'fin=1' TERM
	# Ctrl+C touche tout le groupe de processus : l'affichage l'ignore et
	# attend le TERM de tableau_arreter (appele par le trap de Acmechanic).
	trap '' INT
	local cle c seq
	while [ -z "$fin" ]; do
		_tableau_dessiner
		# Attente de 0,5 s, ecourtee par la molette ou une touche : l'image
		# suit aussitot. Sans terminal lisible : simple pause.
		if [ -z "${_TABLEAU_STTY:-}" ]; then
			sleep 0.5
			continue
		fi
		IFS= read -rsn1 -t 0.5 cle </dev/tty 2>/dev/null || continue
		[ "$cle" = $'\e' ] || continue
		seq=""
		while IFS= read -rsn1 -t 0.05 c </dev/tty 2>/dev/null; do
			seq+="$c"
			[[ "$c" =~ [A-Za-z~] ]] && break
		done
		_tableau_touche "$seq"
	done
}

# _tableau_touche <sequence> : molette (SGR 64/65), fleches, Page
# precedente/suivante, Debut/Fin. Le defilement manuel l'emporte sur le
# suivi automatique pendant ACMECHANIC_DEFIL_PAUSE secondes (20) apres
# la derniere action ; Fin rend la main au suivi automatique.
_DEFIL_MAN="" _DEFIL_T=0 _DEFIL_AUTO=0 _DEFIL_VUE=10
_tableau_touche() {
	local pas=0
	case "$1" in
	"[<64;"*[Mm]) pas=-3 ;;
	"[<65;"*[Mm]) pas=3 ;;
	"[A") pas=-1 ;;
	"[B") pas=1 ;;
	"[5~") pas=$((-_DEFIL_VUE)) ;;
	"[6~") pas=$_DEFIL_VUE ;;
	"[H" | "[1~") _DEFIL_MAN=0 _DEFIL_T=$EPOCHSECONDS; return ;;
	"[F" | "[4~") _DEFIL_MAN=""; return ;;
	*) return ;;
	esac
	_DEFIL_MAN=$((${_DEFIL_MAN:-$_DEFIL_AUTO} + pas))
	_DEFIL_T=$EPOCHSECONDS
}

# _tableau_details <fichier> <k> : range dans _DETAILS les k dernieres
# lignes utiles du fichier de sortie d'un service (journal + sorties des
# commandes). Seuls les 6 derniers Ko sont lus (`tail -c`) ; les
# sequences ANSI sont retirees et, pour une barre de progression
# (retours chariot), seul le dernier etat de la ligne est garde.
_tableau_details() {
	local fichier="$1" k="$2" brut ligne i
	local -a lignes
	_DETAILS=()
	[ "$k" -gt 0 ] && [ -s "$fichier" ] || return 0
	brut="$(tail -c 6000 "$fichier" 2>/dev/null)"
	brut="${brut//$'\e'\[*([0-9;?])[a-zA-Z]/}"
	brut="${brut//$'\t'/  }"
	mapfile -t lignes <<<"$brut"
	for ((i = ${#lignes[@]} - 1; i >= 0 && ${#_DETAILS[@]} < k; i--)); do
		ligne="${lignes[i]%$'\r'}"
		ligne="${ligne##*$'\r'}"
		[ -n "${ligne//[[:space:]]/}" ] || continue
		# Bruit ecarte : traits de separation (=== ---), bilan de fin de
		# script (deja visible dans le tableau).
		[ -n "${ligne//[[:space:]=─-]/}" ] || continue
		case "${ligne#"${ligne%%[![:space:]]*}"}" in
		"Etapes reussies :"* | "Journal complet :"* | "--- Bilan"* | "ETAPE "* | "SERVICE "* | "MAINTENANCE "*) continue ;;
		esac
		_DETAILS=("$ligne" "${_DETAILS[@]}")
	done
}

# _tableau_disposition <nb_lignes> : calcule une disposition FIXE a
# partir de la taille de la fenetre (2026-09-28, demande utilisateur :
# des cases pre-determinees, un affichage qui ne bouge pas).
#   _NCOL      colonnes de cadres (1 a 3, cadres de 58 colonnes minimum)
#   _NRANG     rangees de cadres
#   _LARG      largeur d'un cadre
#   _K         lignes de detail par cadre (identique pour TOUS les
#              services, quel que soit leur etat : rien ne se deplace)
# Recalculee a chaque image : elle ne change que si la fenetre change.
_tableau_disposition() {
	local n="$1" rows="$2" cols="$3"
	_NCOL=$((cols / 58))
	[ "$_NCOL" -lt 1 ] && _NCOL=1
	[ "$_NCOL" -gt 3 ] && _NCOL=3
	[ "$_NCOL" -gt "$n" ] && _NCOL="$n"
	_NRANG=$(((n + _NCOL - 1) / _NCOL))
	_LARG=$(((cols - 1 - (_NCOL - 1)) / _NCOL))
	# En-tete 2 lignes + 1 de marge ; chaque cadre = K + 2 bordures.
	# Jamais moins de ACMECHANIC_LIGNES_MIN lignes de detail : si tout ne
	# tient pas a l'ecran, la grille defile (ascenseur, _DEFIL=oui).
	local kmin="${ACMECHANIC_LIGNES_MIN:-6}"
	_K=$(((rows - 3) / _NRANG - 2))
	[ "$_K" -gt 12 ] && _K=12
	_DEFIL=non
	if [ "$_K" -lt "$kmin" ]; then
		_K="$kmin"
		_DEFIL=oui
	fi
}

# tableau_possible <nb_lignes> : vrai si le tableau peut s'afficher.
tableau_possible() {
	local h w
	[ "${ACMECHANIC_TABLEAU:-oui}" = oui ] && [ -t 1 ] || return 1
	read -r h w < <(stty size </dev/tty 2>/dev/null) || return 1
	_tableau_disposition "$1" "${h:-0}" "${w:-0}"
	# Au moins une rangee entiere a l'ecran et 40 colonnes par cadre.
	[ $((3 + _K + 2)) -le "${h:-0}" ] && [ "$_LARG" -ge 40 ]
}

# _tableau_ligne_detail <ligne> <statut> <largeur> -> _LD (ligne coloree)
# et _LD_LARG (sa largeur visible). Les lignes de journal portent leur
# niveau entre deux \x1f (voir _log_raw) : meme couleur et meme icone
# qu'a l'ecran, dans les couleurs du theme. La sortie des commandes
# (docker, nala...) garde la couleur par defaut ; une erreur ressort en rouge.
_tableau_ligne_detail() {
	local det="$1" statut="$2" w="$3" niveau="" icone="" coul=""
	if [[ "$det" == $'\x1f'*$'\x1f'* ]]; then
		niveau="${det#$'\x1f'}" niveau="${niveau%%$'\x1f'*}"
		det="${det#$'\x1f'*$'\x1f'}"
	fi
	case "$niveau" in
	OK) icone="${_ICONE_STATUT[OK]}" coul="$_T_VERT" ;;
	ATTENTION) icone="${_ICONE_STATUT[ATTENTION]}" coul="$_T_JAUNE" ;;
	ERREUR) icone="${_ICONE_STATUT[ERREUR]}" coul="$_T_ROUGE" ;;
	ETAPE) icone="${_ICONE_STATUT[FLECHE]}" coul="$_T_BLEU" ;;
	INFO) icone="·" coul="" ;;
	*)
		if [ "$statut" = "EN ATTENTE" ]; then
			coul="$_T_ITAL$_T_TERNE"
		elif [[ "${det,,}" =~ (^|[^a-z])(error|erreur|failed|fatal)([^a-z]|$) ]]; then
			coul="$_T_ROUGE"
		fi
		;;
	esac
	[ -n "$icone" ] && det="$icone $det"
	det="${det:0:$w}"
	_LD_LARG=${#det}
	_LD="${coul}${det}${_T_RAZ}"
}

# _tableau_cadre <nom> <indice> : construit le cadre d'un service dans
# le tableau _CADRE_L (K + 2 lignes, toutes exactement de _LARG colonnes).
_tableau_cadre() {
	local nom="$1" idx="$2" d="$TABLEAU_DOSSIER" statut duree debut
	local titre droite remplir ligne det i w="$_LARG" c
	_CADRE_L=()
	if [ -f "$d/$nom.fin" ]; then
		IFS='|' read -r statut duree <"$d/$nom.fin"
	elif [ -f "$d/$nom.debut" ]; then
		read -r debut <"$d/$nom.debut"
		statut="EN COURS"
		duree="$((EPOCHSECONDS - ${debut:-$EPOCHSECONDS}))"
	else
		statut="EN ATTENTE" duree=""
	fi
	_tableau_style "$statut" "$idx"
	c="$_COUL"
	_DUREE=""
	[ -n "$duree" ] && [ "$duree" != "-" ] && _tableau_duree "$duree"

	# Bordure haute : ╭─ <icone> nom ─── <icone statut> libelle  duree ─╮
	titre=" ${_ICONE_SERVICE[$nom]:-${_ICONE_SERVICE[defaut]}} $nom "
	droite=" $_ICONE $_LIBELLE${_DUREE:+ · $_DUREE} "
	remplir=$((w - 4 - ${#titre} - ${#droite}))
	[ "$remplir" -lt 1 ] && { droite=" $_ICONE "; remplir=$((w - 4 - ${#titre} - ${#droite})); }
	printf -v ligne '%*s' "$((remplir > 0 ? remplir : 0))" ''
	_CADRE_L+=("${c}╭─${_T_RAZ}${_T_GRAS}${c}${titre}${_T_RAZ}${c}${ligne// /─}${_T_RAZ}${_T_INV}${c}${droite}${_T_RAZ}${c}─╮${_T_RAZ}")

	# Contenu : K lignes, toujours. En attente : une invitation ; sinon
	# les dernieres lignes de la sortie du service (gardees une fois fini).
	if [ "$statut" = "EN ATTENTE" ]; then
		_DETAILS=("${MSG[coulisses]}")
	else
		_tableau_details "$TABLEAU_SORTIES/$nom.sortie" "$_K"
	fi
	for ((i = 0; i < _K; i++)); do
		det="${_DETAILS[i]:-}"
		_tableau_ligne_detail "$det" "$statut" $((w - 4))
		printf -v remplir '%*s' $((w - 4 - _LD_LARG)) ''
		_CADRE_L+=("${c}│${_T_RAZ} ${_LD}${remplir} ${c}│${_T_RAZ}")
	done

	# Bordure basse avec l'onomatopee : ╰──────── Zoom ! ─╯
	remplir=$((w - 5 - ${#_BRUIT}))
	if [ "$remplir" -ge 1 ]; then
		printf -v ligne '%*s' "$remplir" ''
		_CADRE_L+=("${c}╰${ligne// /─} ${_T_GRAS}${_BRUIT}${_T_RAZ}${c} ─╯${_T_RAZ}")
	else
		printf -v ligne '%*s' $((w - 2)) ''
		_CADRE_L+=("${c}╰${ligne// /─}╯${_T_RAZ}")
	fi
}

# _tableau_dessiner [final] : image complete (en-tete + grille de cadres),
# construite dans une variable puis ecrite d'un bloc au meme endroit.
# La disposition ne depend que du NOMBRE de services et de la taille de
# la fenetre : l'image a toujours la meme hauteur, rien ne saute.
_tableau_dessiner() {
	local d="$TABLEAU_DOSSIER" rows cols n=${#TABLEAU_LIGNES[@]} nom i j r
	local finis=0 en_cours=0 maj=0 echecs=0 statut image ligne precedente
	local largeur_barre=24 pleins barre hauteur k
	local -a grille=()
	read -r rows cols < <(stty size </dev/tty 2>/dev/null)
	rows="${rows:-24}" cols="${cols:-100}"
	_SPIN="${_TABLEAU_SPIN[$((EPOCHSECONDS % ${#_TABLEAU_SPIN[@]}))]}"
	_tableau_disposition "$n" "$rows" "$cols"

	for nom in "${TABLEAU_LIGNES[@]}"; do
		if [ -f "$d/$nom.fin" ]; then
			finis=$((finis + 1))
			IFS='|' read -r statut _ <"$d/$nom.fin"
			case "$statut" in
			MAJ) maj=$((maj + 1)) ;;
			OK | INCHANGE | IGNORE) ;;
			*) echecs=$((echecs + 1)) ;;
			esac
		elif [ -f "$d/$nom.debut" ]; then
			en_cours=$((en_cours + 1))
		fi
	done

	image=""
	if [ -f "$d/.dessine" ]; then
		read -r precedente <"$d/.dessine"
		[ "${precedente:-0}" -gt 0 ] && image+=$'\033'"[${precedente}A"
	fi

	# En-tete : pastille titre, sous-titre, machine, barre arc-en-ciel,
	# compteurs, chrono.
	pleins=$((n > 0 ? finis * largeur_barre / n : 0))
	barre=""
	for ((i = 0; i < largeur_barre; i++)); do
		if [ "$i" -lt "$pleins" ]; then
			barre+="${_T_ARC[$((i % 6))]}█"
		else
			barre+="${_T_TERNE}░"
		fi
	done
	barre+="$_T_RAZ"
	_tableau_duree "$((EPOCHSECONDS - ${TABLEAU_DEBUT:-$EPOCHSECONDS}))"
	ligne=" ${_T_GRAS}${_T_INV}${_T_MAGENTA} ${_ICONE_STATUT[TITRE]} ACMECHANIC ${_T_RAZ}"
	# Etoiles : icone Font Awesome (U+F005) ; « ★ » Unicode n'existe pas
	# dans JetBrainsMono Nerd Font (carre vide a l'ecran).
	[ "$cols" -ge 120 ] && ligne+=" ${_T_ITAL}${_T_JAUNE}${_ICONE_STATUT[ETOILE]} ${MSG[sous_titre]} ${_ICONE_STATUT[ETOILE]}${_T_RAZ}"
	ligne+="  ${_T_CYAN}${_ICONE_STATUT[MACHINE]} ${HOSTNAME:-}${_T_RAZ}"
	ligne+="  ${barre} ${_T_GRAS}${finis}/${n}${_T_RAZ}"
	[ "$maj" -gt 0 ] && ligne+="  ${_T_VERT}${_ICONE_STATUT[MAJ]} ${maj}${_T_RAZ}"
	[ "$echecs" -gt 0 ] && ligne+="  ${_T_ROUGE}${_ICONE_STATUT[ECHEC]} ${echecs}${_T_RAZ}"
	ligne+="  ${_T_TERNE}${_ICONE_STATUT[HORLOGE]} ${_DUREE}${_T_RAZ}"
	image+=$'\033[2K'"$ligne"$'\n\033[2K\n'
	hauteur=2

	# Grille : les cadres d'une meme rangee sont colles ligne a ligne. Une
	# derniere rangee incomplete prend toute la largeur. Chaque ligne est
	# completee jusqu'a l'avant-derniere colonne : la derniere porte
	# l'ascenseur.
	local larg_base="$_LARG" m vis pad r0=-1 total vue debut hc=$((_K + 2)) curseur taille
	local -a toutes=()
	for ((r = 0; r < _NRANG; r++)); do
		grille=()
		m=$((n - r * _NCOL))
		[ "$m" -gt "$_NCOL" ] && m="$_NCOL"
		if [ "$m" -lt "$_NCOL" ]; then
			_LARG=$(((cols - 1 - (m - 1)) / m))
		else
			_LARG="$larg_base"
		fi
		for ((j = 0; j < m; j++)); do
			i=$((r * _NCOL + j))
			# Premiere rangee ou un service n'est pas fini : l'ascenseur
			# s'y place (les services finis, rapides, sont au-dessus).
			[ "$r0" -lt 0 ] && [ ! -f "$d/${TABLEAU_LIGNES[i]}.fin" ] && r0="$r"
			_tableau_cadre "${TABLEAU_LIGNES[i]}" "$i"
			for ((k = 0; k < ${#_CADRE_L[@]}; k++)); do
				grille[k]+="${grille[k]:+ }${_CADRE_L[k]}"
			done
		done
		vis=$((m * _LARG + m - 1))
		printf -v pad '%*s' $((cols - 1 - vis > 0 ? cols - 1 - vis : 0)) ''
		for ligne in "${grille[@]}"; do
			toutes+=("$ligne$pad")
		done
	done
	_LARG="$larg_base"

	# Fenetre (ascenseur) : tout ce qui tient, sinon a partir de la
	# premiere rangee encore au travail ; les rangees terminees sont
	# poussees vers le haut. Tout fini : les dernieres rangees.
	total=${#toutes[@]}
	vue=$((rows - 3))
	debut=0
	if [ "$total" -le "$vue" ]; then
		vue="$total"
	else
		[ "$r0" -lt 0 ] && r0="$_NRANG"
		debut=$((r0 * hc))
		[ "$debut" -gt $((total - vue)) ] && debut=$((total - vue))
		# Defilement manuel (molette, clavier) recent : il l'emporte.
		_DEFIL_AUTO="$debut" _DEFIL_VUE="$vue"
		if [ -n "${_DEFIL_MAN:-}" ] && [ $((EPOCHSECONDS - _DEFIL_T)) -lt "${ACMECHANIC_DEFIL_PAUSE:-20}" ]; then
			[ "$_DEFIL_MAN" -lt 0 ] && _DEFIL_MAN=0
			[ "$_DEFIL_MAN" -gt $((total - vue)) ] && _DEFIL_MAN=$((total - vue))
			debut="$_DEFIL_MAN"
		else
			_DEFIL_MAN=""
		fi
		taille=$((vue * vue / total))
		[ "$taille" -lt 1 ] && taille=1
		curseur=$((debut * vue / total))
	fi
	for ((k = 0; k < vue; k++)); do
		ligne="${toutes[debut + k]}"
		if [ "$total" -gt "$vue" ] || [ "$debut" -gt 0 ]; then
			if [ "$k" -ge "$curseur" ] && [ "$k" -lt $((curseur + taille)) ]; then
				ligne+="${_T_CYAN}┃${_T_RAZ}"
			else
				ligne+="${_T_TERNE}│${_T_RAZ}"
			fi
		fi
		image+=$'\033[2K'"$ligne"$'\n'
		hauteur=$((hauteur + 1))
	done
	image+=$'\033[J'
	printf '%s' "$image"
	echo "$hauteur" >"$d/.dessine"
}

# tableau_erreurs : les ERREUR collectees pendant le run, service par
# service (les actions a faire par l'utilisateur sont des points
# d'attention : point_attention, lib/common.sh).
tableau_erreurs() {
	local f nom niveau texte
	for f in "$TABLEAU_DOSSIER"/*.alertes; do
		[ -s "$f" ] || continue
		nom="$(basename "$f" .alertes)"
		while read -r niveau texte; do
			[ "$niveau" = ERREUR ] || continue
			printf '  %s%s%s %s%-14s%s %s\n' "$_T_ROUGE" "${_ICONE_STATUT[ERREUR]}" "$_T_RAZ" \
				"$_T_GRAS" "$nom" "$_T_RAZ" "$texte"
		done <"$f"
	done
}

# --- Ordre des cadres : du plus rapide au plus lent ---
# Les durees reelles de chaque service sont memorisees a la fin d'un run
# (tableau_memoriser_durees) ; au run suivant, les cadres sont ranges du
# plus rapide (en haut a gauche) au plus lent (en bas a droite), en ordre
# de lecture. Un service jamais mesure passe apres les autres. L'ordre est
# fige pour tout le run : les cadres ne bougent pas pendant l'affichage.

# tableau_ordonner <fichier_durees> <nom>... : noms tries (un par ligne).
tableau_ordonner() {
	local f="$1" nom d
	shift
	local -A duree=()
	if [ -r "$f" ]; then
		while read -r nom d; do [[ "$d" =~ ^[0-9]+$ ]] && duree[$nom]=$d; done <"$f"
	fi
	for nom in "$@"; do
		printf '%s %s\n' "${duree[$nom]:-999999}" "$nom"
	done | sort -s -n -k1,1 | cut -d' ' -f2
}

# tableau_memoriser_durees <fichier_durees> : durees reelles de ce run
# (fichiers .fin), fusionnees avec celles des services non lances.
tableau_memoriser_durees() {
	local f="$1" fin nom statut duree
	local -A duree_de=()
	if [ -r "$f" ]; then
		while read -r nom duree; do [ -n "$nom" ] && duree_de[$nom]="$duree"; done <"$f"
	fi
	for fin in "$TABLEAU_DOSSIER"/*.fin; do
		[ -f "$fin" ] || continue
		nom="$(basename "$fin" .fin)"
		IFS='|' read -r statut duree <"$fin"
		duree="${duree%s}"
		[[ "$duree" =~ ^[0-9]+$ ]] && duree_de[$nom]="$duree"
	done
	for nom in "${!duree_de[@]}"; do printf '%s %s\n' "$nom" "${duree_de[$nom]}"; done |
		sort >"$f.tmp" && mv "$f.tmp" "$f"
}

# tableau_bilan <etapes_ok> <etapes_ignorees> <etapes_echec> : bilan
# lisible. D'abord les SERVICES (un par cadre) selon leur statut final,
# puis le total des etapes de tous les services.
tableau_bilan() {
	local nom statut maj=0 inch=0 ok=0 ign=0 ech=0 txt
	local -a _SFX=(n 1) # suffixe de cle : _1 au singulier, _n sinon
	for nom in "${TABLEAU_LIGNES[@]}"; do
		statut=""
		[ -f "$TABLEAU_DOSSIER/$nom.fin" ] && IFS='|' read -r statut _ <"$TABLEAU_DOSSIER/$nom.fin"
		case "$statut" in
		MAJ) maj=$((maj + 1)) ;;
		INCHANGE) inch=$((inch + 1)) ;;
		OK) ok=$((ok + 1)) ;;
		IGNORE) ign=$((ign + 1)) ;;
		*) ech=$((ech + 1)) ;;
		esac
	done
	printf '\n %s%s%s ' "$_T_GRAS" "${MSG[titre_services]}" "$_T_RAZ"
	_pastille() { printf ' %s %s %s %s ' "$1" "$2" "$3" "$_T_RAZ"; }
	tv txt bilan_maj "$maj"
	_pastille $'\033[1;7;32m' "${_ICONE_STATUT[MAJ]}" "$txt"
	tv txt "bilan_inchange_${_SFX[inch == 1]}" "$inch"
	_pastille $'\033[7;36m' "${_ICONE_STATUT[INCHANGE]}" "$txt"
	if [ "$ok" -gt 0 ]; then
		tv txt "bilan_ok_${_SFX[ok == 1]}" "$ok"
		_pastille $'\033[7;32m' "${_ICONE_STATUT[OK]}" "$txt"
	fi
	if [ "$ign" -gt 0 ]; then
		tv txt "bilan_ignore_${_SFX[ign == 1]}" "$ign"
		_pastille $'\033[7;33m' "${_ICONE_STATUT[IGNORE]}" "$txt"
	fi
	tv txt bilan_echec "$ech"
	_pastille "$([ "$ech" -gt 0 ] && echo $'\033[1;7;91m' || echo $'\033[7;90m')" "${_ICONE_STATUT[ECHEC]}" "$txt"
	echo
	tv txt bilan_etapes "${1:-0}" "${2:-0}" "${3:-0}"
	printf ' %s%s%s\n' "$_T_TERNE" "$txt" "$_T_RAZ"
}

# _version_diff <avant> <apres> : decoupe deux versions en partie
# commune (_VC) et parties qui different (_VA, _VB), facon nala. La coupe
# se fait au debut du « mot » ou commence la difference (chiffres et
# lettres), en y incluant un « + » ou « ~ » de metadonnees de version :
#   v0.21.5+3851.g4569bb8 / v0.21.5+4533.g39faafb  ->  commun « v0.21.5 »
#   (build 2026-09-21) / (build 2026-09-28)        ->  differe « 21) » / « 28) »
_version_diff() {
	local a="$1" b="$2" p=0 n
	n=${#a}
	[ ${#b} -lt "$n" ] && n=${#b}
	while [ "$p" -lt "$n" ] && [ "${a:p:1}" = "${b:p:1}" ]; do p=$((p + 1)); done
	while [ "$p" -gt 0 ] && [[ "${a:p-1:1}" =~ [[:alnum:]] ]]; do p=$((p - 1)); done
	[ "$p" -gt 0 ] && [[ "${a:p-1:1}" == [+~] ]] && p=$((p - 1))
	_VC="${a:0:p}" _VA="${a:p}" _VB="${b:p}"
}

# tableau_versions <fichier_versions> : bloc « Versions » du bilan. Une
# version inchangee s'affiche une fois ; sinon avant -> apres, avec la
# seule partie qui change en couleur (rouge avant, vert apres). Trop
# long pour une ligne : la nouvelle version passe a la ligne.
tableau_versions() {
	local f="$1" service avant apres cols
	[ -s "$f" ] || return 0
	read -r _ cols < <(stty size </dev/tty 2>/dev/null)
	cols="${cols:-100}"
	printf "\n %s%s %s%s\n" "$_T_GRAS$_T_BLEU" "${_ICONE_STATUT[VERSIONS]}" "${MSG[titre_versions]}" "$_T_RAZ"
	while IFS="|" read -r service avant apres; do
		[ -n "$service" ] || continue
		_tableau_cadrer "$service" 14
		if [ "$avant" = "$apres" ]; then
			printf "  %s%s%s %s %s%s%s\n" "$_T_CYAN" "${_ICONE_STATUT[INCHANGE]}" "$_T_RAZ" \
				"$_CADRE" "$_T_TERNE" "${avant:0:$((cols - 22))}" "$_T_RAZ"
			continue
		fi
		_version_diff "$avant" "$apres"
		printf "  %s%s%s %s%s%s %s%s%s%s%s" "$_T_VERT" "${_ICONE_STATUT[MAJ]}" "$_T_RAZ" \
			"$_T_GRAS" "$_CADRE" "$_T_RAZ" "$_T_TERNE" "$_VC" "$_T_ROUGE" "$_VA" "$_T_RAZ"
		if [ $((22 + ${#avant} + 3 + ${#apres})) -gt "$cols" ]; then
			printf "\n  %18s" ""
		fi
		printf " %s%s %s%s%s%s%s\n" "$_T_VERT" "${_ICONE_STATUT[FLECHE]}" "$_T_TERNE" "$_VC" \
			"$_T_GRAS$_T_VERT" "$_VB" "$_T_RAZ"
	done <"$f"
}

# tableau_fin <code> : dernieres lignes (resultat, disque, sauvegardes).
tableau_fin() {
	local code="$1" libre usage taille anneaux="" i
	read -r libre usage < <(df -h "$HOME" | awk "NR==2 {print \$4, \$5}")
	taille="$(du -sh "$BACKUP_ROOT" 2>/dev/null | cut -f1)"
	echo
	if [ "$code" -eq 0 ]; then
		# Fermeture « a l'iris » facon dessin anime : anneaux colores
		# autour du message de fin.
		for i in 0 1 2; do anneaux+="${_T_ARC[i]}("; done
		printf ' %s %s%s %s %s' "$anneaux" "$_T_GRAS$_T_VERT" "${_ICONE_STATUT[OK]}" "${MSG[fin_ok]}" "$_T_RAZ"
		for i in 2 1 0; do printf '%s)' "${_T_ARC[i]}"; done
		printf '%s\n' "$_T_RAZ"
	else
		# shellcheck disable=SC2153 # ACMECHANIC_HOME : pose par acmechanic.sh
		printf ' %s%s %s%s  %s(%s)%s\n' "$_T_GRAS$_T_ROUGE" "${_ICONE_STATUT[ECHEC]}" \
			"$(t fin_echec "$code")" "$_T_RAZ" "$_T_TERNE" "$(t restauration "$ACMECHANIC_HOME/restore.sh")" "$_T_RAZ"
	fi
	printf ' %s%s %s   %s %s%s\n' "$_T_TERNE" \
		"${_ICONE_STATUT[DISQUE]}" "$(t disque "$libre" "$usage")" \
		"${_ICONE_STATUT[SAUVEGARDE]}" "$(t sauvegardes "$taille")" "$_T_RAZ"
}
