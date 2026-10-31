#!/usr/bin/env bash
# Tests unitaires Acmechanic — sans root, sans Docker, sans reseau.
# Usage : tests/run_tests.sh
set -uo pipefail

PASS=0 FAIL=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# Les tests tournent sur une copie du depot, sans les reglages ni les
# services de la machine (local.conf, services/, ordre.d/) : ceux d'un
# clone en service primeraient sur l'environnement des tests (local.conf
# l'emporte sur l'environnement), et ses services seraient a portee.
SOURCE="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$TMP/acmechanic"
mkdir -p "$ROOT"
tar -C "$SOURCE" --exclude=./.git --exclude=./local.conf --exclude=./ordre.d \
	--exclude='./services/*' -cf - . | tar -xf - -C "$ROOT" ||
	{ echo "Copie du depot impossible dans $ROOT : tests arretes." >&2; exit 1; }

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
# Jamais le /etc/acmechanic.conf de la machine : un SERVICES_EXTRA_DIRS
# y ferait decouvrir de vrais services par les passages des tests.
export ACMECHANIC_CONF_SYSTEME="$TMP/aucun-conf-systeme"

echo "isolement"
check "copie du depot : ni local.conf, ni services, ni ordre.d" \
	eq "$(find "$ROOT/services" -mindepth 1 | wc -l)/$(test -e "$ROOT/local.conf" && echo oui)$(test -e "$ROOT/ordre.d" && echo oui)" "0/"
check "copie du depot : le code y est" test -x "$ROOT/acmechanic.sh"

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
PATH="$B:$PATH" ACMECHANIC_ATTENTION_FICHIER="$TMP/att-micro" "$ROOT/bibliotheque/micrologiciel/micrologiciel.sh" >/dev/null 2>&1; rc=$?
out="$(cat "$LOG_DIR/micrologiciel.log")"
check "micrologiciel : EEPROM signalee sans echec" eq "$rc" "0"
check "micrologiciel : point d'attention avec la commande" grep -q 'rpi-eeprom-update -a' <<<"$out"
check "micrologiciel : point d'attention avec pourquoi et attendu" \
	eq "$(awk -F '\037' '$2 ~ /^EEPROM/ && $4 != "" && $5 != "" {n++} END {print n+0}' "$TMP/att-micro")" "1"
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
# claude update en echec une fois (registre npm injoignable) : second
# essai, etape reussie ; en echec deux fois : etape en echec, sans
# troisieme essai.
printf '#!/bin/sh\ncase "$1" in --version) cat "%s/v" ;; update) echo x >>"%s/essais"; [ "$(wc -l <"%s/essais")" -ge "$(cat "%s/ok_au")" ] && echo 2.0 >"%s/v" ;; esac\n' \
	"$B" "$B" "$B" "$B" "$B" >"$B/claude"
echo 1.0 >"$B/v"; : >"$B/essais"; echo 2 >"$B/ok_au"
PATH="$B:$PATH" IA_OUTILS=claude CLAUDE_REPRISE_ATTENTE=0 "$ROOT/bibliotheque/outils-ia/outils-ia.sh" >/dev/null 2>&1; rc=$?
check "outils-ia : claude update en echec une fois, second essai reussi" \
	eq "$rc/$(wc -l <"$B/essais")/$(cat "$B/v")" "0/2/2.0"
echo 1.0 >"$B/v"; : >"$B/essais"; echo 9 >"$B/ok_au"
PATH="$B:$PATH" IA_OUTILS=claude CLAUDE_REPRISE_ATTENTE=0 "$ROOT/bibliotheque/outils-ia/outils-ia.sh" >/dev/null 2>&1; rc=$?
check "outils-ia : claude update en echec deux fois, etape en echec" \
	eq "$([ "$rc" -ne 0 ] && echo echec)/$(wc -l <"$B/essais")" "echec/2"
out="$(ACMEFRAG_DOSSIER="$TMP/absent" "$ROOT/bibliotheque/acmefrag/acmefrag.sh" 2>&1)"; rc=$?
check "acmefrag : absent => ignore, code 0" eq "$rc" "0"
# Sante du disque : faux AcmeFrag ; --sante rend AF_SANTE_RC et sa ligne de bilan
AFD="$TMP/af"; mkdir -p "$AFD" "$TMP/mon disque"
cat >"$AFD/AcmeFrag.sh" <<'EOS'
#!/bin/sh
echo "$*" >>"$AF_LOG"
case "$*" in
*--version*) echo "acmefrag 3.1.0" ;;
*--sante*) sleep "${AF_SANTE_DUREE:-0}"; echo "   detail"; [ -n "${AF_TEXTE:-}" ] && echo "$AF_TEXTE"
	printf 'BILAN SANTÉ : %s\n' "${AF_BILAN:-Secteurs réalloués (5) : 40 → 48}"; exit "${AF_SANTE_RC:-0}" ;;
*--dry-run*) exit "${AF_MESURE_RC:-0}" ;;
esac
exit 0
EOS
chmod +x "$AFD/AcmeFrag.sh"
# sudo bouchonne : AF_SUDO=non simule un sudo qui demande un mot de passe
mkdir -p "$TMP/af-bin"
printf '#!/bin/sh\n[ "${AF_SUDO:-oui}" = oui ]\n' >"$TMP/af-bin/sudo"; chmod +x "$TMP/af-bin/sudo"
# id bouchonne : AF_UID force « id -u » (cas root testable sans etre root)
printf '#!/bin/sh\n[ "$1" = -u ] && [ -n "${AF_UID:-}" ] && { echo "$AF_UID"; exit 0; }\nexec %s "$@"\n' "$(command -v id)" >"$TMP/af-bin/id"
chmod +x "$TMP/af-bin/id"
sante() { # sante <code de --sante> [VAR=valeur...] : lance le service, renvoie son code
	local c="$1"; shift
	: >"$TMP/af.log"; : >"$TMP/att-af"; : >"$LOG_DIR/acmefrag.log"
	env PATH="$TMP/af-bin:$PATH" AF_SANTE_RC="$c" AF_LOG="$TMP/af.log" ACMEFRAG_DOSSIER="$AFD" ACMEFRAG_CIBLE= \
		ACMEFRAG_SANTE_CIBLE="$TMP/mon disque" ACMECHANIC_ATTENTION_FICHIER="$TMP/att-af" "$@" \
		"$ROOT/bibliotheque/acmefrag/acmefrag.sh" >"$TMP/af.out" 2>&1
}
sante 6; rc=$?
check "acmefrag sante : alerte => point d'attention, pas un echec" eq "$rc" "0"
check "acmefrag sante : --sante lance sur la cible" grep -q -- "$TMP/mon disque --sante" "$TMP/af.log"
check "acmefrag sante : bilan, commande, pourquoi et attendu" \
	eq "$(awk -F '\037' '$2 ~ /40 → 48/ && $3 ~ /--sante/ && $4 != "" && $5 != "" {n++} END {print n+0}' "$TMP/att-af")" "1"
cmd="$(awk -F '\037' 'NR == 1 {print $3}' "$TMP/att-af")"
check "acmefrag sante : commande proposee executable" \
	env AF_LOG=/dev/null bash -c '[ -n "$1" ] && eval "${1%--sante}--version" | grep -q 3.1.0' _ "$cmd"
check "acmefrag sante : commande proposee, cible en un seul argument" \
	bash -c 'c=$1 e=$2; eval "set -- $c"; [ "$#/$2/$3" = "3/$e/--sante" ]' _ "$cmd" "$TMP/mon disque"
sante 6 AF_BILAN=$'piege\037rm -rf /tmp/x\037\033[31m'; rc=$?
check "acmefrag sante : bilan hostile nettoye (5 champs, sans controle)" \
	eq "$(awk -F '\037' '{print NF}' "$TMP/att-af")/$(LC_ALL=C grep -c $'\033' "$TMP/att-af")" "5/0"
sante 0 AF_BILAN="aucune nouvelle dégradation (bilan PASSED)"; rc=$?
check "acmefrag sante : disque sain => OK avec le bilan, rien a signaler" \
	eq "$rc/$(wc -c <"$TMP/att-af")/$(grep -c 'OK .*AcmeFrag : aucune nouvelle dégradation (bilan PASSED)' "$LOG_DIR/acmefrag.log")" "0/0/1"
sante 0 AF_BILAN="aucune nouvelle dégradation (bilan FAILED)"; rc=$?
check "acmefrag sante : FAILED deja signale => journal seulement, jamais OK" \
	eq "$rc/$(wc -c <"$TMP/att-af")/$(grep -c 'INFO .*(bilan FAILED)' "$LOG_DIR/acmefrag.log")/$(grep -c 'OK .*(bilan FAILED)' "$LOG_DIR/acmefrag.log")" "0/0/1/0"
sante 7 AF_BILAN="mesure impossible : /dev/x en veille"; rc=$?
check "acmefrag sante : mesure impossible => ignoree avec la raison, code 0" \
	eq "$rc/$(wc -c <"$TMP/att-af")/$(grep -c 'sante du disque -- ignore : mesure impossible : /dev/x en veille' "$LOG_DIR/acmefrag.log")" "0/0/1"
sante 2 AF_TEXTE="   ❌ Option inconnue : --sante (voir --help)"; rc=$?
check "acmefrag sante : AcmeFrag sans --sante (code 2) => ignoree, code 0" \
	eq "$rc/$(grep -c 'ignore : AcmeFrag 3.1 ou plus requis' "$LOG_DIR/acmefrag.log")" "0/1"
sante 2 AF_TEXTE="   ❌ Configuration invalide"; rc=$?
check "acmefrag sante : autre code 2 (configuration) => echec" \
	eq "$([ "$rc" -ne 0 ] && echo echec)/$(grep -c 'ignore : AcmeFrag 3.1' "$LOG_DIR/acmefrag.log")" "echec/0"
sante 6 AF_BILAN="$(printf 'x%.0s' {1..400})"; rc=$?
check "acmefrag sante : bilan borne a 300 caracteres" \
	eq "$(awk -F '\037' '{m = $2; sub(/^AcmeFrag : sante du disque : /, "", m); print length(m)}' "$TMP/att-af")" "300"
sante 6 AF_UID=1000 AF_SUDO=non; rc=$?
check "acmefrag sante : sudo avec mot de passe => ignoree, AcmeFrag non lance" \
	eq "$rc/$(grep -c -- --sante "$TMP/af.log")/$(grep -c 'ignore : sudo demande un mot de passe' "$LOG_DIR/acmefrag.log")" "0/0/1"
sante 0 AF_UID=1000 AF_SUDO=non ACMEFRAG_CIBLE="$TMP/mon disque"; rc=$?
check "acmefrag mesure : sudo avec mot de passe => ignoree, AcmeFrag non lance" \
	eq "$rc/$(grep -c -e --dry-run -e --sante "$TMP/af.log")/$(grep -c 'mesure -- ignore : sudo demande un mot de passe' "$LOG_DIR/acmefrag.log")/$(grep -c 'ignore : sudo demande un mot de passe' "$LOG_DIR/acmefrag.log")" "0/0/1/2"
sante 0 AF_UID=0 AF_SUDO=non ACMEFRAG_CIBLE="$TMP/mon disque"; rc=$?
check "acmefrag : en root, sudo non consulte, mesure et sante lancees" \
	eq "$rc/$(grep -c -e --dry-run -e --sante "$TMP/af.log")" "0/2"
sante 0 ACMEFRAG_CIBLE="$TMP/mon disque"
check "acmefrag sante : apres la mesure --dry-run (disque deja reveille)" \
	eq "$(grep -n -e --dry-run -e --sante "$TMP/af.log" | cut -d: -f2- | sed 's/.* //' | tr '\n' ' ')" "--dry-run --sante "
sante 0 AF_SANTE_DUREE=3 ACMEFRAG_DELAI_SANTE=1; rc=$?
check "acmefrag sante : delai depasse => echec" eq "$([ "$rc" -ne 0 ] && echo echec)/$(grep -c 'trop longue' "$LOG_DIR/acmefrag.log")" "echec/1"
sante 1; rc=$?
check "acmefrag sante : erreur d'AcmeFrag => echec" not eq "$rc" "0"
sante 8; rc=$?
check "acmefrag sante : installation non sure (code 8) => echec explique" \
	eq "$([ "$rc" -ne 0 ] && echo echec)/$(grep -c 'sante du disque refusee : installation d.AcmeFrag non sure' "$LOG_DIR/acmefrag.log")" "echec/1"
sante 0 ACMEFRAG_CIBLE="$TMP/mon disque" AF_MESURE_RC=8; rc=$?
check "acmefrag mesure : installation non sure (code 8) => echec explique, pas ignoree" \
	eq "$([ "$rc" -ne 0 ] && echo echec)/$(grep -c 'mesure refusee : installation d.AcmeFrag non sure' "$LOG_DIR/acmefrag.log")/$(grep -c 'mesure -- ignore' "$LOG_DIR/acmefrag.log")" "echec/1/0"
sante 0 ACMEFRAG_CIBLE="$TMP/mon disque" AF_MESURE_RC=3; rc=$?
check "acmefrag mesure : refus de securite (code 3) => ignoree, code 0" \
	eq "$rc/$(grep -c 'mesure -- ignore : refus de securite' "$LOG_DIR/acmefrag.log")" "0/1"
sante 0 ACMEFRAG_SANTE_CIBLE="$TMP/debranche"; rc=$?
check "acmefrag sante : cible absente => ignoree, code 0" eq "$rc/$(grep -c -- --sante "$TMP/af.log")" "0/0"
: >"$TMP/af.log"
env -u ACMEFRAG_SANTE_CIBLE PATH="$TMP/af-bin:$PATH" AF_LOG="$TMP/af.log" ACMEFRAG_DOSSIER="$AFD" ACMEFRAG_CIBLE="$TMP/mon disque" \
	ACMECHANIC_ATTENTION_FICHIER="$TMP/att-af" "$ROOT/bibliotheque/acmefrag/acmefrag.sh" >/dev/null 2>&1
check "acmefrag sante : cible par defaut = ACMEFRAG_CIBLE" grep -q -- "$TMP/mon disque --sante" "$TMP/af.log"
sante 0 ACMEFRAG_SANTE_CIBLE= ACMEFRAG_CIBLE="$TMP/mon disque"; rc=$?
check "acmefrag sante : desactivee si cible vide, meme avec ACMEFRAG_CIBLE" eq "$rc/$(grep -c -- --sante "$TMP/af.log")" "0/0"

echo "liens physiques : espace reel, meme_fs, noter_bilan (lib/common.sh)"
H="$TMP/hl"; mkdir -p "$H/a" "$H/b"
head -c 1048576 /dev/zero >"$H/a/fichier"; ln "$H/a/fichier" "$H/b/lien"
out="$(bash -c 'SERVICE_NAME=t; source "$ACMECHANIC_HOME/lib/common.sh"
	echo "$(espace_reel "$1/a/fichier") $(espace_reel "$1/a/fichier" "$1/b/lien") $(espace_reel "$1/b/lien" "$1/a/fichier") $(espace_reel) $(espace_reel "$1/absent")"
	echo "$(espace_reel_h "$1/a/fichier") $(meme_fs "$1/a" "$1/b" && echo meme) $(meme_fs / /proc || echo autre) $(meme_fs "$1" "$1/absent" || echo absent)"
	noter_bilan "cle" "valeur"; RAPPORT_COMPACT=non rapport_final B | grep -c "^cle .*INFO .*valeur"
	echo "$NB_OK$NB_ECHEC$NB_IGNORE$NB_INCHANGE"' _ "$H" 2>/dev/null)"
check "espace_reel : fichier + lien physique comptes une fois, meme sur deux chemins" \
	eq "$(sed -n 1p <<<"$out")" "1024 1024 1024 0 0"
check "espace_reel_h lisible ; meme_fs vrai sur le meme FS, faux sur /proc ou un chemin absent" \
	eq "$(sed -n 2p <<<"$out")" "1.0 Mio meme autre absent"
check "noter_bilan : ligne INFO du bilan, aucun compteur d'etape touche" eq "$(sed -n '3,4p' <<<"$out" | tr '\n' /)" "1/0000/"

echo "cross-seed : config.js, qBittorrent et liens (lib/xseed.sh)"
XS="$TMP/xs"; mkdir -p "$XS/config" "$XS/bin" "$XS/data/Film.A" "$XS/data2" "$XS/links/trackerA" "$XS/links/trackerB"
cat >"$XS/config/config.js" <<EOS
// config.js de test
module.exports = {
  torrentClients: ["qbittorrent:http://moi:s3cret@127.0.0.1:8080"], // identifiants
  // linkDirs: ["/commente"],
  dataDirs: [
    "$XS/data",
    '$XS/data2'   // simples quotes
  ],
  linkDirs: ["$XS/links"],
  matchMode: "flexible",
};
EOS
# curl bouchonne : API qBittorrent (login, torrents/info, app/preferences)
cat >"$XS/bin/curl" <<'EOS'
#!/bin/sh
out=""; url=""; pass=""
while [ $# -gt 0 ]; do
	case "$1" in
	-o) out="$2"; shift ;;
	--data-urlencode) case "$2" in password@*) pass="$(cat "${2#password@}")" ;; password=*) pass="ARGUMENT" ;; esac; shift ;;
	-c | -b | -m | -w) shift ;;
	-*) ;;
	*) url="$1" ;;
	esac
	shift
done
echo "$url" >>"${CURL_LOG:-/dev/null}"
case "$url" in
*injoignable*) exit 7 ;;
*/auth/login) echo "$pass" >>"${CURL_PASS:-/dev/null}"
	case "$pass" in s3cret) printf 'Ok.' ;; banni) printf 'Banned' ;; *) printf 'Fails.' ;; esac ;;
*/torrents/info) cat "$QBIT_INFO" >"$out"; printf 200 ;;
*/app/preferences) printf '{"save_path":"%s"}' "$QBIT_SAVE" >"$out"; printf 200 ;;
*/app/version) [ "${QBIT_SANS_MDP:-non}" = oui ] && printf 200 || printf 403 ;;
*) printf 404 ;;
esac
EOS
chmod +x "$XS/bin/curl"
printf '[{"name":"Film A","content_path":"%s/links/trackerA/Film.A"},{"name":"B","content_path":"%s/links/trackerB/fichier.mkv"}]\n' \
	"$XS" "$XS" >"$XS/info.json"
echo film >"$XS/data/Film.A/film.mkv"
mkdir -p "$XS/links/trackerA/Film.A"; ln "$XS/data/Film.A/film.mkv" "$XS/links/trackerA/Film.A/film.mkv"
ln "$XS/data/Film.A/film.mkv" "$XS/links/trackerA/ancien.mkv"   # orphelin, autre nom conserve
ln "$XS/data/Film.A/film.mkv" "$XS/links/trackerB/fichier.mkv"
echo seul >"$XS/links/trackerB/seul.mkv"                            # orphelin, dernier nom : donnees
printf '%s/links/trackerA/Film.A\n%s/links/trackerB/fichier.mkv\n' "$XS" "$XS" >"$XS/contenus"   # = qbit_chemins_contenus
out="$(bash -c 'SERVICE_NAME=t; source "$ACMECHANIC_HOME/lib/common.sh"
	CROSS_SEED_CONFIG="$1/config/config.js"; source "$ACMECHANIC_HOME/lib/xseed.sh"
	xseed_liens_dossiers | tr "\n" " "; echo
	xseed_donnees_dossiers | tr "\n" " "; echo
	config_js_liste "$CROSS_SEED_CONFIG" matchMode; config_js_liste "$CROSS_SEED_CONFIG" absent; echo "rc=$?"
	qbit_url
	CROSS_SEED_QBIT_URL=http://x/ qbit_url
	xseed_liens_par_tracker "$1/links" | tr "\t\n" ":/"; echo
	xseed_liens_orphelins "$1/contenus" "$1/links" | sort | tr "\n" " "; echo
	xseed_protege "$1/links/trackerA/x" && echo protege-linkdir
	xseed_protege "/mnt/d/xseed-links/t/x" && echo protege-nom
	xseed_protege "$1/data/x" || echo libre
	M="$1"; docker() { printf "%s\t%s\n" "$M" "$M"; }
	xseed_monte_a_l_identique c "$1/links"; echo "monte=$?"
	docker() { printf "%s\t%s\n" "/hote$M" "$M"; }
	xseed_monte_a_l_identique c "$1/links"; echo "autre-source=$?"
	docker() { return 1; }
	xseed_monte_a_l_identique c "$1/links"; echo "inspect=$?"
' _ "$XS" 2>&1)"
check "config.js : linkDirs lu (cle commentee ignoree)" eq "$(sed -n 1p <<<"$out")" "$XS/links "
check "config.js : dataDirs sur plusieurs lignes, simples quotes, commentaire de fin" \
	eq "$(sed -n 2p <<<"$out")" "$XS/data $XS/data2 "
check "config.js : valeur simple ; cle absente = rien, code 0" eq "$(sed -n '3,4p' <<<"$out" | tr '\n' /)" "flexible/rc=0/"
check "qbit_url : torrentClients de config.js, CROSS_SEED_QBIT_URL prioritaire" \
	eq "$(sed -n '5,6p' <<<"$out" | tr '\n' /)" "http://moi:s3cret@127.0.0.1:8080/http://x//"
check "liens par tracker : nombre de fichiers par sous-dossier" eq "$(sed -n 7p <<<"$out")" "2:trackerA/2:trackerB/"
check "liens orphelins : les fichiers qu'aucun content_path ne couvre" \
	eq "$(sed -n 8p <<<"$out")" "$XS/links/trackerA/ancien.mkv $XS/links/trackerB/seul.mkv "
check "xseed_protege : sous un linkDir, ou composant xseed-links ; libre ailleurs" \
	eq "$(sed -n '9,11p' <<<"$out" | tr '\n' /)" "protege-linkdir/protege-nom/libre/"
check "montage identique : trouve sous un volume <chemin>:<chemin> ; source differente ou inspect en echec refuses" \
	eq "$(sed -n '12,14p' <<<"$out" | tr '\n' /)" "monte=0/autre-source=1/inspect=2/"
# Session qBittorrent : identifiants decodes, cookie, API, refus, injoignable.
# Un script .sh (pas bash -c) : les fichiers temporaires sont supprimes a la sortie.
cat >"$XS/session.sh" <<'EOS'
SERVICE_NAME=t; source "$ACMECHANIC_HOME/lib/common.sh"; source "$ACMECHANIC_HOME/lib/xseed.sh"
qbit_session "http://moi:s3cret@127.0.0.1:8080/"; echo "session=$? $QBIT_BASE"
qbit_session "http://moi:banni@127.0.0.1:8080"; echo "banni=$? $(test -e "$QBIT_REFUS" && echo marque || echo libre)"
qbit_chemins_contenus | wc -l; qbit_dossier_arrivee
qbit_session "http://moi:faux@127.0.0.1:8080"; echo "refus=$?"
qbit_session "http://a:b@injoignable:1"; echo "injoignable=$?"
qbit_session ""; echo "vide=$?"
QBIT_SANS_MDP=oui qbit_session "http://moi:faux@127.0.0.1:8080"; echo "sans-mdp=$?"
qbit_session "http://moi:p%40s%5Cs@h/"; echo "decode=$?"
qbit_session "http://moi:p%40s%5Cs@h/"; echo "memorise=$? $(cat "$QBIT_REFUS" | wc -l)"
qbit_session "http://autre:p%40s%5Cs@h/"; echo "autre-url=$?"
qbit_session "http://127.0.0.1:8080"; echo "sans-ident=$?"
echo "$QBIT_COOKIE"
EOS
out="$(PATH="$XS/bin:$PATH" QBIT_INFO="$XS/info.json" QBIT_SAVE="$XS/data" CURL_LOG="$XS/curl.log" CURL_PASS="$XS/pass.log" \
	QBIT_REFUS="$XS/refus" bash "$XS/session.sh" 2>&1)"
check "qbit_session : ouverte, URL sans identifiants ni / final" eq "$(sed -n 1p <<<"$out")" "session=0 http://127.0.0.1:8080"
check "qbit_session : reponse autre que Fails. (bannissement, erreur) => 1 sans refus memorise" eq "$(sed -n 2p <<<"$out")" "banni=1 libre"
check "qbit_chemins_contenus et qbit_dossier_arrivee lus par l'API" eq "$(sed -n '3,4p' <<<"$out" | tr '\n' /)" "2/$XS/data/"
check "qbit_session : refus 1, injoignable 2, URL vide 3" eq "$(sed -n '5,7p' <<<"$out" | tr '\n' /)" "refus=1/injoignable=2/vide=3/"
check "qbit_session : identifiants refuses mais API ouverte a l'hote sans mot de passe => 0" eq "$(sed -n 8p <<<"$out")" "sans-mdp=0"
check "qbit_session : mot de passe decode (%40, %5C), jamais en argument de processus" \
	eq "$(sed -n 9p <<<"$out")/$(grep -c '^p@s\\s$' "$XS/pass.log")/$(grep -c ARGUMENT "$XS/pass.log")" "decode=1/2/0"
check "qbit_session : refus memorise => pas de nouvel essai avec la meme URL, essai avec une autre" \
	eq "$(sed -n '10,11p' <<<"$out" | tr '\n' /)/$(grep -c auth/login "$XS/curl.log")" "memorise=1 1/autre-url=1//5"
check "qbit_session : authentification requise sans identifiants dans l'URL => 4" eq "$(sed -n 12p <<<"$out")" "sans-ident=4"
check "qbit_session : API d'abord essayee sans identifiants (login seulement sur 403)" \
	eq "$(grep -c app/version "$XS/curl.log")" "9"
check "qbit_session : seul l'hote est appele (jamais les identifiants dans l'URL)" \
	not grep -q 's3cret' "$XS/curl.log"
check "qbit_session : fichiers temporaires supprimes a la sortie" \
	bash -c '[ -n "$1" ] && [ ! -e "$1" ] && [ ! -e "$1.lock" ]' _ "$(tail -n 1 <<<"$out")"

echo "cross-seed : controles au demarrage (bouchons)"
# Le service entier, avec lib/service.sh deja « charge » : docker_* bouchonnes,
# docker inspect bouchonne par XS_MONTAGES (source<TAB>destination).
cat >"$XS/svc.sh" <<'EOS'
SERVICE_NAME=cross-seed; source "$ACMECHANIC_HOME/lib/common.sh"
source "$ACMECHANIC_HOME/config.sh"; _SERVICE_SH_LOADED=1
etape() { run_etape "$@"; }
docker_preparer() { :; }
docker_standard() { echo "docker_standard $*" >>"$XS_LOG"; }
docker_terminer() { bilan_service "Bilan"; exit $?; }
docker() { [ "$1" = inspect ] && cat "$XS_MONTAGES"; }
source "$ACMECHANIC_HOME/bibliotheque/cross-seed/cross-seed.sh"
EOS
printf '%s\t%s\n' "$XS" "$XS" >"$XS/montages"
xs() {  # xs [VAR=valeur...] : lance le service cross-seed bouchonne, renvoie son code
	: >"$XS/svc.log"; : >"$XS/att"; : >"$LOG_DIR/cross-seed.log"
	env PATH="$XS/bin:$PATH" QBIT_INFO="$XS/info.json" QBIT_SAVE="$XS/data/" XS_LOG="$XS/svc.log" \
		XS_MONTAGES="$XS/montages" CROSS_SEED_CONFIG="$XS/config/config.js" ACMECHANIC_ATTENTION_FICHIER="$XS/att" QBIT_REFUS="$XS/refus" "$@" \
		bash "$XS/svc.sh" >"$XS/svc.out" 2>&1
}
xs; rc=$?
check "cross-seed : tout en ordre => aucun point d'attention, conteneur maintenu, code 0" \
	eq "$rc/$(wc -c <"$XS/att")/$(grep -c '^docker_standard cross-seed crossseed/cross-seed:' "$XS/svc.log")" "0/0/1"
check "cross-seed : bilan, liens par tracker" \
	eq "$(grep -c -e 'liens trackerA  *INFO  *2$' -e 'liens trackerB  *INFO  *2$' "$LOG_DIR/cross-seed.log")" "2"
check "cross-seed : bilan, liens orphelins" grep -q 'liens orphelins  *INFO  *2 sur 4' "$LOG_DIR/cross-seed.log"
xs QBIT_SAVE="$XS/debranche"; rc=$?
check "cross-seed : dossier d'arrivee de qBittorrent absent de l'hote => point d'attention, code 0" \
	eq "$rc/$(grep -c "dossier absent sur l.hote : $XS/debranche" "$XS/att")/$(grep -c 'hardlink impossible' "$XS/att")" "0/1/0"
# linkDir sur un autre systeme de fichiers : hardlink impossible => point d'attention
AUTRE_FS="/dev/shm/acmechanic-test-$$"
if mkdir -p "$AUTRE_FS/links" 2>/dev/null && [ "$(stat -c %d "$AUTRE_FS")" != "$(stat -c %d "$XS")" ]; then
	sed "s#\"$XS/links\"#\"$AUTRE_FS/links\"#" "$XS/config/config.js" >"$XS/config/autre-fs.js"
	xs CROSS_SEED_CONFIG="$XS/config/autre-fs.js"; rc=$?
	check "cross-seed : linkDir sur un autre FS => « hardlink impossible pour <dataDir> : injection en echec », code 0" \
		eq "$rc/$(grep -c "hardlink impossible pour $XS/data : injection en echec" "$XS/att")" "0/1"
	check "cross-seed : linkDir absent de l'hote signale, sans faux « hardlink impossible »" \
		eq "$(rmdir "$AUTRE_FS/links"; xs CROSS_SEED_CONFIG="$XS/config/autre-fs.js"; grep -c "linkDir absent sur l.hote : $AUTRE_FS/links" "$XS/att")/$(grep -c 'hardlink impossible' "$XS/att")" "1/2"
	rm -rf "$AUTRE_FS"
else
	echo "  (saute : pas de second systeme de fichiers inscriptible)"
fi
: >"$XS/montages"   # conteneur sans ces volumes
xs; rc=$?
check "cross-seed : chemin non monte a l'identique dans le conteneur => point d'attention, code 0" \
	eq "$rc/$(grep -c "n'est pas monte dans le conteneur au meme chemin" "$XS/att")" "0/3"
printf '%s\t%s\n' "$XS" "$XS" >"$XS/montages"
xs QBIT_SAVE="$XS" CROSS_SEED_QBIT_URL="http://moi:faux@127.0.0.1:8080"; rc=$?
check "cross-seed : identifiants qBittorrent refuses => avertissement, pas d'orphelins, code 0" \
	eq "$rc/$(grep -c 'identifiants qBittorrent refuses' "$LOG_DIR/cross-seed.log")/$(grep -c 'liens orphelins' "$LOG_DIR/cross-seed.log")" "0/1/0"
xs CROSS_SEED_LIENS=non; rc=$?
check "cross-seed : CROSS_SEED_LIENS=non => controle ignore, code 0" \
	eq "$rc/$(grep -c 'liens physiques -- ignore : desactive' "$LOG_DIR/cross-seed.log")" "0/1"
sed '/linkDirs/d' "$XS/config/config.js" >"$XS/config/sans-liens.js"
xs CROSS_SEED_CONFIG="$XS/config/sans-liens.js"; rc=$?
check "cross-seed : pas de linkDirs => rien a controler, code 0" \
	eq "$rc/$(grep -c 'liens physiques non utilises' "$LOG_DIR/cross-seed.log")/$(wc -c <"$XS/att")" "0/1/0"

echo "ollama (installeur officiel, bouchons)"
O="$TMP/ollama"; mkdir -p "$O"; echo 1.0.0 >"$O/ov"; : >"$O/systemctl.log"
cat >"$O/ollama" <<EOS
#!/bin/sh
[ "\$1" = --version ] && echo "ollama version is \$(cat $O/ov)"
[ "\$1" = list ] && exit 1
exit 0
EOS
cat >"$O/curl" <<EOS
#!/bin/sh
case "\$*" in
*api.github.com*) echo '"tag_name": "v9.9.9"' ;;
*" -o "*) while [ "\$1" != -o ]; do shift; done; printf 'echo "\$OLLAMA_VERSION" >$O/ov\n' >"\$2" ;;
esac
EOS
printf '#!/bin/sh\n[ "$1" = -n ] && shift\nexec "$@"\n' >"$O/sudo"
cat >"$O/systemctl" <<EOS
#!/bin/sh
case "\$1" in is-active) echo inactive ;; is-enabled) echo disabled ;; cat) exit 0 ;; *) echo "\$*" >>$O/systemctl.log ;; esac
EOS
chmod +x "$O"/*
PATH="$O:$PATH" IA_OUTILS=ollama OLLAMA_MAJ=oui "$ROOT/bibliotheque/outils-ia/outils-ia.sh" >/dev/null 2>&1; rc=$?
check "ollama : mise a jour appliquee (version fixee)" eq "$rc/$(cat "$O/ov")" "0/9.9.9"
check "ollama : service remis desactive et arrete" eq "$(tr '\n' ';' <"$O/systemctl.log")" "disable ollama;stop ollama;"
echo 1.0.0 >"$O/ov"
PATH="$O:$PATH" IA_OUTILS=ollama "$ROOT/bibliotheque/outils-ia/outils-ia.sh" >/dev/null 2>&1
check "ollama : OLLAMA_MAJ par defaut = signaler seulement" eq "$(cat "$O/ov")" "1.0.0"

echo "session-graphique (depot git + correctifs)"
N="$TMP/nwg"; mkdir -p "$N"
nouveau_depot demo-outil
git -C "$G/demo-outil.src" tag v1.0
( cd "$G/demo-outil.src" && git checkout -q -b correctif-a && echo a >f && git commit -qam a &&
	git checkout -q main && git checkout -q -b correctif-b && echo b >f && git commit -qam b && git checkout -q main )
git -C "$G/demo-outil.src" push -q origin correctif-a correctif-b --tags
git -C "$G/demo-outil" fetch -q origin 'refs/heads/correctif-*:refs/heads/correctif-*' --tags
cat >"$N/local.conf" <<EOS
SESSION_GRAPHIQUE_PIP_GIT=(demo-outil)
DEMO_OUTIL_SRC="$G/demo-outil"
DEMO_OUTIL_CORRECTIFS=(correctif-a correctif-b)
EOS
cp -r "$ROOT/lib" "$ROOT/config.sh" "$ROOT/locale" "$N/"; mkdir -p "$N/bibliotheque"; cp -r "$ROOT/bibliotheque/session-graphique" "$N/bibliotheque/"
env -u ACMECHANIC_HOME SESSION_GRAPHIQUE_ETAT="$N/etat" "$N/bibliotheque/session-graphique/session-graphique.sh" >/dev/null 2>&1; rc=$?
out="$(cat "$LOG_DIR/session-graphique.log")"
check "session-graphique : code 0" eq "$rc" "0"
check "session-graphique : conflit de correctifs => point d'attention, rien d'installe" grep -q "correctif-b ne s'applique plus sur v1.0" <<<"$out"
check "session-graphique : dossier jetable supprime" eq "$(git -C "$G/demo-outil" worktree list | wc -l)" "1"
sed -i 's/^SESSION_GRAPHIQUE_PIP_GIT=/BUREAU_PIP_GIT=/' "$N/local.conf"; : >"$LOG_DIR/session-graphique.log"
env -u ACMECHANIC_HOME SESSION_GRAPHIQUE_ETAT="$N/etat" "$N/bibliotheque/session-graphique/session-graphique.sh" >/dev/null 2>&1
check "session-graphique : ancien reglage BUREAU_PIP_GIT encore lu" grep -q "correctif-b ne s'applique plus sur v1.0" "$LOG_DIR/session-graphique.log"

echo "configuration"
mkdir -p "$TMP/home"
cp "$ROOT/config.sh" "$TMP/home/"
echo 'DELAI_SERVICE=42; SERVICES_CONNUS=(demo)' >"$TMP/home/local.conf"
val="$(env -u BACKUP_ROOT ACMECHANIC_HOME="$TMP/home" bash -c \
	'source "$ACMECHANIC_HOME/config.sh"; echo "$DELAI_SERVICE ${SERVICES_CONNUS[*]} $DELAI_SYSTEME"')"
check "local.conf surcharge les defauts" eq "$val" "42 demo 1800"
val="$(ACMECHANIC_HOME="$ROOT" bash -c 'source "$ACMECHANIC_HOME/config.sh"; config_service x type')"
check "config_service par defaut : vide" eq "$val" ""
# Fichier systeme : celui de ACMECHANIC_CONF_SYSTEME, lu avant local.conf.
echo 'DELAI_SYSTEME=77; DELAI_SERVICE=99' >"$TMP/conf-systeme"
val="$(ACMECHANIC_CONF_SYSTEME="$TMP/conf-systeme" ACMECHANIC_HOME="$TMP/home" bash -c \
	'source "$ACMECHANIC_HOME/config.sh"; echo "$DELAI_SERVICE $DELAI_SYSTEME"')"
check "fichier systeme : ACMECHANIC_CONF_SYSTEME lu, local.conf prime" eq "$val" "42 77"

echo "affichage (lib/tableau.sh)"
# shellcheck source=../lib/tableau.sh
source "$ROOT/lib/tableau.sh"
_tableau_disposition 4 24 80
check "80x24, 4 services : 1 colonne, 6 lignes minimum, ascenseur" eq "$_NCOL/$_NRANG/$_K/$_DEFIL" "1/4/6/oui"
ACMECHANIC_LIGNES_MIN=2 _tableau_disposition 4 24 80
check "ACMECHANIC_LIGNES_MIN=2 : tout tient" eq "$_K/$_DEFIL" "3/non"
_tableau_disposition 9 50 200
check "200x50, 9 services : 3 colonnes, detail plafonne a 12" eq "$_NCOL/$_NRANG/$_K/$_DEFIL" "3/3/12/non"
_DEFIL_AUTO=12 _DEFIL_VUE=10 _DEFIL_MAN=""
_tableau_touche "[<65;40;12M"
check "molette vers le bas : +3 lignes depuis la position automatique" eq "$_DEFIL_MAN" "15"
_tableau_touche "[<64;40;12M"; _tableau_touche "[<64;40;12M"
check "molette vers le haut : -3 lignes par cran" eq "$_DEFIL_MAN" "9"
_tableau_touche "[5~"
check "Page precedente : une hauteur d'ecran" eq "$_DEFIL_MAN" "-1"
_tableau_touche "[F"
check "Fin : retour au suivi automatique" eq "$_DEFIL_MAN" ""
_tableau_touche "[<35;1;1M"
check "mouvement de souris sans bouton : ignore" eq "$_DEFIL_MAN" ""
D_ANT="$TMP/anticipe"; mkdir -p "$D_ANT"
printf '\x1fETAPE\x1fAnticipé pendant les services : nala update\nFetched 42 kB\n' >"$D_ANT/systeme.anticipe"
( TABLEAU_DOSSIER="$D_ANT" TABLEAU_SORTIES="$D_ANT" _K=4 _LARG=60 _BRUIT=""
  _tableau_cadre systeme 0; printf '%s\n' "${_CADRE_L[@]}" ) >"$TMP/cadre-anticipe" 2>&1
check "tache anticipee visible dans une case en attente" grep -q 'Fetched 42 kB' "$TMP/cadre-anticipe"
check "tache anticipee : son etape affichee" grep -q 'nala update' "$TMP/cadre-anticipe"
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
	n="$(bash -c 'source "$1/style.sh"; echo "${#THEME_ARC[@]}/${#THEME_ICONE}"' _ "$d" 2>/dev/null)"
	check "theme $th : style (10 couleurs, une icone)" eq "$n" "10/1"
	for c in fr en; do
		check "theme $th : $c.sh present" test -r "$d/$c.sh"
		extra="$(comm -23 <(cles "$d/$c.sh") <(cles "$ROOT/locale/fr.sh"))"
		check "theme $th/$c : seulement des cles connues" eq "$extra" ""
		check "theme $th/$c : %d garde dans fin_echec" grep -q 'fin_echec\]=".*%d' "$d/$c.sh"
	done
done
check "theme applique par-dessus la langue" eq "$(ACMECHANIC_LANGUE=fr ACMECHANIC_THEME=godzilla bash -c 'source "$1/lib/i18n.sh"; echo "${MSG[bruit_maj]}|${MSG[journal]}|${#THEME_ARC[@]}"' _ "$ROOT")" "Souffle atomique !|Journal complet : %s|10"
check "theme inconnu : sans effet" eq "$(ACMECHANIC_LANGUE=fr ACMECHANIC_THEME=nimporte bash -c 'source "$1/lib/i18n.sh"; t fin_ok' _ "$ROOT")" "Rideau ! Tout est en ordre."
check "--themes liste les themes" grep -q 'enterprise' <("$ROOT/acmechanic.sh" --themes)
out="$(for i in $(seq 1 40); do ACMECHANIC_LANGUE=fr ACMECHANIC_THEME=hasard bash -c 'source "$1/lib/i18n.sh"; echo "$ACMECHANIC_THEME"' _ "$ROOT"; done | sort -u)"
check "theme au hasard : plusieurs themes tires" test "$(wc -l <<<"$out")" -ge 3
check "theme au hasard : seulement des themes existants" eq "$(grep -vxF -f <(ACMECHANIC_THEME='' bash -c 'source "$1/lib/i18n.sh"; i18n_themes' _ "$ROOT") <<<"$out")" ""
check "theme au hasard : tirage stable (rechargement)" eq "$(ACMECHANIC_LANGUE=fr ACMECHANIC_THEME=hasard bash -c 'source "$1/lib/i18n.sh"; a=$ACMECHANIC_THEME; i18n_charger; i18n_charger; [ "$a" = "$ACMECHANIC_THEME" ] && echo stable' _ "$ROOT")" "stable"
out="$(for i in $(seq 1 30); do ACMECHANIC_LANGUE=hasard bash -c 'source "$1/lib/i18n.sh"; echo "$I18N_LANGUE"' _ "$ROOT"; done | sort -u | tr '\n' ' ')"
check "langue au hasard : fr et en tirees" eq "$out" "en fr "

echo "points d'attention"
out="$(bash -c '
	SERVICE_NAME=att; source "$ACMECHANIC_HOME/lib/common.sh"
	export ACMECHANIC_ATTENTION_FICHIER="'"$TMP"'/att"
	point_attention "EEPROM a mettre a jour" "sudo rpi-eeprom-update -a" "correctifs non appliques" "flash au prochain demarrage"
	cat "$ACMECHANIC_ATTENTION_FICHIER"
' 2>/dev/null | tail -1)"
check "point_attention : fichier partage (service, message, commande, pourquoi, attendu)" eq "$(tr '\037' '|' <<<"$out")" "att|EEPROM a mettre a jour|sudo rpi-eeprom-update -a|correctifs non appliques|flash au prochain demarrage"
out="$(bash -c 'SERVICE_NAME=att; source "$ACMECHANIC_HOME/lib/common.sh"; point_attention "A faire" "curl x | sh" >/dev/null; rapport_attention ""' 2>/dev/null)"
check "rapport_attention : message et commande" grep -q 'A faire' <<<"$out"
check "rapport_attention : commande avec | intacte" grep -qF 'curl x | sh' <<<"$out"
out="$(bash -c 'SERVICE_NAME=att; source "$ACMECHANIC_HOME/lib/common.sh"; point_attention "A faire" "cmd-x" "risque-y" "effet-z" >/dev/null; rapport_attention ""' 2>/dev/null)"
check "rapport_attention : commande seule, sans pourquoi ni attendu" \
	eq "$(grep -c 'cmd-x' <<<"$out")/$(grep -c 'risque-y\|effet-z' <<<"$out")" "1/0"

A="$TMP/actions"
{
	printf 'svc\x1fRedemarrage requis\x1fsudo reboot\n'
	printf 'svc\x1fA faire\x1ftouch %s/fait1\n' "$TMP"
	printf 'svc\x1fAutre\x1ftouch %s/fait2\n' "$TMP"
	printf 'svc\x1fDoublon\x1ftouch %s/fait1\n' "$TMP"
	printf 'svc\x1fSans commande\x1f\n'
} >"$A"
out="$(printf 'o\nn\nn\n' | ACMECHANIC_PROPOSER=force ACMECHANIC_LANGUE=fr bash -c 'SERVICE_NAME=t; source "$ACMECHANIC_HOME/lib/common.sh"; proposer_actions "$1"' _ "$A" 2>/dev/null)"
check "actions : acceptee => lancee" test -e "$TMP/fait1"
check "actions : refusee => rien" not test -e "$TMP/fait2"
check "actions : redemarrage propose en dernier" eq "$(grep -o 'Lancer « [^»]*»' <<<"$out" | tr '\n' ';')" "Lancer « touch $TMP/fait1 »;Lancer « touch $TMP/fait2 »;Lancer « sudo reboot »;"
out="$(ACMECHANIC_PROPOSER=oui bash -c 'SERVICE_NAME=t; source "$ACMECHANIC_HOME/lib/common.sh"; proposer_actions "$1"' _ "$A" </dev/null 2>&1)"
check "actions : rien demande hors terminal" eq "$out" ""
printf 'svc\x1fLent\x1ftouch %s/fait3\n' "$TMP" >"$A"
out="$(sleep 2 | ACMECHANIC_DELAI_REPONSE=1 ACMECHANIC_PROPOSER=force ACMECHANIC_LANGUE=fr bash -c 'SERVICE_NAME=t; source "$ACMECHANIC_HOME/lib/common.sh"; proposer_actions "$1"' _ "$A" 2>/dev/null)"
check "actions : delai ecoule => reponse par defaut (non)" not test -e "$TMP/fait3"
check "actions : delai ecoule annonce" grep -q 'Délai écoulé' <<<"$out"
check "actions : decompte affiche dans la question" grep -qF '[  1 s]' <<<"$out"
# Pourquoi et attendu : montres avant la question, sous l'en-tete
# (rang, service, constat) ; absents, aucune ligne vide a leur place.
{
	printf 'svc\x1fConstat-un\x1ftrue\x1fRisque-un\x1fEffet-un\n'
	printf 'svc\x1fConstat-deux\x1ftrue --deux\x1f\x1f\n'
	printf 'autre\x1fConstat-trois\x1ftrue\x1fRisque-trois\x1fEffet-trois\n'
} >"$A"
out="$(printf 'n\nn\n' | ACMECHANIC_DELAI_REPONSE=0 ACMECHANIC_PROPOSER=force ACMECHANIC_LANGUE=fr bash -c 'SERVICE_NAME=t; source "$ACMECHANIC_HOME/lib/common.sh"; proposer_actions "$1"' _ "$A" 2>/dev/null)"
check "actions : en-tete avec rang, service et constat" grep -qF '1/2  svc — Constat-un' <<<"$out"
check "actions : pourquoi puis attendu, avant la question" \
	eq "$(grep -oE 'Pourquoi : Risque-un|Attendu  : Effet-un|Lancer « true »' <<<"$out" | tr '\n' ';')" \
	"Pourquoi : Risque-un;Attendu  : Effet-un;Lancer « true »;"
check "actions : meme commande, autre pourquoi => proposee une fois" not grep -q 'Constat-trois' <<<"$out"
check "actions : sans pourquoi ni attendu, rien a leur place" \
	eq "$(grep -A1 'Constat-deux' <<<"$out" | tail -1 | grep -c 'Lancer « true --deux »')" "1"

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

echo "Docker : pulls et prune en parallele (incident du 07/10/2026)"
unset DELAI_VERROU_EXCLUSIF DELAI_VERROU_PARTAGE
# Les detenteurs du verrou posent un temoin SOUS le verrou : on attend
# le temoin (10 s au plus) plutot qu'un delai fixe (machine chargee).
ATTENDRE='attendre() {
	local i
	for i in $(seq 200); do [ -e "$1" ] && return 0; sleep 0.05; done
	echo "temoin absent : $1" >&2; exit 1
}'
rm -f "$TMP/tient" "$TMP/prune-lance" "$TMP/docker-reel"
out="$(bash -c "$ATTENDRE"'
	SERVICE_NAME=t; source "$ACMECHANIC_HOME/lib/common.sh"
	avec_verrou_images partage bash -c "touch \"\$1/tient\"; sleep 2; echo pull" _ "$1" &
	attendre "$1/tient"
	DELAI_VERROU_EXCLUSIF=30 avec_verrou_images exclusif echo prune
	wait
' _ "$TMP" 2>/dev/null)"
check "prune (exclusif) attend la fin du pull en cours (partage)" eq "$out" $'pull\nprune'
rm -f "$TMP/tient"
out="$(bash -c "$ATTENDRE"'
	SERVICE_NAME=t; source "$ACMECHANIC_HOME/lib/common.sh"
	t="$1"; docker() { echo "docker $*" >>"$t/docker-reel"; }   # jamais le vrai Docker
	avec_verrou_images partage bash -c "touch \"\$1/tient\"; sleep 2" _ "$1" &
	attendre "$1/tient"
	DELAI_VERROU_PARTAGE=0 avec_verrou_images partage true; echo "partage=$?"
	DELAI_VERROU_EXCLUSIF=0 avec_verrou_images exclusif touch "$1/prune-lance"; echo "exclusif=$?"
	DELAI_VERROU_EXCLUSIF=0 nettoyer_images; echo "prune-reporte=$?"
	wait
	DELAI_VERROU_EXCLUSIF=0 avec_verrou_images exclusif true; echo "libere=$?"
	avec_verrou_images partage bash -c "sleep 2 &"
	DELAI_VERROU_EXCLUSIF=0 avec_verrou_images exclusif true; echo "non-legue=$?"
	avec_verrou_images exclusive true; echo "mode=$?"
' _ "$TMP" 2>/dev/null)"
check "un second pull (partage) passe pendant un pull" grep -qx 'partage=0' <<<"$out"
check "un prune (exclusif) ne passe pas pendant un pull (code 75)" grep -qx 'exclusif=75' <<<"$out"
check "commande non lancee sans le verrou" not test -e "$TMP/prune-lance"
check "prune reporte sans echec quand des pulls tournent" grep -qx 'prune-reporte=0' <<<"$out"
check "prune reporte : Docker jamais appele" not test -e "$TMP/docker-reel"
check "verrou libere a la fin de la commande" grep -qx 'libere=0' <<<"$out"
check "verrou non legue aux processus laisses derriere (8>&-)" grep -qx 'non-legue=0' <<<"$out"
check "mode de verrou invalide refuse (code 2)" grep -qx 'mode=2' <<<"$out"
# Delais d'etape = attente du verrou + delai de l'operation (sinon
# run_etape couperait une etape qui attend encore le verrou).
out="$(DELAI_VERROU_PARTAGE=7 DELAI_PULL=100 bash -c 'SERVICE_NAME=t
	source "$ACMECHANIC_HOME/lib/common.sh"
	echo "$(delai_etape_pull) $(delai_etape_up) $(delai_etape_prune) $(delai_etape_prune 5)"
	DELAI_VERROU_EXCLUSIF=11; delai_etape_prune')"
check "delais d'etape : attente du verrou comprise" eq "$out" $'107 187 400 305\n311'
out="$(bash -c 'SERVICE_NAME=t; source "$ACMECHANIC_HOME/lib/common.sh"
	docker() { return 3; }; nettoyer_images 2>/dev/null; echo "rc=$?"')"
check "prune en echec (verrou obtenu) : code de Docker remonte" eq "$out" "rc=3"
# Bouchons : conteneur actif sur une autre image que celle du tag cible
# (changement de tag), registre joignable. etat_verrou : vu de dehors.
MSD_BOUCHONS="$ATTENDRE"'
	SERVICE_NAME=t; source "$ACMECHANIC_HOME/lib/common.sh"
	conteneur_actif() { return 0; }; conteneur_a_jour() { return 1; }
	version_docker() { echo v1; }; digest_image() { echo; }
	digest_registre() { echo sha256:neuf; }; etat_sante() { echo healthy; }
	config_a_jour() { return 0; }
	etat_verrou() {   # libre | partage | exclusif
		local f="$VERROU_DIR/maintenance-docker-prune.lock" x=0 s=0
		flock -n -x "$f" true || x=$?
		flock -n -s "$f" true || s=$?
		if [ "$x" -eq 0 ]; then echo libre
		elif [ "$x" -eq 1 ] && [ "$s" -eq 0 ]; then echo partage
		elif [ "$x" -eq 1 ] && [ "$s" -eq 1 ]; then echo exclusif
		else echo "erreur $x/$s"; fi
	}'
rm -f "$TMP/compose.log"
out="$(bash -c "$MSD_BOUCHONS"'
	docker() { return 1; }   # image cible absente en local
	compose() { echo "$*" >>"$1/compose.log"; [ "$2" != pull ]; }
	maintenir_service_docker "$1" svc "" editeur/app:latest non /d >/dev/null 2>&1
	echo "echecs=$NB_ECHEC"' _ "$TMP")"
check "pull en echec : un seul echec compte" eq "$out" "echecs=1"
check "pull en echec : le pull a bien ete tente" grep -qE ' pull svc$' "$TMP/compose.log"
check "pull en echec, image cible absente : conteneur actif jamais arrete" \
	not grep -qE ' (down|up) ' "$TMP/compose.log"
# Conteneur deja arrete : la garde ne s'applique pas, on tente la creation.
rm -f "$TMP/compose.log"
bash -c "$MSD_BOUCHONS"'
	conteneur_actif() { return 1; }
	docker() { return 1; }
	compose() { echo "$*" >>"$1/compose.log"; [ "$2" != pull ]; }
	maintenir_service_docker "$1" svc "" editeur/app:latest non /d' _ "$TMP" >/dev/null 2>&1
check "conteneur arrete : creation tentee malgre le pull en echec" \
	grep -qE ' up -d --remove-orphans svc$' "$TMP/compose.log"
rm -f "$TMP/compose.log"
out="$(bash -c "$MSD_BOUCHONS"'
	docker() { [ "$1 $2" = "image prune" ]; }   # image absente ; prune OK
	compose() { echo "$*" >>"$1/compose.log"; }   # pull « reussi »
	maintenir_service_docker "$1" svc "" editeur/app:latest non /d >/dev/null 2>&1
	echo "echecs=$NB_ECHEC"' _ "$TMP")"
check "pull reussi mais image absente : echec signale" eq "$out" "echecs=1"
check "pull reussi mais image absente : conteneur jamais arrete" \
	not grep -qE ' (down|up) ' "$TMP/compose.log"
rm -f "$TMP/compose.log"
bash -c "$MSD_BOUCHONS"'
	docker() {   # image cible tiree ; le prune note l etat du verrou
		case "$1 $2" in
		"image prune") echo "image prune [$(etat_verrou)]" >>"$VERROU_DIR/compose.log" ;;
		esac
		return 0
	}
	compose() { echo "$* [$(etat_verrou)]" >>"$1/compose.log"; }
	maintenir_service_docker "$1" svc "" editeur/app:latest non /d' _ "$TMP" >/dev/null 2>&1
out="$(cat "$TMP/compose.log" 2>/dev/null)"
check "pull reussi : arret puis recreation" grep -qE ' down svc \[libre\]' <<<"$out"
check "pull sous verrou partage" grep -qE ' pull svc \[partage\]' <<<"$out"
check "up sous verrou partage (pull implicite des dependances)" grep -qE ' up -d .*svc \[partage\]' <<<"$out"
check "prune sous verrou exclusif" grep -qx 'image prune \[exclusif\]' <<<"$out"
# Delais passes a run_etape, a chaque appel : l'attente du verrou y est
# comprise (delai_etape_*), sinon l'etape serait coupee pendant qu'elle
# attend encore un prune. Le faux run_etape note <libelle>|<delai>.
ETAPES_BOUCHON='
	run_etape() { echo "$1|$2" >>"$ETAPES"; shift 2; "$@"; }
	docker() { return 0; }
	compose() { :; }'
delais_etapes() {  # delais_etapes <bouchons en plus> : etapes d un passage de maintenir_service_docker
	rm -f "$TMP/etapes.log"
	ETAPES="$TMP/etapes.log" DELAI_VERROU_PARTAGE=7 DELAI_PULL=100 ATTENTE_PRUNE_SERVICE=5 \
		bash -c "$MSD_BOUCHONS$ETAPES_BOUCHON$1"'
		maintenir_service_docker "$1" svc "" editeur/app:latest non /d' _ "$TMP" >/dev/null 2>&1
	cat "$TMP/etapes.log" 2>/dev/null
}
out="$(delais_etapes '')"
check "mise a jour : delai du pull, attente du verrou comprise" grep -qx "svc : pull de l'image|107" <<<"$out"
check "mise a jour : delai du redemarrage, attente du verrou comprise" grep -qx 'svc : redemarrage|187' <<<"$out"
check "mise a jour : delai du prune, attente courte comprise" \
	grep -qx 'svc : nettoyage images orphelines|305' <<<"$out"
out="$(delais_etapes '
	conteneur_a_jour() { return 0; }; digest_image() { echo sha256:neuf; }
	config_a_jour() { return 1; }')"
check "recreation : delai du up, attente du verrou comprise" grep -qx 'svc : recreation|187' <<<"$out"
out="$(delais_etapes '
	conteneur_actif() { return 1; }; version_docker() { return 1; }')"
check "conteneur absent : delai du pull, attente du verrou comprise" grep -qx "svc : pull de l'image|107" <<<"$out"
check "conteneur absent : delai du redemarrage, attente du verrou comprise" \
	grep -qx 'svc : redemarrage|187' <<<"$out"
check "conteneur absent : creation sans arret ni prune" not grep -qE 'arret|nettoyage' <<<"$out"
# Des prune tiennent l'exclusif au-dela de DELAI_VERROU_PARTAGE : le
# redemarrage qui suit un arret part quand meme (service jamais coupe).
rm -f "$TMP/compose.log" "$TMP/tient" "$TMP/liberer"
bash -c "$MSD_BOUCHONS"'
	docker() { return 0; }
	compose() { echo "$* [$(etat_verrou)]" >>"$1/compose.log"; }
	trap '\''touch "$1/liberer"'\'' EXIT   # le detenteur part toujours
	avec_verrou_images exclusif bash -c "touch \"\$1/tient\"
		for i in \$(seq 600); do [ -e \"\$1/liberer\" ] && break; sleep 0.05; done" _ "$1" &
	attendre "$1/tient"
	d=$SECONDS
	DELAI_VERROU_PARTAGE=0 DELAI_VERROU_EXCLUSIF=30 ATTENTE_PRUNE_SERVICE=0 \
		maintenir_service_docker "$1" svc "" editeur/app:latest non /d
	echo "duree=$((SECONDS - d))" >>"$1/compose.log"
	touch "$1/liberer"; wait' _ "$TMP" >/dev/null 2>&1
out="$(cat "$TMP/compose.log" 2>/dev/null)"
check "prune apres mise a jour : attente courte, pas DELAI_VERROU_EXCLUSIF" \
	test "$(sed -n 's/^duree=//p' <<<"$out")" -lt 15
check "prune en cours : arret puis redemarrage quand meme" \
	grep -qE ' down svc \[' <<<"$out"
check "prune en cours : le service est relance sans verrou" \
	grep -qE ' up -d --remove-orphans svc \[exclusif\]' <<<"$out"
# Recreation (configuration modifiee, image a jour) : sous verrou partage.
rm -f "$TMP/compose.log"
bash -c "$MSD_BOUCHONS"'
	conteneur_a_jour() { return 0; }; digest_image() { echo sha256:neuf; }
	config_a_jour() { return 1; }   # configuration modifiee : recreation
	docker() { return 0; }
	compose() { echo "$* [$(etat_verrou)]" >>"$1/compose.log"; }
	maintenir_service_docker "$1" svc "" editeur/app:latest non /d' _ "$TMP" >/dev/null 2>&1
check "recreation (configuration modifiee) sous verrou partage" \
	grep -qE ' up -d --force-recreate svc \[partage\]' "$TMP/compose.log"
# Fichier de verrou illisible (autre compte) : « non obtenu », jamais
# un redemarrage abandonne. Sans objet en root (lecture toujours permise).
if [ "$(id -u)" -ne 0 ]; then
	rm -f "$TMP/compose.log"
	out="$(VERROU_DIR="$TMP/illisible" bash -c "$MSD_BOUCHONS"'
		mkdir -p "$VERROU_DIR"; : >"$VERROU_DIR/maintenance-docker-prune.lock"
		chmod 000 "$VERROU_DIR/maintenance-docker-prune.lock"
		avec_verrou_images partage true 2>/dev/null; echo "rc=$?"
		compose() { echo "$*" >>"$1/compose.log"; }
		redemarrer_service "$1" svc >/dev/null 2>&1; echo "redemarrage=$?"' _ "$TMP")"
	check "verrou illisible : code 75" grep -qx 'rc=75' <<<"$out"
	check "verrou illisible : redemarrage reussi" grep -qx 'redemarrage=0' <<<"$out"
	check "verrou illisible : le redemarrage part sans verrou" \
		grep -qE ' up -d --remove-orphans svc$' "$TMP/compose.log"
fi

echo "systeme : fichiers de configuration modifies (dpkg)"
# Passage --systeme de bout en bout, avec un PATH reduit a un dossier de
# liens : le sudo et le gestionnaire de paquets y sont des bouchons (le
# faux sudo note ses arguments et n'execute rien), les vrais sont hors
# d'atteinte. Lance depuis une copie sans local.conf ni depot git : les
# reglages de la machine ne priment pas sur ceux du test.
C="$TMP/copie-systeme"
mkdir -p "$C"
cp -r "$ROOT/acmechanic.sh" "$ROOT/config.sh" "$ROOT/lib" "$ROOT/locale" "$C"/
P="$TMP/path-systeme"
mkdir -p "$P"
IFS=: read -ra dossiers_path <<<"$PATH"
for d in "${dossiers_path[@]}"; do cp -s "$d"/* "$P"/ 2>/dev/null; done
rm -f "$P/sudo" "$P/nala" "$P/apt-get"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"$SUDO_TEMOIN"\n' >"$P/sudo"
chmod +x "$P/sudo"
passage_systeme() {  # passage_systeme <gestionnaire> : affiche la ligne de mise a jour vue par sudo
	printf '#!/bin/sh\n' >"$P/$1"
	chmod +x "$P/$1"
	SUDO_TEMOIN="$TMP/sudo-$1" PATH="$P" SERVICES_DIR="$TMP/vide" ORDRE_DIR="$TMP/vide" \
		ACMECHANIC_AUTO_MAJ=non "$C/acmechanic.sh" --systeme </dev/null >/dev/null 2>&1
	rm -f "$P/$1"
	grep -E " $1 .*upgrade" "$TMP/sudo-$1"
}
for gest in nala apt-get; do
	ligne="$(passage_systeme "$gest")"
	check "$gest : mise a jour lancee, sans question (noninteractive, -y)" \
		grep -qE "^-n env DEBIAN_FRONTEND=noninteractive $gest .*-y" <<<"$ligne"
	check "$gest : fichier de configuration modifie garde (--force-confold)" \
		grep -q -- ' -o Dpkg::Options::=--force-confold' <<<"$ligne"
	check "$gest : choix par defaut de dpkg quand il existe (--force-confdef)" \
		grep -q -- ' -o Dpkg::Options::=--force-confdef' <<<"$ligne"
done

echo "verrou des images : ouverture en echec apres le controle"
# Le fichier est lisible, mais son ouverture sur le descripteur 8 echoue
# (limite de descripteurs) : meme classe que le fichier qui disparait
# entre le controle et l'ouverture. Attendu : « non obtenu » (75), donc
# un redemarrage qui part quand meme, sans verrou.
rm -f "$TMP/compose.log"
out="$(bash -c '
	SERVICE_NAME=test-ouverture
	source "$ACMECHANIC_HOME/lib/common.sh"
	: >"$VERROU_DIR/maintenance-docker-prune.lock"
	compose() { echo "$*" >>"$1/compose.log"; }
	exec 3>&- 4>&- 5>&- 6>&- 7>&-   # descripteurs legues par le lanceur
	ulimit -n 8
	avec_verrou_images partage true 2>/dev/null; echo "rc=$?"
	demarrer_service "$1" svc >/dev/null 2>&1; echo "demarrage=$?"' _ "$TMP")"
check "ouverture du verrou en echec : code 75" grep -qx 'rc=75' <<<"$out"
check "ouverture du verrou en echec : le service est relance" grep -qx 'demarrage=0' <<<"$out"
check "ouverture du verrou en echec : relance sans verrou" \
	grep -qE ' up -d svc$' "$TMP/compose.log"

echo "verrou : execution deja en cours"
# Le verrou est tenu par un autre processus : arret, et un conseil qui ne
# fait pas supprimer le fichier (un processus qui le tient encore
# garderait son verrou sur l'ancien fichier : exclusion rompue).
mkdir -p "$TMP/verrou-tenu"
# flock -o : le detenteur ne legue pas son descripteur au script refuse.
flock -x -o "$TMP/verrou-tenu/maintenance-test-tenu.lock" \
	env VERROU_DIR="$TMP/verrou-tenu" bash -c '
	SERVICE_NAME=test-tenu
	source "$ACMECHANIC_HOME/lib/common.sh"
	prendre_verrou
	echo "suite sans verrou" >"$VERROU_DIR/suite"' >/dev/null 2>&1
check "verrou tenu : arret, code 1" eq "$?" 1
check "verrou tenu : rien ne tourne sans verrou" not test -e "$TMP/verrou-tenu/suite"
check "verrou tenu : conseil de chercher le processus" \
	grep -q 'ERREUR .*fuser -v' "$LOG_DIR/test-tenu.log"
check "verrou tenu : ne conseille plus de supprimer le verrou" \
	not grep -q 'ou supprimez le verrou' "$LOG_DIR/test-tenu.log"
if command -v fuser >/dev/null 2>&1; then
	check "verrou tenu : seul le detenteur est liste, pas le script refuse" \
		grep -qE 'processus : [0-9]+\)$' "$LOG_DIR/test-tenu.log"
fi

echo "verrou : dossier des verrous absent"
out="$(VERROU_DIR="$TMP/absent" bash -c '
	SERVICE_NAME=test-verrou
	source "$ACMECHANIC_HOME/lib/common.sh"
	prendre_verrou
	echo "suite sans verrou"' 2>&1)"
rc=$?
check "dossier des verrous absent : arret, code 1" eq "$rc" 1
check "dossier des verrous absent : rien ne tourne sans verrou" not grep -q 'suite sans verrou' <<<"$out"
check "dossier des verrous absent : VERROU_DIR nomme au journal" \
	grep -q 'ERREUR .*VERROU_DIR' "$LOG_DIR/test-verrou.log"
# Fichier de verrou d'un autre compte (ici : sans droit d'ecriture), dans
# un dossier correct. Sans objet en root (ecriture toujours permise).
if [ "$(id -u)" -ne 0 ]; then
	mkdir -p "$TMP/verrou-autre" && : >"$TMP/verrou-autre/maintenance-test-autre.lock"
	chmod 444 "$TMP/verrou-autre/maintenance-test-autre.lock"
	VERROU_DIR="$TMP/verrou-autre" bash -c '
		SERVICE_NAME=test-autre
		source "$ACMECHANIC_HOME/lib/common.sh"
		prendre_verrou
		echo "suite sans verrou" >"$VERROU_DIR/suite"' >/dev/null 2>&1
	check "fichier de verrou d'un autre compte : arret, code 1" eq "$?" 1
	check "fichier de verrou d'un autre compte : rien ne tourne sans verrou" \
		not test -e "$TMP/verrou-autre/suite"
	check "fichier de verrou d'un autre compte : cause nommee au journal" \
		grep -q 'ERREUR .*autre compte' "$LOG_DIR/test-autre.log"
fi

echo "journal : sorties lisibles"
# Tache anticipee d'un passage --systeme : au journal, le marqueur
# d'etape est separe de son texte.
passage_systeme apt-get >/dev/null
check "tache anticipee : marqueur separe du texte au journal" \
	not grep -qE '^(ETAPE|OK|ERREUR)[^ ]' "$LOG_DIR/acmechanic.log"
check "tache anticipee : son etape est au journal" \
	grep -qE '^ETAPE : .*apt-get update' "$LOG_DIR/acmechanic.log"
# Service en echec : la fin de sa sortie est gardee au journal (le
# fichier <service>.sortie est ecrase au passage suivant).
SK="$TMP/services-ko"
mkdir -p "$SK/enpanne"
printf '#!/bin/bash\nSERVICE_NAME=enpanne\nsource "${ACMECHANIC_HOME}/lib/common.sh"\nprintf "\\037ERREUR\\037etape-en-panne\\n"\nfor i in $(seq 25); do echo "remplissage-$i"; done\nprintf "\\033]0;titre\\007\\033[31mtrace-de-la-panne\\033(B\\033[0m\\n"\nprintf "octet\\0nul\\n"\nexit 1\n' \
	>"$SK/enpanne/enpanne.sh"
chmod +x "$SK/enpanne/enpanne.sh"
# Bouchons en tete du PATH : ni sudo, ni Docker, ni reseau (un passage
# avec un service detecte prechauffe le cache du registre).
BK="$TMP/bouchons-ko"
mkdir -p "$BK"
for c in sudo docker curl; do
	printf '#!/bin/sh\necho "$0 $*" >>"%s/appels"\n' "$BK" >"$BK/$c"
	chmod +x "$BK/$c"
done
# Sous fr_FR.UTF-8 quand elle existe (la CI la genere) : les plages de
# sed dependent de la collation, et celle-ci refuse [0-?].
locale_reelle="$(locale -a 2>/dev/null | grep -iE '^fr_FR\.utf-?8$' | head -n 1)"
LC_ALL="${locale_reelle:-$LC_ALL}" PATH="$BK:$PATH" SERVICES_DIR="$SK" ORDRE_DIR="$TMP/vide" \
	ACMECHANIC_AUTO_MAJ=non "$C/acmechanic.sh" --services </dev/null >/dev/null 2>"$TMP/enpanne.err"
check "service en echec : passage en echec" eq "$?" 1
check "service en echec : le sudo appele est le bouchon" grep -q "^$BK/sudo " "$BK/appels"
check "service en echec : le docker appele est le bouchon" grep -q "^$BK/docker " "$BK/appels"
check "service en echec : fin de sa sortie au journal, sans sequences de terminal" \
	grep -q '^    trace-de-la-panne$' "$LOG_DIR/acmechanic.log"
# L'etape en echec, loin de la fin (25 lignes apres elle), reste dans
# l'extrait ; les lignes sautees sont marquees.
check "service en echec : etape en echec gardee, loin de la fin" \
	grep -q '^    ERREUR : etape-en-panne$' "$LOG_DIR/acmechanic.log"
check "service en echec : saut marque" grep -q '^    \[\.\.\.\]$' "$LOG_DIR/acmechanic.log"
check "service en echec : lignes hors des 20 dernieres sautees" \
	not grep -q '^    remplissage-7$' "$LOG_DIR/acmechanic.log"
check "service en echec : 20 dernieres lignes gardees" \
	grep -q '^    remplissage-8$' "$LOG_DIR/acmechanic.log"
check "service en echec : octet nul retire" grep -q '^    octetnul$' "$LOG_DIR/acmechanic.log"
check "service en echec : octet nul retire avant bash, sans avertissement" \
	not grep -qiE 'null byte|octet nul' "$TMP/enpanne.err"

echo "restore.sh : redemarrage sous le verrou des images"
# Restauration de bout en bout d'un service Docker, depuis une copie avec
# son propre local.conf ; le faux docker (en tete du PATH) note chaque
# appel et l'etat du verrou des images vu de dehors.
R="$TMP/restore"
mkdir -p "$R/acm" "$R/bin" "$R/projet" "$R/donnees" "$R/source" "$R/sauvegardes/appli" "$R/verrou"
cp -r "$ROOT/restore.sh" "$ROOT/config.sh" "$ROOT/lib" "$ROOT/locale" "$R/acm"/
cat >"$R/acm/local.conf" <<FIN
SERVICES_CONNUS=(appli)
config_service() {
	case "\$2" in
	type) echo docker ;;
	cible) echo "$R/donnees" ;;
	projet) echo "$R/projet" ;;
	conteneur) echo appli ;;
	esac
}
FIN
echo ancien >"$R/donnees/fichier"
echo restaure >"$R/source/fichier"
tar czf "$R/sauvegardes/appli/appli_2026-01-01_00-00-00.tar.gz" -C "$R/source" fichier
cat >"$R/bin/docker" <<'FIN'
#!/usr/bin/env bash
f="$VERROU_DIR/maintenance-docker-prune.lock" etat=libre
if [ -e "$f" ] && ! flock -n -x "$f" true; then
	etat=exclusif
	flock -n -s "$f" true && etat=partage
fi
echo "$* [$etat]" >>"$DOCKER_TEMOIN"
FIN
chmod +x "$R/bin/docker"
DOCKER_TEMOIN="$R/docker.log" PATH="$R/bin:$PATH" BACKUP_ROOT="$R/sauvegardes" VERROU_DIR="$R/verrou" \
	"$R/acm/restore.sh" appli 1 <<<oui >/dev/null 2>&1
check "restore.sh : donnees restaurees" eq "$(cat "$R/donnees/fichier" 2>/dev/null)" restaure
check "restore.sh : conteneur arrete avant la restauration" \
	grep -qE '^compose .* stop appli \[' "$R/docker.log"
check "restore.sh : redemarrage sous verrou partage, sans rien retirer" \
	grep -qE '^compose .* up -d appli \[partage\]$' "$R/docker.log"
# Un prune en cours (verrou exclusif) : l'attente est dite a l'ecran. Le
# faux prune ne rend le verrou qu'une fois cette annonce vue (30 s au plus).
rm -f "$R/docker.log"
: >"$R/ecran"
flock -x "$R/verrou/maintenance-docker-prune.lock" timeout 30 bash -c '
	until grep -q "En attente du verrou" "$1"; do sleep 0.2; done' _ "$R/ecran" &
for _ in $(seq 100); do   # 10 s au plus : le faux prune tient le verrou
	flock -n -x "$R/verrou/maintenance-docker-prune.lock" true || break
	sleep 0.1
done
DOCKER_TEMOIN="$R/docker.log" PATH="$R/bin:$PATH" BACKUP_ROOT="$R/sauvegardes" VERROU_DIR="$R/verrou" \
	"$R/acm/restore.sh" appli 1 <<<oui >"$R/ecran" 2>&1
wait
check "restore.sh : attente du verrou annoncee a l'ecran" grep -q 'En attente du verrou' "$R/ecran"
check "restore.sh : redemarrage une fois le prune fini" \
	grep -qE '^compose .* up -d appli \[partage\]$' "$R/docker.log"

echo
echo "Resultat : $PASS ok, $FAIL echec(s)"
[ "$FAIL" -eq 0 ]
