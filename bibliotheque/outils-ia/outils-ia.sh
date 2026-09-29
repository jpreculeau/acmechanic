#!/usr/bin/env bash
# outils-ia.sh - Mise a jour des outils d'IA en ligne de commande.
#
# Chaque outil n'est traite que s'il est installe :
#   Claude Code   claude update
#   CLI npm       IA_NPM (ex. @openai/codex, @google/gemini-cli)
#   uv / pipx     outils Python (aider, llm...) : upgrade --all
#   pi.dev        pi update (+ extensions), configuration sauvegardee
#   Hermes        hermes update, configuration sauvegardee ; jamais
#                 depuis une session Hermes (elle serait coupee)
#   Ollama        binaire : installeur officiel (sudo) si OLLAMA_MAJ=oui,
#                 sinon signale ; l'etat du service (arrete, desactive)
#                 est remis comme avant ; echec -> reinstallation de la
#                 version precedente. Modeles : ollama pull si
#                 OLLAMA_MODELES_MAJ=oui (volumineux, desactive par defaut)
#
# Interface web (Open WebUI) : voir bibliotheque/open-webui.
# Installation : ln -s "$PWD/bibliotheque/outils-ia" services/outils-ia
#
# SPDX-License-Identifier: GPL-3.0-or-later

set -uo pipefail

SERVICE_NAME="outils-ia"
: "${ACMECHANIC_HOME:=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)}"
# shellcheck source=../../lib/service.sh
source "${ACMECHANIC_HOME}/lib/service.sh"

# --- Reglages (surchargeables dans local.conf) ---------------------------------
if [[ -z "${IA_NPM+x}" ]]; then IA_NPM=(@openai/codex @google/gemini-cli); fi
# Outils consideres (retirez-en pour les ignorer).
: "${IA_OUTILS:=claude npm uv pipx pi hermes ollama}"
: "${OLLAMA_MAJ:=signaler}"        # oui = installer la nouvelle version (sudo)
: "${OLLAMA_MODELES_MAJ:=non}"
: "${HERMES_HOME:=$HOME/.hermes}"
# -------------------------------------------------------------------------------

titre "OUTILS D'IA"
# present <outil> : retenu dans IA_OUTILS ET installe.
present() { [[ " $IA_OUTILS " == *" $1 "* ]] && command -v "$1" >/dev/null 2>&1; }
TROUVE=non

# maj_commande <nom> <version...> -- <commande de mise a jour...>
# Version avant/apres, mise a jour, comptage.
maj_commande() {
	local nom="$1" v=() avant apres
	shift
	while [ "$1" != "--" ]; do v+=("$1"); shift; done
	shift
	avant="$(version_commande "${v[@]}")"
	etape "$nom : mise a jour" 1800 "$@" || return
	apres="$(version_commande "${v[@]}")"
	enregistrer_version "$nom" "$avant" "$apres"
	[ "$avant" != "$apres" ] && NB_MAJ=$((NB_MAJ + 1))
	return 0
}

# --- Claude Code -----------------------------------------------------------------
if present claude; then
	TROUVE=oui
	maj_commande claude claude --version -- claude update
fi

# --- CLI npm ---------------------------------------------------------------------
version_npm() {
	npm ls -g --depth=0 --json "$1" 2>/dev/null |
		grep -oE '"version": *"[^"]+"' | head -1 | cut -d'"' -f4
}
if present npm && [ ${#IA_NPM[@]} -gt 0 ]; then
	prefixe="$(npm prefix -g 2>/dev/null)"
	npm_cmd=(npm)
	if [ -n "$prefixe" ] && [ ! -w "$prefixe/lib/node_modules" ]; then
		if sudo_disponible; then npm_cmd=(sudo -n npm); else npm_cmd=(); fi
	fi
	installes="$(npm ls -g --depth=0 --parseable 2>/dev/null)"
	for paquet in "${IA_NPM[@]}"; do
		grep -q "/node_modules/$paquet\$" <<<"$installes" || continue
		TROUVE=oui
		if [ ${#npm_cmd[@]} -eq 0 ]; then
			ignorer_etape "$paquet" "prefixe npm global non inscriptible et sudo indisponible"
			continue
		fi
		maj_commande "$paquet" version_npm "$paquet" -- \
			"${npm_cmd[@]}" install -g --no-fund --no-audit "$paquet@latest"
	done
fi

# --- Outils Python ---------------------------------------------------------------
if present uv && uv tool list 2>/dev/null | grep -qv '^-'; then
	TROUVE=oui
	run_etape "uv : outils Python" 1800 uv tool upgrade --all
fi
if present pipx && [ -n "$(pipx list --short 2>/dev/null)" ]; then
	TROUVE=oui
	run_etape "pipx : outils Python" 1800 pipx upgrade-all
fi

# --- pi.dev ----------------------------------------------------------------------
if present pi && [ -d "$HOME/.pi" ]; then
	TROUVE=oui
	BACKUP_EXCLURE=('*/sessions' '*/node_modules' '*/bin')
	run_etape "pi.dev : sauvegarde de la configuration" 600 \
		creer_sauvegarde pi "$HOME/.pi" agent
	maj_commande pi pi --version -- pi update
	run_etape "pi.dev : mise a jour des extensions" 1800 pi update --extensions
fi

# --- Hermes ----------------------------------------------------------------------
if present hermes; then
	TROUVE=oui
	if [ -d "$HERMES_HOME" ]; then
		BACKUP_EXCLURE=('*/hermes-agent' '*/logs' '*/sessions' '*/cache' '*/state.db*' '*/node_modules')
		elements=()
		for el in config.yaml .env skills skins plugins memories cron auth.json; do
			[ -e "$HERMES_HOME/$el" ] && elements+=("$el")
		done
		[ ${#elements[@]} -gt 0 ] &&
			run_etape "Hermes : sauvegarde de la configuration" 900 \
				creer_sauvegarde hermes "$HERMES_HOME" "${elements[@]}"
	fi
	if ! timeout 120 hermes update --check 2>&1 | grep -qiE 'update available|behind'; then
		inchanger_etape "Hermes" "deja a jour"
	elif [ -n "${HERMES_SESSION_ID:-}${HERMES_AGENT:-}" ]; then
		ignorer_etape "Hermes : mise a jour" "lance depuis Hermes : la session serait coupee"
		point_attention "Hermes : mise a jour disponible, non appliquee depuis une session Hermes" "hermes update"
	else
		maj_commande hermes hermes --version -- hermes update --yes
	fi
fi

# --- Ollama ----------------------------------------------------------------------
# maj_ollama <locale> <derniere> : installeur officiel, version fixee
# (OLLAMA_VERSION). Il active et demarre le service : on remet son etat
# d'avant (un service arrete expres pour liberer la RAM le reste).
installer_ollama() {  # installer_ollama <script> <version>
	sudo -n env OLLAMA_VERSION="$2" sh "$1"
}
maj_ollama() {
	local locale="$1" derniere="$2" actif activee script apres
	actif="$(systemctl is-active ollama 2>/dev/null)"
	activee="$(systemctl is-enabled ollama 2>/dev/null)"
	fichier_temp script "${TMPDIR:-/tmp}/ollama-install-XXXXXX"
	etape "Ollama : installeur officiel" 120 curl -fsSL -o "$script" https://ollama.com/install.sh || return 0
	if ! etape "Ollama : $locale -> $derniere" 1800 installer_ollama "$script" "$derniere"; then
		warn "Ollama : echec, reinstallation de $locale."
		run_etape "Ollama : retour a $locale" 1800 installer_ollama "$script" "$locale"
	fi
	if systemctl cat ollama >/dev/null 2>&1; then
		[ "$activee" = disabled ] && sudo -n systemctl disable ollama >/dev/null 2>&1
		[ "$actif" != active ] && sudo -n systemctl stop ollama >/dev/null 2>&1
		log "Ollama : service remis dans son etat d'avant ($actif, $activee)."
	fi
	apres="$(ollama --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
	enregistrer_version "ollama" "$locale" "${apres:-?}"
	if [ "$apres" = "$derniere" ]; then
		NB_MAJ=$((NB_MAJ + 1))
	else
		err "Ollama : version ${apres:-?} apres installation (attendue : $derniere)."
		NB_ECHEC=$((NB_ECHEC + 1))
	fi
}

if present ollama; then
	TROUVE=oui
	locale="$(ollama --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
	derniere="$(curl -fsS --max-time 15 https://api.github.com/repos/ollama/ollama/releases/latest 2>/dev/null |
		grep -oE '"tag_name": *"v?[^"]+"' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
	if [ -z "$locale" ] || [ -z "$derniere" ]; then
		warn "Ollama : version locale ou publiee inconnue, comparaison impossible."
		enregistrer_version "ollama" "${locale:-?}" "${locale:-?}"
	elif [ "$locale" = "$derniere" ]; then
		inchanger_etape "Ollama" "a jour ($locale)"
		enregistrer_version "ollama" "$locale" "$locale"
	elif [ "$OLLAMA_MAJ" != oui ]; then
		point_attention "Ollama : $locale installee, $derniere publiee (OLLAMA_MAJ=oui pour l'appliquer)" \
			"curl -fsSL https://ollama.com/install.sh | OLLAMA_VERSION=$derniere sh"
		enregistrer_version "ollama" "$locale" "$locale"
	elif ! sudo_disponible; then
		ignorer_etape "Ollama : mise a jour" "sudo indisponible sans mot de passe"
		point_attention "Ollama : $locale installee, $derniere publiee" \
			"curl -fsSL https://ollama.com/install.sh | OLLAMA_VERSION=$derniere sh"
	else
		maj_ollama "$locale" "$derniere"
	fi
	if [ "$OLLAMA_MODELES_MAJ" = oui ] && ! ollama list >/dev/null 2>&1; then
		ignorer_etape "Ollama : modeles" "serveur Ollama arrete"
	elif [ "$OLLAMA_MODELES_MAJ" = oui ]; then
		while read -r modele _; do
			[ -n "$modele" ] && run_etape "Ollama : modele $modele" 1800 ollama pull "$modele"
		done < <(ollama list 2>/dev/null | tail -n +2)
	fi
fi

[ "$TROUVE" = oui ] || ignorer_etape "Outils d'IA" "aucun outil detecte"

bilan_service "Bilan des outils d'IA"
exit $?
