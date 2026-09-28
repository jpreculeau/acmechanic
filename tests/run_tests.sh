#!/usr/bin/env bash
# Tests unitaires Acmechanic — sans root, sans Docker, sans reseau.
# Usage : tests/run_tests.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0 FAIL=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

check() {  # check "description" commande...
	local desc="$1"; shift
	if "$@"; then PASS=$((PASS + 1)); printf '  ok   %s\n' "$desc"
	else FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$desc"; fi
}
not() { ! "$@"; }
eq() { [[ "$1" == "$2" ]] || { printf '       attendu [%s] obtenu [%s]\n' "$2" "$1"; return 1; }; }

export LC_ALL=C.UTF-8 NO_COLOR=1 ACMECHANIC_TABLEAU=non LIMITES_RESSOURCES=non
export LOG_DIR="$TMP/logs" BACKUP_ROOT="$TMP/backups" CACHE_REGISTRE_DIR="$TMP/cache"
export ACMECHANIC_HOME="$ROOT"

echo "syntaxe"
for f in "$ROOT"/acmechanic.sh "$ROOT"/restore.sh "$ROOT"/config.sh "$ROOT"/lib/*.sh \
	"$ROOT"/examples/services/*/*.sh; do
	check "bash -n ${f#"$ROOT"/}" bash -n "$f"
done

echo "options"
check "--version" eq "$("$ROOT/acmechanic.sh" --version)" "acmechanic 1.0.0"
check "--aide mentionne --liste" grep -q -- '--liste' <("$ROOT/acmechanic.sh" --aide)
check "option inconnue => code 1" not bash -c '"$1" --nimportequoi >/dev/null 2>&1' _ "$ROOT/acmechanic.sh"

echo "decouverte des services"
S="$TMP/services"
mkdir -p "$S/alpha" "$S/beta" "$S/gamma"
printf '#!/bin/bash\nsource "${ACMECHANIC_HOME}/lib/common.sh"\n' >"$S/alpha/alpha.sh"
printf '#!/bin/bash\necho outil\n' >"$S/beta/beta.sh"
printf '#!/bin/bash\nsource "${ACMECHANIC_HOME}/lib/common.sh"\n' >"$S/gamma/autre.sh"
chmod +x "$S"/*/*.sh
liste="$(SERVICES_DIR="$S" ORDRE_DIR="$TMP/ordre" "$ROOT/acmechanic.sh" --liste 2>&1)"
check "service qui source lib/common.sh detecte" grep -qE 'alpha +detecte automatiquement' <<<"$liste"
check "script sans lib/common.sh ecarte" grep -qE '^ +beta +' <<<"$liste"
check "script mal nomme ignore" not grep -q 'autre' <<<"$liste"
mkdir -p "$TMP/ordre"
ln -s "$S/alpha/alpha.sh" "$TMP/ordre/10-alpha.sh"
liste="$(SERVICES_DIR="$S" ORDRE_DIR="$TMP/ordre" "$ROOT/acmechanic.sh" --liste 2>&1)"
check "lien numerote : ordre impose" grep -qE 'alpha +ordre impose' <<<"$liste"

echo "configuration"
mkdir -p "$TMP/home"
cp "$ROOT/config.sh" "$TMP/home/"
echo 'DELAI_SERVICE=42; SERVICES_CONNUS=(demo)' >"$TMP/home/local.conf"
val="$(env -u BACKUP_ROOT ACMECHANIC_HOME="$TMP/home" bash -c \
	'source "$ACMECHANIC_HOME/config.sh"; echo "$DELAI_SERVICE ${SERVICES_CONNUS[*]} $DELAI_SYSTEME"')"
check "local.conf surcharge les defauts" eq "$val" "42 demo 1800"
val="$(ACMECHANIC_HOME="$ROOT" bash -c 'source "$ACMECHANIC_HOME/config.sh"; config_service x type')"
check "config_service par defaut : vide" eq "$val" ""

echo "affichage (lib/tableau.sh)"
# shellcheck source=../lib/tableau.sh
source "$ROOT/lib/tableau.sh"
_tableau_disposition 4 24 80
check "80x24, 4 services : 1 colonne" eq "$_NCOL/$_NRANG/$_K" "1/4/3"
_tableau_disposition 9 50 200
check "200x50, 9 services : 3 colonnes, detail plafonne a 12" eq "$_NCOL/$_NRANG/$_K" "3/3/12"
_tableau_cadrer "école" 8
check "cadrage en caracteres (accents)" eq "${#_CADRE}" "8"
_tableau_duree 125
check "duree 125 s" eq "$_DUREE" "2m05s"
_tableau_duree 42s
check "duree 42 s" eq "$_DUREE" "42s"

echo "sauvegardes (lib/backup.sh)"
out="$(bash -c '
	SERVICE_NAME=test
	source "$ACMECHANIC_HOME/lib/common.sh"
	source "$ACMECHANIC_HOME/lib/backup.sh"
	src="'"$TMP"'/src"; mkdir -p "$src/config"; echo secret-de-test >"$src/config/a.txt"
	BACKUP_GARDER=2
	for i in 1 2 3; do creer_sauvegarde demo "$src" config >/dev/null 2>&1 || exit 1; sleep 1; done
	n=$(find "$BACKUP_ROOT/demo" -name "demo_*.tar.gz" | wc -l)
	a=$(find "$BACKUP_ROOT/demo" -name "demo_*.tar.gz" | sort | tail -1)
	verifier_sauvegarde "$a" >/dev/null 2>&1 && echo "$n ok" || echo "$n ko"
')"
check "rotation (garder 2) + verification SHA-256" eq "$out" "2 ok"

echo
echo "Resultat : $PASS ok, $FAIL echec(s)"
[ "$FAIL" -eq 0 ]
