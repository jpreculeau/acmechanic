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
export LOG_DIR="$TMP/logs" BACKUP_ROOT="$TMP/backups" CACHE_REGISTRE_DIR="$TMP/cache" VERROU_DIR="$TMP"
export ACMECHANIC_HOME="$ROOT"

echo "syntaxe"
for f in "$ROOT"/acmechanic.sh "$ROOT"/restore.sh "$ROOT"/config.sh "$ROOT"/lib/*.sh \
	"$ROOT"/bibliotheque/*/*.sh; do
	check "bash -n ${f#"$ROOT"/}" bash -n "$f"
done

echo "options"
check "--version" eq "$("$ROOT/acmechanic.sh" --version)" "acmechanic 1.1.0"
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
ln -s "$ROOT/bibliotheque/syncthing" "$S/syncthing"
liste="$(SERVICES_DIR="$S" ORDRE_DIR="$TMP/vide" "$ROOT/acmechanic.sh" --liste 2>&1)"
check "service de la bibliotheque lie (symlink) detecte" grep -qE 'syncthing +detecte automatiquement' <<<"$liste"

echo "bibliotheque (lib/service.sh)"
out="$(bash -c '
	SERVICE_NAME=test-service
	source "$ACMECHANIC_HOME/lib/service.sh"
	maintenir_service_docker() { echo "$*"; }   # bouchon : pas de Docker
	DOCKER_PROJET=/p
	docker_standard beszel-agent editeur/agent:latest http://u /d a b
	echo "$BESZEL_AGENT_TAG"
	docker_standard app editeur/app:latest "" /d
' 2>/dev/null)"
check "docker_standard : arguments transmis" eq "$(sed -n 1p <<<"$out")" "/p beszel-agent http://u editeur/agent:latest oui /d a b"
check "docker_standard : tag exporte en <CONTENEUR>_TAG" eq "$(sed -n 2p <<<"$out")" "latest"
check "docker_standard : sans elements, pas de sauvegarde" eq "$(sed -n 3p <<<"$out")" "/p app  editeur/app:latest non /d"
for d in "$ROOT"/bibliotheque/*/; do
	n="$(basename "$d")"
	check "bibliotheque/$n : script nomme comme son dossier" test -x "$d/$n.sh"
	check "bibliotheque/$n : source lib/service.sh" grep -q 'lib/service.sh' "$d/$n.sh"
done

echo "mises a jour git (auto-mise a jour, depots-git)"
# Copie du dossier de travail dans un depot jetable + un amont nu.
G="$TMP/git"; mkdir -p "$G"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
nouveau_depot() {  # nouveau_depot <nom> [source] : clone <nom> + amont <nom>.git
	local n="$1" src="${2:-}"
	mkdir -p "$G/$n.src"
	if [ -n "$src" ]; then (cd "$src" && tar cf - --exclude=.git . ) | tar xf - -C "$G/$n.src"
	else echo v1 >"$G/$n.src/f"; fi
	git -C "$G/$n.src" init -q -b main && git -C "$G/$n.src" add -A && git -C "$G/$n.src" commit -qm v1
	git clone -q --bare "$G/$n.src" "$G/$n.git" && git clone -q "$G/$n.git" "$G/$n"
	git -C "$G/$n.src" remote add origin "$G/$n.git"
}
publier() {  # publier <nom> : un commit de plus dans l'amont
	echo "$RANDOM" >>"$G/$1.src/f" && git -C "$G/$1.src" add -A &&
		git -C "$G/$1.src" commit -qm suite && git -C "$G/$1.src" push -q origin main
}
nouveau_depot acm "$ROOT"; publier acm
mkdir -p "$TMP/vide"
( cd "$G/acm" && SERVICES_DIR="$TMP/vide" ORDRE_DIR="$TMP/vide" ./acmechanic.sh --services >/dev/null 2>&1 )
check "auto-mise a jour : avance rapide appliquee" eq "$(git -C "$G/acm" rev-parse HEAD)" "$(git -C "$G/acm.git" rev-parse HEAD)"
publier acm; echo local >>"$G/acm/README.md"
( cd "$G/acm" && SERVICES_DIR="$TMP/vide" ORDRE_DIR="$TMP/vide" ./acmechanic.sh --services >/dev/null 2>&1 )
check "auto-mise a jour : modifications locales preservees" not test "$(git -C "$G/acm" rev-parse HEAD)" = "$(git -C "$G/acm.git" rev-parse HEAD)"
git -C "$G/acm" checkout -q README.md
nouveau_depot outil; publier outil
nouveau_depot sale; publier sale; echo local >>"$G/sale/f"
printf 'DEPOTS_GIT=("%s" "%s" "%s")\nCHEZMOI_VERIFIER=non\n' "$G/outil" "$G/sale" "$G/acm" >"$G/acm/local.conf"
env -u ACMECHANIC_HOME "$G/acm/bibliotheque/depots-git/depots-git.sh" >/dev/null 2>&1; rc=$?
out="$(cat "$LOG_DIR/depots-git.log")"
check "depots-git : code 0" eq "$rc" "0"
check "depots-git : depot propre mis a jour" eq "$(git -C "$G/outil" rev-parse HEAD)" "$(git -C "$G/outil.git" rev-parse HEAD)"
check "depots-git : depot modifie laisse intact" grep -q 'sale : 1 commit(s) disponible(s), non appliques' <<<"$out"
check "depots-git : Acmechanic laisse a l'auto-mise a jour" grep -q 'se met a jour lui-meme' <<<"$out"

echo "micrologiciel, nettoyage, outils-ia, acmefrag (bouchons)"
B="$TMP/bouchons"; mkdir -p "$B"
printf '#!/bin/sh\necho "BOOTLOADER: update available"\necho "   CURRENT: jeu. 1 (1)"\necho "    LATEST: ven. 2 (2)"\nexit 1\n' >"$B/rpi-eeprom-update"
chmod +x "$B/rpi-eeprom-update"
PATH="$B:$PATH" "$ROOT/bibliotheque/micrologiciel/micrologiciel.sh" >/dev/null 2>&1; rc=$?
out="$(cat "$LOG_DIR/micrologiciel.log")"
check "micrologiciel : EEPROM signalee sans echec" eq "$rc" "0"
check "micrologiciel : point d'attention avec la commande" grep -q 'rpi-eeprom-update -a' <<<"$out"
L="$TMP/lg"; mkdir -p "$L/foo" "$L/nettoyage"
head -c 3145728 /dev/zero >"$L/foo/foo.log"; head -c 3145728 /dev/zero >"$L/foo/autre.log"
LOG_DIR="$L/nettoyage" NETTOYAGE_DOCKER=non NETTOYAGE_JOURNAL=non NETTOYAGE_PAQUETS=non \
	NETTOYAGE_VIGNETTES_JOURS=0 NETTOYAGE_LOG_MO=1 "$ROOT/bibliotheque/nettoyage/nettoyage.sh" >/dev/null 2>&1
check "nettoyage : journal de service raccourci" eq "$(stat -c %s "$L/foo/foo.log")" "524288"
check "nettoyage : autre fichier intact" eq "$(stat -c %s "$L/foo/autre.log")" "3145728"
printf '#!/bin/sh\ncase "$1" in --version) cat "%s/v" ;; update) echo 2.0 >"%s/v" ;; esac\n' "$B" "$B" >"$B/claude"
chmod +x "$B/claude"; echo 1.0 >"$B/v"
out="$(PATH="$B:$PATH" IA_OUTILS=claude "$ROOT/bibliotheque/outils-ia/outils-ia.sh" 2>&1)"; rc=$?
check "outils-ia : claude mis a jour" eq "$rc/$(cat "$B/v")" "0/2.0"
out="$(ACMEFRAG_DOSSIER="$TMP/absent" "$ROOT/bibliotheque/acmefrag/acmefrag.sh" 2>&1)"; rc=$?
check "acmefrag : absent => ignore, code 0" eq "$rc" "0"

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
check "80x24, 4 services : 1 colonne, 6 lignes minimum, ascenseur" eq "$_NCOL/$_NRANG/$_K/$_DEFIL" "1/4/6/oui"
ACMECHANIC_LIGNES_MIN=2 _tableau_disposition 4 24 80
check "ACMECHANIC_LIGNES_MIN=2 : tout tient" eq "$_K/$_DEFIL" "3/non"
_tableau_disposition 9 50 200
check "200x50, 9 services : 3 colonnes, detail plafonne a 12" eq "$_NCOL/$_NRANG/$_K/$_DEFIL" "3/3/12/non"
_tableau_cadrer "école" 8
check "cadrage en caracteres (accents)" eq "${#_CADRE}" "8"
_tableau_duree 125
check "duree 125 s" eq "$_DUREE" "2m05s"
_tableau_duree 42s
check "duree 42 s" eq "$_DUREE" "42s"

_version_diff "Hermes Agent v0.21.5+3851.g4569bb8 (2026.9.24)" "Hermes Agent v0.21.5+4533.g39faafb (2026.9.24)"
check "versions : partie commune (facon nala)" eq "$_VC" "Hermes Agent v0.21.5"
check "versions : partie qui change, avant" eq "$_VA" "+3851.g4569bb8 (2026.9.24)"
check "versions : partie qui change, apres" eq "$_VB" "+4533.g39faafb (2026.9.24)"
_version_diff "img:unstable (build 2026-09-21)" "img:unstable (build 2026-09-28)"
check "versions : date de build" eq "$_VA/$_VB" "21)/28)"
_version_diff "5.2.3" "5.2.10"
check "versions : dernier nombre seulement" eq "$_VC|$_VA|$_VB" "5.2.|3|10"
printf 'lent 300\nrapide 5\nmoyen 40\n' >"$TMP/durees"
check "ordre des cadres : du plus rapide au plus lent, inconnus a la fin" \
	eq "$(tableau_ordonner "$TMP/durees" lent inconnu rapide moyen | tr '\n' ' ')" "rapide moyen lent inconnu "
mkdir -p "$TMP/etat"; echo "MAJ|12s" >"$TMP/etat/lent.fin"; echo "IGNORE|-" >"$TMP/etat/moyen.fin"
TABLEAU_DOSSIER="$TMP/etat" tableau_memoriser_durees "$TMP/durees"
check "durees memorisees (mesuree, gardee, ignoree)" eq "$(tr '\n' ' ' <"$TMP/durees")" "lent 12 moyen 40 rapide 5 "

echo "langues (lib/i18n.sh, locale/)"
cles() { bash -c 'declare -A MSG=(); source "$1"; printf "%s\n" "${!MSG[@]}" | sort' _ "$1"; }
for c in "$ROOT"/locale/*.sh; do
	[ "$(basename "$c")" = fr.sh ] && continue
	check "locale/$(basename "$c") : memes cles que fr.sh" eq "$(cles "$c" | tr '\n' ' ')" "$(cles "$ROOT/locale/fr.sh" | tr '\n' ' ')"
done
check "anglais par defaut sous LANG=C" eq "$(env -u ACMECHANIC_LANGUE LC_ALL=C bash -c 'source "$1/lib/i18n.sh"; t fin_ok' _ "$ROOT")" "Curtain! Everything's shipshape."
check "ACMECHANIC_LANGUE=fr" eq "$(ACMECHANIC_LANGUE=fr bash -c 'source "$1/lib/i18n.sh"; t fin_echec 2' _ "$ROOT")" "Patatras ! 2 étape(s) en échec."
check "langue sans catalogue : anglais" eq "$(ACMECHANIC_LANGUE=de bash -c 'source "$1/lib/i18n.sh"; echo "$I18N_LANGUE"' _ "$ROOT")" "en"

echo "themes (locale/themes)"
for d in "$ROOT"/locale/themes/*/; do
	th="$(basename "$d")"
	for c in fr en; do
		check "theme $th : $c.sh present" test -r "$d/$c.sh"
		extra="$(comm -23 <(cles "$d/$c.sh") <(cles "$ROOT/locale/fr.sh"))"
		check "theme $th/$c : seulement des cles connues" eq "$extra" ""
		check "theme $th/$c : %d garde dans fin_echec" grep -q 'fin_echec\]=".*%d' "$d/$c.sh"
	done
done
check "theme applique par-dessus la langue" eq "$(ACMECHANIC_LANGUE=fr ACMECHANIC_THEME=kaiju bash -c 'source "$1/lib/i18n.sh"; echo "${MSG[bruit_maj]}|${MSG[journal]}"' _ "$ROOT")" "RRRAAAWR !|Journal complet : %s"
check "theme inconnu : sans effet" eq "$(ACMECHANIC_LANGUE=fr ACMECHANIC_THEME=nimporte bash -c 'source "$1/lib/i18n.sh"; t fin_ok' _ "$ROOT")" "Rideau ! Tout est en ordre."
check "--themes liste les themes" grep -q 'kaiju' <("$ROOT/acmechanic.sh" --themes)

echo "points d'attention"
out="$(bash -c '
	SERVICE_NAME=att; source "$ACMECHANIC_HOME/lib/common.sh"
	export ACMECHANIC_ATTENTION_FICHIER="'"$TMP"'/att"
	point_attention "EEPROM a mettre a jour" "sudo rpi-eeprom-update -a"
	cat "$ACMECHANIC_ATTENTION_FICHIER"
' 2>/dev/null | tail -1)"
check "point_attention : fichier partage (service, message, commande)" eq "$(tr '\037' '|' <<<"$out")" "att|EEPROM a mettre a jour|sudo rpi-eeprom-update -a"
out="$(bash -c 'SERVICE_NAME=att; source "$ACMECHANIC_HOME/lib/common.sh"; point_attention "A faire" "curl x | sh" >/dev/null; rapport_attention ""' 2>/dev/null)"
check "rapport_attention : message et commande" grep -q 'A faire' <<<"$out"
check "rapport_attention : commande avec | intacte" grep -qF 'curl x | sh' <<<"$out"

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
