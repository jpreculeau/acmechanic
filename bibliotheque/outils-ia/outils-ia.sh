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
#   Ollama        binaire : SIGNALE seulement (installeur officiel a
#                 lancer vous-meme) ; modeles : ollama pull si
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
		ignorer_etape "Hermes : mise a jour" "lance depuis Hermes : la session serait coupee (hermes update)"
	else
		maj_commande hermes hermes --version -- hermes update --yes
	fi
fi

# --- Ollama ----------------------------------------------------------------------
if present ollama; then
	TROUVE=oui
	locale="$(ollama --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
	derniere="$(curl -fsS --max-time 15 https://api.github.com/repos/ollama/ollama/releases/latest 2>/dev/null |
		grep -oE '"tag_name": *"v?[^"]+"' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
	if [ -z "$locale" ] || [ -z "$derniere" ]; then
		warn "Ollama : version locale ou publiee inconnue, comparaison impossible."
	elif [ "$locale" = "$derniere" ]; then
		inchanger_etape "Ollama" "a jour ($locale)"
	else
		warn "Ollama : $locale installee, $derniere publiee."
		warn "  A appliquer vous-meme : curl -fsSL https://ollama.com/install.sh | sh"
	fi
	enregistrer_version "ollama" "${locale:-?}" "${locale:-?}"
	if [ "$OLLAMA_MODELES_MAJ" = oui ]; then
		while read -r modele _; do
			[ -n "$modele" ] && run_etape "Ollama : modele $modele" 1800 ollama pull "$modele"
		done < <(ollama list 2>/dev/null | tail -n +2)
	fi
fi

[ "$TROUVE" = oui ] || ignorer_etape "Outils d'IA" "aucun outil detecte"

bilan_service "Bilan des outils d'IA"
exit $?
