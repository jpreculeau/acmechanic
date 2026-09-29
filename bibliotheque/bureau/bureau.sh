#!/usr/bin/env bash
# bureau.sh - Gestionnaire de fenetres et barre de menu.
#
#   Gestionnaire de fenetres (Hyprland, Sway, labwc, Wayfire, niri) :
#     installe par paquet -> mis a jour avec le systeme, version relevee ;
#     compile a la main (/usr/local) -> signale ; greffons Hyprland
#     (hyprpm) mis a jour s'il y en a.
#   Barre / outils installes par pip DEPUIS UN DEPOT GIT, avec vos
#   correctifs (branches) : BUREAU_PIP_GIT=(nwg-panel ...). Pour chacun :
#     1. derniere etiquette de l'amont (ou <NOM>_REF) ;
#     2. fusion de vos branches <NOM>_CORRECTIFS dans un dossier jetable
#        (git worktree) ; un conflit deja resolu une fois est rejoue par
#        git rerere ; un conflit nouveau -> point d'attention, rien ne change ;
#     3. copie de securite, pip install --user, verification, retour
#        arriere automatique en cas d'echec ;
#     4. la barre en cours tourne encore l'ancienne version : sa relance
#        est proposee (points d'attention / actions proposees).
#
# Installation : ln -s "$PWD/bibliotheque/bureau" services/bureau
#
# SPDX-License-Identifier: GPL-3.0-or-later

set -uo pipefail

SERVICE_NAME="bureau"
: "${ACMECHANIC_HOME:=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)}"
# shellcheck source=../../lib/service.sh
source "${ACMECHANIC_HOME}/lib/service.sh"

# --- Reglages (surchargeables dans local.conf) ---------------------------------
# Paquets pip installes depuis un depot git (ex. nwg-panel). Pour chacun :
#   <NOM>_SRC         clone git (remote « origin » = amont), obligatoire
#   <NOM>_CORRECTIFS  branches locales a fusionner (vos correctifs), tableau
#   <NOM>_REF         etiquette ou branche visee (defaut : derniere etiquette)
if [[ -z "${BUREAU_PIP_GIT+x}" ]]; then BUREAU_PIP_GIT=(); fi
: "${BUREAU_ETAT:=${XDG_STATE_HOME:-$HOME/.local/state}/acmechanic}"
# -------------------------------------------------------------------------------

titre "BUREAU : GESTIONNAIRE DE FENETRES ET BARRE"
mkdir -p "$BUREAU_ETAT"

# --- 1. Gestionnaire de fenetres -----------------------------------------------
# processus:paquet:commande
GESTIONNAIRES=(Hyprland:hyprland:Hyprland sway:sway:sway labwc:labwc:labwc
	wayfire:wayfire:wayfire niri:niri:niri)
TROUVE=non
for g in "${GESTIONNAIRES[@]}"; do
	IFS=: read -r proc paquet cmd <<<"$g"
	pgrep -x "$proc" >/dev/null 2>&1 || continue
	TROUVE=oui
	chemin="$(command -v "$cmd" 2>/dev/null)"
	version="$(dpkg-query -W -f='${Version}' "$paquet" 2>/dev/null)"
	if [ -n "$version" ] && [[ "$chemin" != /usr/local/* ]]; then
		inchanger_etape "$paquet" "paquet $version, mis a jour avec le systeme"
	else
		version="$(version_commande "$cmd" --version)"
		point_attention "$paquet : installe hors paquets ($chemin), mise a jour manuelle"
	fi
	enregistrer_version "$paquet" "$version" "$version"
	# Greffons Hyprland : a recompiler apres chaque mise a jour de Hyprland.
	if [ "$paquet" = hyprland ] && command -v hyprpm >/dev/null 2>&1 &&
		[ -n "$(ls -A "$HOME/.local/share/hyprpm" 2>/dev/null)" ]; then
		run_etape "hyprland : greffons (hyprpm)" 1800 hyprpm update
	fi
done
[ "$TROUVE" = oui ] || ignorer_etape "Gestionnaire de fenetres" "aucun gestionnaire connu en cours d'execution"

# --- 2. Paquets pip depuis git, avec correctifs --------------------------------
version_pip() { python3 -m pip show "$1" 2>/dev/null | sed -n 's/^Version: //p'; }

# relance_proposee <nom> : commande de relance de l'outil tel qu'il tourne.
relance_proposee() {
	local nom="$1" pid args
	pid="$(pgrep -f "bin/$nom( |\$)" | head -1)"
	[ -n "$pid" ] || return 0
	args="$(ps -o args= -p "$pid" | sed "s#^.*bin/$nom#$nom#")"
	point_attention "$nom : nouvelle version installee, celle en cours tourne encore l'ancienne" \
		"pkill -f 'bin/$nom( |\$)'; sleep 1; setsid -f $args >/dev/null 2>&1"
}

# restaurer <nom> <site> <sauvegarde> : remet la version d'avant.
restaurer() {
	local mod="${1//-/_}" site="$2" sauvegarde="$3"
	[ -s "$sauvegarde" ] || return 1
	rm -rf "${site:?}/$mod" "$site/$mod"-*.dist-info
	tar xzf "$sauvegarde" -C "$site"
}

maj_pip_git() {
	local nom="$1" v src ref empreinte ancienne avant apres arbre b sauvegarde site mod
	local -a correctifs=()
	v="$(tr 'a-z-' 'A-Z_' <<<"$nom")"
	mod="${nom//-/_}"
	local var_src="${v}_SRC" var_ref="${v}_REF"
	src="${!var_src:-}"
	if declare -p "${v}_CORRECTIFS" >/dev/null 2>&1; then
		eval "correctifs=(\"\${${v}_CORRECTIFS[@]}\")"
	fi
	if [ -z "$src" ] || ! git -C "$src" rev-parse --git-dir >/dev/null 2>&1; then
		ignorer_etape "$nom" "${var_src} n'est pas un clone git"
		return
	fi
	etape "$nom : recherche de nouveautes" 120 git -C "$src" fetch -q --tags origin || return
	ref="${!var_ref:-$(git -C "$src" tag --sort=-v:refname | grep -iE '^v?[0-9]' | head -1)}"
	[ -n "$ref" ] || { ignorer_etape "$nom" "aucune etiquette dans $src"; return; }

	# Empreinte = ce qui serait installe (amont + chaque correctif).
	empreinte="$(git -C "$src" rev-parse "$ref^{commit}")"
	for b in "${correctifs[@]}"; do
		empreinte+=" $(git -C "$src" rev-parse "$b" 2>/dev/null || echo "?$b")"
	done
	ancienne="$(cat "$BUREAU_ETAT/$nom.empreinte" 2>/dev/null)"
	avant="$(version_pip "$nom")"
	if [ "$empreinte" = "$ancienne" ]; then
		inchanger_etape "$nom" "a jour ($ref + ${#correctifs[@]} correctif(s))"
		enregistrer_version "$nom" "$avant" "$avant"
		return
	fi

	# Construction dans un dossier jetable.
	arbre="$(mktemp -u "${TMPDIR:-/tmp}/acmechanic-$nom-XXXXXX")"
	if ! git -C "$src" worktree add -q --detach "$arbre" "$ref"; then
		err "$nom : impossible d'extraire $ref"
		NB_ECHEC=$((NB_ECHEC + 1))
		return
	fi
	local g=(git -C "$arbre" -c user.name=acmechanic -c user.email=acmechanic@localhost
		-c rerere.enabled=true -c rerere.autoupdate=true)
	for b in "${correctifs[@]}"; do
		"${g[@]}" merge -q --no-edit "$b" >/dev/null 2>&1 && continue
		if [ -z "$(git -C "$arbre" diff --name-only --diff-filter=U)" ] && "${g[@]}" commit -q --no-edit; then
			log "$nom : conflit sur $b resolu par git rerere (resolution deja connue)"
			continue
		fi
		git -C "$arbre" merge --abort 2>/dev/null
		git -C "$src" worktree remove --force "$arbre"
		point_attention "$nom : le correctif $b ne s'applique plus sur $ref (conflit), version actuelle conservee" \
			"cd $src && git checkout --detach $ref && git merge $b"
		return
	done

	# Copie de securite de l'installation actuelle, pour le retour arriere.
	site="$(python3 -c 'import site; print(site.getusersitepackages())')"
	sauvegarde="$BUREAU_ETAT/$nom-avant.tar.gz"
	(cd "$site" && tar czf "$sauvegarde" "$mod" "$mod"-*.dist-info) 2>/dev/null

	if etape "$nom : installation ($ref + ${#correctifs[@]} correctif(s))" 900 \
		python3 -m pip install --user --break-system-packages --no-deps --force-reinstall \
		--quiet "$arbre" && python3 -c "import $mod" 2>/dev/null; then
		apres="$(version_pip "$nom")"
		echo "$empreinte" >"$BUREAU_ETAT/$nom.empreinte"
		NB_MAJ=$((NB_MAJ + 1))
		enregistrer_version "$nom" "$avant" "$apres"
		relance_proposee "$nom"
	else
		err "$nom : installation en echec, retour a la version precedente."
		restaurer "$nom" "$site" "$sauvegarde" || err "$nom : copie de securite absente ($sauvegarde)"
		point_attention "$nom : mise a jour vers $ref en echec, version $avant restauree (journal : $LOG_FILE)"
	fi
	git -C "$src" worktree remove --force "$arbre"
}

for nom in "${BUREAU_PIP_GIT[@]}"; do
	maj_pip_git "$nom"
done

bilan_service "Bilan du bureau"
exit $?
