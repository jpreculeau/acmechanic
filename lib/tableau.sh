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
	_ICONE_SERVICE=(
		[docker]=$'\xef\x88\x9e' [flatpak]=$'\xef\x86\xb3' [media]=$'\xef\x80\x88'
		[sync]=$'\xef\x80\xa1' [agents]=$'\xef\x83\x90' [backup]=$'\xef\x86\x87'
		[systeme]=$'\xef\x8c\x95' [defaut]=$'\xef\x80\x93'
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
_T_ONOMATOPEES=("Zip !" "Zoom !" "Vroum !" "Bip bip !" "Hop hop !" "Boing !" "Wiizz !" "Tagada !")

# _tableau_style <statut> [indice] : fixe _COUL (cadre et titre),
# _LIBELLE, _ICONE et _BRUIT (onomatopee du bas de cadre).
_tableau_style() {
	local i="${2:-0}"
	case "$1" in
	"EN COURS")
		_COUL="${_T_ARC[$((i % ${#_T_ARC[@]}))]}" _LIBELLE="au travail" _ICONE="$_SPIN"
		_BRUIT="${_T_ONOMATOPEES[$(((EPOCHSECONDS / 2 + i) % ${#_T_ONOMATOPEES[@]}))]}" ;;
	MAJ) _COUL="$_T_VERT" _LIBELLE="mis à jour" _ICONE="${_ICONE_STATUT[MAJ]}" _BRUIT="Tadaa !" ;;
	OK) _COUL=$'\033[32m' _LIBELLE="ok" _ICONE="${_ICONE_STATUT[OK]}" _BRUIT="Nickel !" ;;
	INCHANGE) _COUL=$'\033[32m' _LIBELLE="inchangé" _ICONE="${_ICONE_STATUT[INCHANGE]}" _BRUIT="Nickel !" ;;
	IGNORE) _COUL="$_T_JAUNE" _LIBELLE="ignoré" _ICONE="${_ICONE_STATUT[IGNORE]}" _BRUIT="Pouf !" ;;
	"EN ATTENTE") _COUL="$_T_TERNE" _LIBELLE="en attente" _ICONE="${_ICONE_STATUT[ATTENTE]}" _BRUIT="Au suivant…" ;;
	TIMEOUT) _COUL="$_T_ROUGE" _LIBELLE="trop long" _ICONE="${_ICONE_STATUT[TIMEOUT]}" _BRUIT="Zzzz…" ;;
	*) _COUL="$_T_ROUGE" _LIBELLE="échec" _ICONE="${_ICONE_STATUT[ECHEC]}" _BRUIT="Patatras !" ;;
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
	_tableau_boucle </dev/null >/dev/tty 2>/dev/null 9>&- &
	TABLEAU_PID=$!
}

# tableau_arreter : arrete l'affichage, dessine l'etat final, rend le
# curseur. Sans effet si le tableau n'est pas actif (idempotent).
tableau_arreter() {
	[ -n "$TABLEAU_PID" ] || return 0
	kill -TERM "$TABLEAU_PID" 2>/dev/null
	wait "$TABLEAU_PID" 2>/dev/null
	TABLEAU_PID=""
	(_tableau_utf8 && _tableau_dessiner final) >/dev/tty 2>/dev/null
	printf '\033[?25h' >/dev/tty 2>/dev/null
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
	while [ -z "$fin" ]; do
		_tableau_dessiner
		sleep 0.5
	done
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
		"Reussies :"* | "Journal complet :"* | "--- Bilan"* | ETAPE* | "SERVICE "* | "MAINTENANCE "*) continue ;;
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
	_K=$(((rows - 3) / _NRANG - 2))
	[ "$_K" -lt 1 ] && _K=1
	[ "$_K" -gt 12 ] && _K=12
}

# tableau_possible <nb_lignes> : vrai si le tableau peut s'afficher.
tableau_possible() {
	local h w
	[ "${ACMECHANIC_TABLEAU:-oui}" = oui ] && [ -t 1 ] || return 1
	read -r h w < <(stty size </dev/tty 2>/dev/null) || return 1
	_tableau_disposition "$1" "${h:-0}" "${w:-0}"
	# Au moins une ligne de detail par cadre et 40 colonnes par cadre.
	[ $((3 + _NRANG * 3)) -le "${h:-0}" ] && [ "$_LARG" -ge 40 ]
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
		_DETAILS=("…patiente dans les coulisses")
	else
		_tableau_details "$TABLEAU_SORTIES/$nom.sortie" "$_K"
	fi
	for ((i = 0; i < _K; i++)); do
		det="${_DETAILS[i]:-}"
		det="${det:0:$((w - 4))}"
		printf -v remplir '%*s' $((w - 4 - ${#det})) ''
		if [ "$statut" = "EN ATTENTE" ]; then
			ligne="${_T_ITAL}${_T_TERNE}${det}${_T_RAZ}"
		elif [[ "$det" =~ ^([0-9]{2}:[0-9]{2}:[0-9]{2})\ (.*)$ ]]; then
			ligne="${_T_TERNE}${BASH_REMATCH[1]}${_T_RAZ} ${BASH_REMATCH[2]}"
		elif [[ "${det,,}" =~ (^|[^a-z])(error|erreur|failed|fatal)([^a-z]|$) ]]; then
			ligne="${_T_ROUGE}${det}${_T_RAZ}"
		else
			ligne="${_T_TERNE}${det}${_T_RAZ}"
		fi
		_CADRE_L+=("${c}│${_T_RAZ} ${ligne}${remplir} ${c}│${_T_RAZ}")
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
	[ "$cols" -ge 120 ] && ligne+=" ${_T_ITAL}${_T_JAUNE}${_ICONE_STATUT[ETOILE]} le grand show de la maintenance ${_ICONE_STATUT[ETOILE]}${_T_RAZ}"
	ligne+="  ${_T_CYAN}${_ICONE_STATUT[MACHINE]} ${HOSTNAME:-}${_T_RAZ}"
	ligne+="  ${barre} ${_T_GRAS}${finis}/${n}${_T_RAZ}"
	[ "$maj" -gt 0 ] && ligne+="  ${_T_VERT}${_ICONE_STATUT[MAJ]} ${maj}${_T_RAZ}"
	[ "$echecs" -gt 0 ] && ligne+="  ${_T_ROUGE}${_ICONE_STATUT[ECHEC]} ${echecs}${_T_RAZ}"
	ligne+="  ${_T_TERNE}${_ICONE_STATUT[HORLOGE]} ${_DUREE}${_T_RAZ}"
	image+=$'\033[2K'"$ligne"$'\n\033[2K\n'
	hauteur=2

	# Grille : les cadres d'une meme rangee sont colles ligne a ligne.
	for ((r = 0; r < _NRANG; r++)); do
		grille=()
		for ((j = 0; j < _NCOL; j++)); do
			i=$((r * _NCOL + j))
			[ "$i" -lt "$n" ] || break
			_tableau_cadre "${TABLEAU_LIGNES[i]}" "$i"
			for ((k = 0; k < ${#_CADRE_L[@]}; k++)); do
				grille[k]+="${grille[k]:+ }${_CADRE_L[k]}"
			done
		done
		for ligne in "${grille[@]}"; do
			image+=$'\033[2K'"$ligne"$'\n'
			hauteur=$((hauteur + 1))
		done
	done
	image+=$'\033[J'
	printf '%s' "$image"
	echo "$hauteur" >"$d/.dessine"
}

# tableau_alertes : liste les ATTENTION / ERREUR collectees pendant le
# run, service par service. Les etapes ignorees volontairement (deja
# comptees dans le bilan) ne sont pas repetees.
tableau_alertes() {
	local f nom niveau texte icone coul
	for f in "$TABLEAU_DOSSIER"/*.alertes; do
		[ -s "$f" ] || continue
		nom="$(basename "$f" .alertes)"
		while read -r niveau texte; do
			case "$texte" in *" -- ignore : "*) continue ;; esac
			if [ "$niveau" = ERREUR ]; then
				icone="${_ICONE_STATUT[ERREUR]}" coul="$_T_ROUGE"
			else
				icone="${_ICONE_STATUT[ATTENTION]}" coul="$_T_JAUNE"
			fi
			printf '  %s%s%s %s%-10s%s %s\n' "$coul" "$icone" "$_T_RAZ" \
				"$_T_GRAS" "$nom" "$_T_RAZ" "$texte"
		done <"$f"
	done
}

# tableau_versions <fichier_versions> : bloc « Versions » du bilan, en
# style tableau (icone, service, version ; en vert ce qui a change).
tableau_versions() {
	local f="$1" service avant apres cols
	[ -s "$f" ] || return 0
	read -r _ cols < <(stty size </dev/tty 2>/dev/null)
	cols="${cols:-100}"
	printf "\n %s%s Versions%s\n" "$_T_GRAS$_T_BLEU" "${_ICONE_STATUT[VERSIONS]}" "$_T_RAZ"
	while IFS="|" read -r service avant apres; do
		[ -n "$service" ] || continue
		_tableau_cadrer "$service" 14
		if [ "$avant" = "$apres" ]; then
			printf "  %s%s%s %s %s%s%s\n" "$_T_CYAN" "${_ICONE_STATUT[INCHANGE]}" "$_T_RAZ" \
				"$_CADRE" "$_T_TERNE" "${avant:0:$((cols - 22))}" "$_T_RAZ"
		else
			printf "  %s%s%s %s%s%s %s%s%s %s%s%s\n" "$_T_VERT" "${_ICONE_STATUT[MAJ]}" "$_T_RAZ" \
				"$_T_GRAS" "$_CADRE" "$_T_RAZ" "$_T_TERNE" "$avant" "$_T_RAZ" \
				"$_T_VERT${_ICONE_STATUT[FLECHE]} " "$apres" "$_T_RAZ"
		fi
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
		printf ' %s %s%s Rideau ! Tout est en ordre. %s' "$anneaux" "$_T_GRAS$_T_VERT" "${_ICONE_STATUT[OK]}" "$_T_RAZ"
		for i in 2 1 0; do printf '%s)' "${_T_ARC[i]}"; done
		printf '%s\n' "$_T_RAZ"
	else
		printf ' %s%s Patatras ! %s étape(s) en échec.%s  %s(restauration : %s/restore.sh)%s\n' \
			"$_T_GRAS$_T_ROUGE" "${_ICONE_STATUT[ECHEC]}" "$code" "$_T_RAZ" "$_T_TERNE" "$ACMECHANIC_HOME" "$_T_RAZ"
	fi
	printf ' %s%s %s libres (%s utilisés)   %s %s de sauvegardes%s\n' "$_T_TERNE" \
		"${_ICONE_STATUT[DISQUE]}" "$libre" "$usage" "${_ICONE_STATUT[SAUVEGARDE]}" "$taille" "$_T_RAZ"
}
