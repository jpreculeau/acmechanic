# shellcheck shell=bash
################################################################################
# xseed.sh - Liens physiques de cross-seed (xseed-links) et API qBittorrent.
#
# cross-seed (matchMode flexible, action "inject") cree des liens physiques
# sous <linkDir>/<tracker>/ : un meme inode, plusieurs noms. Ce module est
# partage par bibliotheque/cross-seed (controles, bilan) et
# bibliotheque/nettoyage (liens orphelins, en proposition seulement) ; un
# script maison peut appeler xseed_controler (voir en fin de fichier).
# Rien ici ne supprime quoi que ce soit.
#
# Reglages (surchargeables dans local.conf) :
#   CROSS_SEED_CONFIG    config.js de cross-seed, lu sur l'hote
#                        (defaut : <CROSS_SEED_DONNEES>/config/config.js)
#   CROSS_SEED_QBIT_URL  API qBittorrent vue de l'hote, identifiants compris :
#                        http://utilisateur:motdepasse@127.0.0.1:8080
#                        (defaut : celle de config.js, torrentClients)
#
# Dependances : curl ; jq pour les reponses JSON de qBittorrent.
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Jean-Philippe Reculeau — voir LICENSE
################################################################################

[ -n "${_XSEED_SH_LOADED:-}" ] && return 0
_XSEED_SH_LOADED=1

: "${CROSS_SEED_PROJET:=$HOME/cross-seed}"
: "${CROSS_SEED_DONNEES:=$CROSS_SEED_PROJET}"
: "${CROSS_SEED_CONFIG:=$CROSS_SEED_DONNEES/config/config.js}"
: "${CROSS_SEED_QBIT_URL:=}"
: "${CROSS_SEED_LIENS:=oui}"   # non = pas de controle des liens physiques

# --- config.js ---------------------------------------------------------------
# config_js_liste <fichier> <cle> : valeurs d'une liste de chaines du
# config.js (`cle: ["a", "b"]`, sur une ou plusieurs lignes), une par ligne.
# Une cle a valeur simple (`cle: "a"`) donne cette valeur. Les lignes en
# commentaire (`//`) sont ignorees : une cle commentee n'existe pas.
# Lecture textuelle, sans node : les valeurs calculees ne sont pas vues.
config_js_liste() {
	local fichier="$1" cle="$2"
	[ -r "$fichier" ] || return 1
	LC_ALL=C awk -v cle="$cle" -v q="'" '
		{ sub(/^[ \t]*\/\/.*/, ""); sub("//[^\"" q "]*$", "") }   # commentaires
		# Les crochets sont cherches hors des chaines : un nom de dossier
		# peut en contenir ("[01] Films").
		function hors_chaines(l) { gsub("\"[^\"]*\"|" q "[^" q "]*" q, "", l); return l }
		!lu && $0 ~ ("^[ \t]*" cle "[ \t]*:") {
			sub("^[ \t]*" cle "[ \t]*:", ""); lu = 1
			if (hors_chaines($0) !~ /\[/) { texte = $0; exit }   # valeur simple : une ligne
		}
		lu {
			texte = texte $0 "\n"
			if (hors_chaines($0) ~ /\]/) exit                  # fin de la liste
		}
		END {
			re = "\"[^\"]*\"|" q "[^" q "]*" q
			while (match(texte, re)) {
				print substr(texte, RSTART + 1, RLENGTH - 2)
				texte = substr(texte, RSTART + RLENGTH)
			}
		}' "$fichier"
}
# Seuls les chemins absolus sont retenus : cross-seed les exige, et un
# chemin relatif ou commencant par « - » serait pris pour une option.
xseed_liens_dossiers() { config_js_liste "$CROSS_SEED_CONFIG" linkDirs | LC_ALL=C grep '^/' || true; }
xseed_donnees_dossiers() { config_js_liste "$CROSS_SEED_CONFIG" dataDirs | LC_ALL=C grep '^/' || true; }

# --- qBittorrent (API WebUI v2) ---------------------------------------------
# qbit_url : URL de l'API avec identifiants : le reglage, sinon celle de
# config.js (torrentClients "qbittorrent:http://...", ou l'ancien
# qbittorrentUrl). Vide si inconnue.
qbit_url() {
	local u
	if [ -n "$CROSS_SEED_QBIT_URL" ]; then
		echo "$CROSS_SEED_QBIT_URL"
		return 0
	fi
	u="$(config_js_liste "$CROSS_SEED_CONFIG" torrentClients 2>/dev/null | LC_ALL=C sed -n 's/^qbittorrent://p' | premiere_ligne)"
	[ -n "$u" ] || u="$(config_js_liste "$CROSS_SEED_CONFIG" qbittorrentUrl 2>/dev/null | premiere_ligne)"
	echo "$u"
}

# _url_decoder : decode %XX (identifiants dans l'URL) ; une barre oblique
# inverse reste litterale (printf %b l'interpreterait).
_url_decoder() { local s="${1//\\/\\\\}"; printf '%b' "${s//%/\\x}"; }

# qbit_session <url> : ouvre une session sur l'API. Pose QBIT_BASE (URL sans
# identifiants, sans / final) et QBIT_COOKIE (fichier, supprime a la sortie).
# Codes : 0 ouverte (ou API accessible sans mot de passe) ; 1 identifiants
# refuses ; 2 injoignable (QBIT_HTTP : code HTTP, vide sans reponse) ; 3 URL
# vide ; 4 authentification requise mais aucun identifiant dans l'URL.
# L'API est d'abord essayee sans identifiants (reglage qBittorrent « pas
# d'authentification pour les clients sur localhost ») : le login ne sert
# que si elle refuse. Un refus est memorise (fichier QBIT_REFUS, avec
# l'empreinte de l'URL) : tant que l'URL n'a pas change, le login n'est pas
# retente, car qBittorrent bannit l'hote apres quelques echecs d'affilee, ce
# qui couperait aussi cross-seed. Seul un refus explicite (« Fails. ») est
# memorise : un bannissement en cours ou une erreur passagere ne l'est pas.
# Le mot de passe ne passe jamais en argument de processus (fichier
# temporaire, --data-urlencode @) ; il est percent-encode dans l'URL, comme
# dans config.js.
QBIT_BASE="" QBIT_COOKIE="" QBIT_REPONSE="" QBIT_IDENT=""
: "${QBIT_REFUS:=${XDG_CACHE_HOME:-$HOME/.cache}/acmechanic-qbit-refus}"
qbit_session() {
	local url="$1" ident="" utilisateur="" mdp="" reponse empreinte code
	[ -n "$url" ] || return 3
	# scheme://[ident@]hote[:port][/...] : ident = ce qui precede le dernier @ de l'autorite
	local autorite="${url#*://}" reste
	reste="${autorite#*/}"; [ "$reste" = "$autorite" ] && reste=""
	autorite="${autorite%%/*}"
	if [[ "$autorite" == *@* ]]; then
		ident="${autorite%@*}"; autorite="${autorite##*@}"
	fi
	QBIT_BASE="${url%%://*}://$autorite${reste:+/$reste}"
	QBIT_BASE="${QBIT_BASE%/}"
	# Fichiers temporaires (supprimes a la sortie) : cookie et reponse.
	# fichier_temp ne s'appelle pas dans $(...) : qbit_session non plus.
	[ -n "$QBIT_COOKIE" ] || fichier_temp QBIT_COOKIE || return 2
	[ -n "$QBIT_REPONSE" ] || fichier_temp QBIT_REPONSE || return 2
	[ -n "$QBIT_IDENT" ] || fichier_temp QBIT_IDENT || return 2
	: >"$QBIT_COOKIE"
	# Sans identifiants : l'API repond (200) ou refuse (403) ; injoignable sinon.
	if qbit_api 'app/version' >/dev/null; then
		rm -f -- "$QBIT_REFUS"
		return 0
	fi
	[ "$QBIT_HTTP" = 403 ] || return 2
	[ -n "$ident" ] || return 4
	empreinte="$(printf '%s' "$url" | cksum)"
	if [ -r "$QBIT_REFUS" ] && [ "$(cat "$QBIT_REFUS" 2>/dev/null)" = "$empreinte" ]; then
		return 1   # deja refuses avec cette URL : pas de nouvel essai (bannissement)
	fi
	utilisateur="$(_url_decoder "${ident%%:*}")"
	[[ "$ident" == *:* ]] && mdp="$(_url_decoder "${ident#*:}")"
	printf '%s' "$mdp" >"$QBIT_IDENT"
	reponse="$(curl -s -m 15 -c "$QBIT_COOKIE" --data-urlencode "username=$utilisateur" \
		--data-urlencode "password@$QBIT_IDENT" "$QBIT_BASE/api/v2/auth/login" 2>/dev/null)"
	code=$?
	: >"$QBIT_IDENT"
	[ $code -eq 0 ] || { QBIT_HTTP=""; return 2; }   # login sans reponse : pas le 403 de la sonde
	if [ "$reponse" = "Ok." ]; then
		rm -f -- "$QBIT_REFUS"
		return 0
	fi
	if [ "$reponse" = "Fails." ]; then
		mkdir -p -- "${QBIT_REFUS%/*}" 2>/dev/null
		(umask 077; printf '%s\n' "$empreinte" >"$QBIT_REFUS") 2>/dev/null
	fi
	return 1
}

# qbit_api <chemin> : GET api/v2/<chemin> avec la session ; rend 1 si la
# reponse n'est pas un 200 (403 : authentification requise ou refusee ;
# QBIT_HTTP garde le code, vide si injoignable).
QBIT_HTTP=""
qbit_api() {
	QBIT_HTTP=""
	[ -n "$QBIT_BASE" ] && [ -n "$QBIT_REPONSE" ] || return 1
	QBIT_HTTP="$(curl -s -m 60 -b "$QBIT_COOKIE" -o "$QBIT_REPONSE" -w '%{http_code}' \
		"$QBIT_BASE/api/v2/$1" 2>/dev/null)" || { QBIT_HTTP=""; return 1; }
	[ "$QBIT_HTTP" = 200 ] || return 1
	cat "$QBIT_REPONSE"
}

# qbit_chemins_contenus : content_path de tous les torrents, un par ligne
# (chemins sur l'hote, tels que qBittorrent les voit). jq requis.
qbit_chemins_contenus() {
	command -v jq >/dev/null 2>&1 || return 2
	qbit_api 'torrents/info' | jq -r '.[] | .content_path // empty' 2>/dev/null
}

# qbit_dossier_arrivee : dossier de telechargement par defaut (save_path).
qbit_dossier_arrivee() {
	command -v jq >/dev/null 2>&1 || return 2
	qbit_api 'app/preferences' | jq -r '.save_path // empty' 2>/dev/null
}

# --- Liens ---------------------------------------------------------------------
# xseed_liens_par_tracker <linkDir> : « <nombre de fichiers><TAB><tracker> »
# par sous-dossier de premier niveau, puis « <n><TAB>(racine) » s'il y a des
# fichiers a la racine.
xseed_liens_par_tracker() {
	local d="$1" t n
	[ -d "$d" ] || return 1
	while IFS= read -r -d '' t; do
		n="$(find "$t" -type f -printf . 2>/dev/null | wc -c)"
		printf '%s\t%s\n' "$n" "$(basename "$t")"
	done < <(find "$d" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null | sort -z)
	n="$(find "$d" -maxdepth 1 -type f -printf . 2>/dev/null | wc -c)"
	[ "$n" -gt 0 ] && printf '%s\t(racine)\n' "$n"
	return 0
}

# xseed_liens_orphelins <fichier contenus> <linkDir...> : fichiers des
# linkDirs qu'aucun torrent ne couvre (ni egal au content_path d'un torrent,
# ni dessous), un par ligne. <fichier contenus> : sortie de
# qbit_chemins_contenus. Chemins lus ligne par ligne : un chemin qui
# contient un saut de ligne arrive en fragments, dont le second ne commence
# pas par « / » ; un tel fragment est ecarte (jamais declare orphelin), le
# premier est compare comme un chemin ordinaire.
xseed_liens_orphelins() {
	local contenus="$1"; shift
	[ $# -gt 0 ] || return 0
	find "$@" -type f 2>/dev/null | LC_ALL=C awk -v contenus="$contenus" '
		BEGIN {
			while ((getline l <contenus) > 0) if (l ~ /^\//) { c[++n] = l }
			close(contenus)
		}
		$0 !~ /^\// { next }
		{
			for (i = 1; i <= n; i++) {
				if ($0 == c[i] || index($0, c[i] "/") == 1) next
			}
			print
		}'
}

# xseed_protege <chemin> : vrai si <chemin> est dans un dossier de liens de
# cross-seed : sous un linkDir de config.js, ou avec un composant
# « xseed-links » (nom conventionnel, meme sans config.js lisible). Aucune
# regle de menage ne supprime la : un nom de plus sur un inode ne coute
# rien, et le retirer casse le seed du tracker qui l'utilise.
# Les linkDirs sont lus une fois (cache _XSEED_LIENS, pour le config.js
# courant) : xseed_protege est appele pour chaque fichier a supprimer.
_XSEED_LIENS=() _XSEED_LIENS_CONFIG=""
xseed_protege() {
	local chemin="$1" l
	[[ "/$chemin/" == */xseed-links/* ]] && return 0
	if [ "$_XSEED_LIENS_CONFIG" != "$CROSS_SEED_CONFIG" ]; then
		mapfile -t _XSEED_LIENS < <(xseed_liens_dossiers 2>/dev/null)
		_XSEED_LIENS_CONFIG="$CROSS_SEED_CONFIG"
	fi
	for l in "${_XSEED_LIENS[@]}"; do
		l="${l%/}"
		[ "$chemin" = "$l" ] && return 0
		[[ "$chemin" == "$l"/* ]] && return 0
	done
	return 1
}

# xseed_monte_a_l_identique <conteneur> <chemin> : vrai si <chemin> est vu
# dans le conteneur au meme chemin que sur l'hote (un montage dont la
# source et la destination sont identiques le contient). Rend 2 si le
# conteneur ne peut pas etre inspecte (absent, Docker arrete).
xseed_monte_a_l_identique() {
	local conteneur="$1" chemin="$2" src dst montages
	montages="$(docker inspect --format '{{range .Mounts}}{{.Source}}{{"\t"}}{{.Destination}}{{"\n"}}{{end}}' \
		"$conteneur" 2>/dev/null)" || return 2
	while IFS=$'\t' read -r src dst; do
		[ -n "$dst" ] || continue
		[ "$src" = "$dst" ] || continue
		[ "$chemin" = "$dst" ] && return 0
		[[ "$chemin" == "${dst%/}"/* ]] && return 0
	done <<<"$montages"
	return 1
}

# xseed_controler <conteneur> : controles des liens physiques, a appeler
# avant la mise a jour du conteneur cross-seed :
#   1. chaque dataDir, et le dossier d'arrivee de qBittorrent, a un linkDir
#      sur le meme systeme de fichiers (sinon « hardlink impossible ») ;
#   2. ces chemins sont montes dans <conteneur> au meme chemin que sur l'hote ;
#   3. bilan : liens par tracker, liens orphelins.
# Tout ecart est un point d'attention, jamais un echec ; rien n'est supprime.
# Appele hors run_etape : ses points d'attention et ses lignes de bilan
# doivent rester dans ce shell (un sous-shell les perdrait).
xseed_controler() {
	local CONTENEUR="${1:-cross-seed}" libelle="cross-seed : liens physiques" fichier_contenus="" arrivee="" d l p trouve
	local -a liens donnees
	local qbit_ok=non
	if [ "$CROSS_SEED_LIENS" != oui ]; then
		ignorer_etape "$libelle" "desactive (CROSS_SEED_LIENS)"
		return 0
	fi
	if [ ! -r "$CROSS_SEED_CONFIG" ]; then
		ignorer_etape "$libelle" "config.js illisible : $CROSS_SEED_CONFIG (CROSS_SEED_CONFIG)"
		return 0
	fi
	mapfile -t liens < <(xseed_liens_dossiers)
	mapfile -t donnees < <(xseed_donnees_dossiers)
	if [ ${#liens[@]} -eq 0 ]; then
		log "cross-seed : pas de linkDirs dans config.js : liens physiques non utilises, rien a controler."
		return 0
	fi
	step "$libelle (${#liens[@]} linkDir)"

	# qBittorrent : dossier d'arrivee et contenus des torrents. Sans lui, les
	# controles qui en dependent sont sautes, les autres faits quand meme.
	local url code
	url="$(qbit_url)"
	qbit_session "$url"; code=$?
	case $code in
	0)
		if ! fichier_temp fichier_contenus || ! qbit_chemins_contenus >"$fichier_contenus"; then
			warn "cross-seed : API qBittorrent sans reponse exploitable ($QBIT_BASE : jq absent, ou acces refuse) : orphelins et dossier d'arrivee non controles."
		elif [ ! -s "$fichier_contenus" ]; then
			warn "cross-seed : aucun content_path renvoye par qBittorrent ($QBIT_BASE) : orphelins non controles."
		else
			qbit_ok=oui
			arrivee="$(qbit_dossier_arrivee)" || arrivee=""
			[ "$arrivee" != / ] && arrivee="${arrivee%/}"   # qBittorrent le donne souvent avec / final
		fi ;;
	1) warn "cross-seed : identifiants qBittorrent refuses ($QBIT_BASE ; refus memorise dans $QBIT_REFUS, a supprimer si le mot de passe a ete corrige cote qBittorrent) : orphelins et dossier d'arrivee non controles." ;;
	2) warn "cross-seed : qBittorrent injoignable ($QBIT_BASE, HTTP ${QBIT_HTTP:-aucune reponse}) : orphelins et dossier d'arrivee non controles." ;;
	4) warn "cross-seed : qBittorrent demande une authentification et l'URL n'a pas d'identifiants (CROSS_SEED_QBIT_URL) : orphelins et dossier d'arrivee non controles." ;;
	*) warn "cross-seed : URL de qBittorrent inconnue (torrentClients de config.js, ou CROSS_SEED_QBIT_URL) : orphelins et dossier d'arrivee non controles." ;;
	esac

	# Sources des liens : dataDirs et dossier d'arrivee, chacun une fois.
	local -A vu=()
	local -a sources=()
	for d in "${donnees[@]}" ${arrivee:+"$arrivee"}; do
		[ -n "${vu[$d]:-}" ] && continue
		vu[$d]=1; sources+=("$d")
	done

	# 1. Un linkDir sur le meme systeme de fichiers que chaque source.
	for l in "${liens[@]}"; do
		[ -d "$l" ] || point_attention "cross-seed : linkDir absent sur l'hote : $l (disque debranche, ou chemin du conteneur seulement ?)"
	done
	for d in "${sources[@]}"; do
		if [ ! -d "$d" ]; then
			point_attention "cross-seed : dossier absent sur l'hote : $d (dataDirs ou dossier d'arrivee de qBittorrent)"
			continue
		fi
		trouve=non
		for l in "${liens[@]}"; do
			[ -d "$l" ] && meme_fs "$d" "$l" && { trouve=oui; break; }
		done
		[ "$trouve" = oui ] ||
			point_attention "cross-seed : hardlink impossible pour $d : injection en echec (aucun linkDir sur le meme systeme de fichiers ; en ajouter un dans linkDirs)"
	done

	# 2. Memes chemins dans le conteneur que sur l'hote.
	local inspectable=oui
	for p in "${liens[@]}" "${sources[@]}"; do
		xseed_monte_a_l_identique "$CONTENEUR" "$p"; code=$?
		[ $code -eq 2 ] && { inspectable=non; break; }
		[ $code -eq 0 ] ||
			point_attention "cross-seed : $p n'est pas monte dans le conteneur au meme chemin que sur l'hote (volume <chemin>:<chemin> a ajouter au compose : les chemins viennent de qBittorrent)"
	done
	[ "$inspectable" = oui ] ||
		log "cross-seed : conteneur $CONTENEUR non inspectable (absent, ou Docker arrete) : montages non controles."

	# 3. Bilan : liens par tracker, orphelins.
	local tracker n total=0
	for l in "${liens[@]}"; do
		[ -d "$l" ] || continue
		while IFS=$'\t' read -r n tracker; do
			noter_bilan "cross-seed : liens $tracker" "$n"
			total=$((total + n))
		done < <(xseed_liens_par_tracker "$l")
	done
	if [ "$qbit_ok" = oui ]; then
		n="$(xseed_liens_orphelins "$fichier_contenus" "${liens[@]}" | wc -l)"
		if [ "$total" -gt 0 ] && [ "$n" -eq "$total" ]; then
			# Tous orphelins : qBittorrent ne voit sans doute pas les memes chemins que l'hote.
			point_attention "cross-seed : tous les liens ($total) sont orphelins : les chemins de qBittorrent ne sont pas ceux de l'hote ? (qBittorrent en conteneur, montages differents)"
		else
			noter_bilan "cross-seed : liens orphelins" "$n sur $total (aucun torrent qBittorrent ne pointe dessus ; menage propose par nettoyage)"
		fi
	fi
	ok "$libelle -- controles faits"
}
