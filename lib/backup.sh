#!/bin/bash
# backup.sh - Sauvegarde et restauration verifiables.
# Usage : source "${ACMECHANIC_HOME}/lib/backup.sh"  (necessite common.sh)
#
# Principe : chaque archive .tar.gz est accompagnee d'un fichier .manifest
# qui contient sa date, sa taille, son empreinte SHA-256 et la liste des
# dossiers sauvegardes. Sans manifeste valide, une archive est consideree
# comme douteuse et signalee comme telle a la restauration.

[ -n "${_BACKUP_SH_LOADED:-}" ] && return 0
_BACKUP_SH_LOADED=1

BACKUP_ROOT="${BACKUP_ROOT:-$HOME/backups}"
# Nombre d'archives conservees par service.
BACKUP_GARDER="${BACKUP_GARDER:-5}"

# creer_sauvegarde <service> <dossier_source> <element...>
#
# Cree BACKUP_ROOT/<service>/<service>_<horodatage>.tar.gz contenant les
# elements indiques, relatifs a <dossier_source>. Ecrit le manifeste,
# verifie l'integrite de l'archive, puis applique la rotation.
#
# Les exclusions sont lues dans la variable BACKUP_EXCLURE (tableau).
creer_sauvegarde() {
	local service="$1" source_dir="$2"
	shift 2
	local elements=("$@")

	if [ ${#elements[@]} -eq 0 ]; then
		err "creer_sauvegarde : aucun element a sauvegarder pour $service"
		return 1
	fi
	if [ ! -d "$source_dir" ]; then
		err "creer_sauvegarde : dossier source introuvable : $source_dir"
		return 1
	fi

	local dest="$BACKUP_ROOT/$service"
	mkdir -p "$dest" || return 1

	# Verifie que les elements existent vraiment avant de lancer tar,
	# sinon tar echoue a mi-parcours et laisse une archive tronquee.
	local presents=() absents=() el
	for el in "${elements[@]}"; do
		if [ -e "$source_dir/$el" ]; then
			presents+=("$el")
		else
			absents+=("$el")
		fi
	done
	if [ ${#absents[@]} -gt 0 ]; then
		warn "Elements absents, ignores : ${absents[*]}"
	fi
	if [ ${#presents[@]} -eq 0 ]; then
		err "Aucun element existant a sauvegarder dans $source_dir"
		return 1
	fi

	local horodatage archive manifeste
	horodatage="$(date +%Y-%m-%d_%H-%M-%S)"
	archive="$dest/${service}_${horodatage}.tar.gz"
	manifeste="${archive%.tar.gz}.manifest"

	# Construction des options d'exclusion.
	local opts_exclusion=() motif
	for motif in "${BACKUP_EXCLURE[@]:-}"; do
		[ -n "$motif" ] && opts_exclusion+=("--exclude=$motif")
	done

	log "Sauvegarde de $service : ${presents[*]}"
	[ ${#opts_exclusion[@]} -gt 0 ] && log "Exclusions : ${BACKUP_EXCLURE[*]}"

	# --ignore-failed-read evite qu'un fichier verrouille fasse tout echouer,
	# mais on controle quand meme le code de sortie ensuite.
	# TAR_CMD permet de forcer sudo pour les dossiers appartenant a root
	# (ex. /srv/app/config) : on le prefixe uniquement a la creation,
	# pas a la verification (l'archive reste lisible par l'utilisateur).
	# tar+gzip est le seul vrai consommateur CPU de la maintenance
	# (plusieurs centaines de Mo de base SQLite, par exemple, sur un seul
	# coeur). En priorite basse CPU et IO, il ne rend plus le bureau
	# saccade ; la duree change a peine puisque la compression est
	# limitee par un coeur, pas par la concurrence.
	local prio=(nice -n 10)
	command -v ionice >/dev/null 2>&1 && prio+=(ionice -c2 -n7)
	# TAR_CMD peut contenir plusieurs mots (« sudo tar ») : tableau.
	local tar_cmd
	read -ra tar_cmd <<<"${TAR_CMD:-tar}"
	if ! "${prio[@]}" "${tar_cmd[@]}" czf "$archive" \
		"${opts_exclusion[@]}" \
		--ignore-failed-read \
		-C "$source_dir" "${presents[@]}" 2>>"$LOG_FILE"; then
		err "Echec de la creation de l'archive $archive (details dans $LOG_FILE)"
		rm -f "$archive"
		return 1
	fi

	# Controle d'integrite : on relit l'archive entierement.
	if ! tar tzf "$archive" >/dev/null 2>&1; then
		err "Archive corrompue apres creation, suppression : $archive"
		rm -f "$archive"
		return 1
	fi

	local taille empreinte nb_fichiers
	taille="$(du -h "$archive" | cut -f1)"
	empreinte="$(sha256sum "$archive" | cut -d' ' -f1)"
	nb_fichiers="$(tar tzf "$archive" | wc -l)"

	{
		echo "service=$service"
		echo "date=$(date +'%Y-%m-%d %H:%M:%S')"
		echo "archive=$(basename "$archive")"
		echo "source=$source_dir"
		echo "elements=${presents[*]}"
		echo "exclusions=${BACKUP_EXCLURE[*]:-aucune}"
		echo "taille=$taille"
		echo "fichiers=$nb_fichiers"
		echo "sha256=$empreinte"
	} >"$manifeste"

	ok "Sauvegarde creee : $(basename "$archive") ($taille, $nb_fichiers fichiers)"

	rotation_sauvegardes "$service"
	return 0
}

# rotation_sauvegardes <service>
#
# Conserve les BACKUP_GARDER archives les plus recentes et supprime les
# autres, avec leur manifeste. Utilise un tableau bash plutot qu'un
# pipeline find|sort|tail : mixer des separateurs NUL avec tail casse
# silencieusement le comptage.
rotation_sauvegardes() {
	local service="$1"
	local dest="$BACKUP_ROOT/$service"
	[ -d "$dest" ] || return 0

	local archives=()
	local f
	# Tri par date de modification, du plus recent au plus ancien.
	while IFS= read -r f; do
		[ -n "$f" ] && archives+=("$f")
	done < <(find "$dest" -maxdepth 1 -name "${service}_*.tar.gz" -type f -printf '%T@ %p\n' 2>/dev/null |
		sort -rn | cut -d' ' -f2-)

	local total=${#archives[@]}
	if [ "$total" -le "$BACKUP_GARDER" ]; then
		log "Rotation : $total archive(s) conservee(s) sur $BACKUP_GARDER autorisee(s)"
		return 0
	fi

	local i supprimees=0
	for ((i = BACKUP_GARDER; i < total; i++)); do
		rm -f "${archives[i]}" "${archives[i]%.tar.gz}.manifest"
		log "Rotation : ancienne archive supprimee -- $(basename "${archives[i]}")"
		supprimees=$((supprimees + 1))
	done
	ok "Rotation : $supprimees archive(s) supprimee(s), $BACKUP_GARDER conservee(s)"
	return 0
}

# lister_sauvegardes <service>
# Affiche les archives disponibles, numerotees, avec les infos du manifeste.
lister_sauvegardes() {
	local service="$1"
	local dest="$BACKUP_ROOT/$service"
	if [ ! -d "$dest" ]; then
		err "Aucune sauvegarde pour '$service' (dossier $dest inexistant)"
		return 1
	fi

	local archives=() f
	while IFS= read -r f; do
		[ -n "$f" ] && archives+=("$f")
	done < <(find "$dest" -maxdepth 1 -name "${service}_*.tar.gz" -type f -printf '%T@ %p\n' 2>/dev/null |
		sort -rn | cut -d' ' -f2-)

	if [ ${#archives[@]} -eq 0 ]; then
		err "Aucune archive trouvee pour '$service' dans $dest"
		return 1
	fi

	printf '%s%-4s %-38s %-8s %-10s %s%s\n' "$C_BOLD" "N°" "ARCHIVE" "TAILLE" "FICHIERS" "INTEGRITE" "$C_OFF"
	printf '%s\n' "---------------------------------------------------------------------------------"
	local i manifeste taille nb etat
	for i in "${!archives[@]}"; do
		manifeste="${archives[i]%.tar.gz}.manifest"
		if [ -f "$manifeste" ]; then
			taille="$(grep '^taille=' "$manifeste" | cut -d= -f2)"
			nb="$(grep '^fichiers=' "$manifeste" | cut -d= -f2)"
			etat="manifeste present"
		else
			taille="$(du -h "${archives[i]}" | cut -f1)"
			nb="?"
			etat="${C_YELLOW}sans manifeste${C_OFF}"
		fi
		printf '%-4s %-38s %-8s %-10s %b\n' \
			"$((i + 1))" "$(basename "${archives[i]}")" "$taille" "$nb" "$etat"
	done
	printf '%s\n' "---------------------------------------------------------------------------------"
	# Rend la liste exploitable par l'appelant.
	ARCHIVES_TROUVEES=("${archives[@]}")
	return 0
}

# verifier_sauvegarde <chemin_archive>
# Compare l'empreinte SHA-256 de l'archive a celle du manifeste et relit
# l'archive de bout en bout.
verifier_sauvegarde() {
	local archive="$1"
	local manifeste="${archive%.tar.gz}.manifest"

	if [ ! -f "$archive" ]; then
		err "Archive introuvable : $archive"
		return 1
	fi

	log "Verification de la lisibilite de l'archive..."
	if ! tar tzf "$archive" >/dev/null 2>&1; then
		err "Archive illisible ou corrompue : $archive"
		return 1
	fi
	ok "Archive lisible de bout en bout"

	if [ ! -f "$manifeste" ]; then
		warn "Pas de manifeste pour cette archive : empreinte non verifiable"
		return 0
	fi

	local attendue obtenue
	attendue="$(grep '^sha256=' "$manifeste" | cut -d= -f2)"
	log "Calcul de l'empreinte SHA-256 (peut prendre un moment)..."
	obtenue="$(sha256sum "$archive" | cut -d' ' -f1)"
	if [ "$attendue" = "$obtenue" ]; then
		ok "Empreinte SHA-256 conforme au manifeste"
		return 0
	fi
	err "Empreinte differente du manifeste : archive alteree"
	err "  attendue : $attendue"
	err "  obtenue  : $obtenue"
	return 1
}

# restaurer_sauvegarde <chemin_archive> <dossier_cible>
#
# Extrait l'archive dans le dossier cible. Avant d'ecraser quoi que ce
# soit, deplace l'etat actuel dans un dossier .avant-restauration-<date>
# afin que l'operation reste annulable.
restaurer_sauvegarde() {
	local archive="$1" cible="$2"

	verifier_sauvegarde "$archive" || return 1

	if [ ! -d "$cible" ]; then
		err "Dossier cible introuvable : $cible"
		return 1
	fi

	# Elements presents dans l'archive, au premier niveau.
	local elements=() el
	while IFS= read -r el; do
		[ -n "$el" ] && elements+=("$el")
	done < <(tar tzf "$archive" | cut -d/ -f1 | sort -u)

	log "L'archive contient : ${elements[*]}"

	local filet
	filet="$cible/.avant-restauration-$(date +%Y-%m-%d_%H-%M-%S)"
	mkdir -p "$filet" || return 1

	for el in "${elements[@]}"; do
		if [ -e "$cible/$el" ]; then
			mv "$cible/$el" "$filet/" || {
				err "Impossible de mettre de cote $cible/$el, restauration annulee"
				return 1
			}
			log "Etat actuel mis de cote : $el -> $(basename "$filet")/"
		fi
	done

	log "Extraction de l'archive vers $cible ..."
	if ! tar xzf "$archive" -C "$cible" 2>>"$LOG_FILE"; then
		err "Echec de l'extraction. Retour a l'etat precedent..."
		for el in "${elements[@]}"; do
			rm -rf "${cible:?}/${el:?}"
			[ -e "$filet/$el" ] && mv "$filet/$el" "$cible/"
		done
		err "Etat precedent restaure. Rien n'a ete perdu."
		return 1
	fi

	ok "Restauration terminee dans $cible"
	log "L'etat precedent reste disponible ici : $filet"
	log "Supprimez-le vous-meme une fois le bon fonctionnement confirme."
	return 0
}
