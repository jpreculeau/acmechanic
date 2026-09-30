# Changelog

Toutes les évolutions notables d'Acmechanic sont consignées ici.
Format inspiré de [Keep a Changelog](https://keepachangelog.com/fr/1.1.0/), versions [SemVer](https://semver.org/lang/fr/).

## [1.1.0] - 2026-09-29

### Ajouté
- Bibliothèque : `plex`, `audiobookshelf`, `vaultwarden`, `uptime-kuma`, `forgejo`, `portainer`, `open-webui` (script + `docker-compose.yml` modèle).
- Maintenance de la machine : `depots-git` (vos dépôts git en avance rapide, nouveautés chezmoi signalées), `outils-ia` (Claude Code, CLI npm, uv/pipx, pi.dev, Hermes ; Ollama signalé), `micrologiciel` (EEPROM Raspberry Pi et fwupd, signalés sans flasher), `nettoyage` (Docker sans volumes, journal, cache des paquets, journaux, vignettes), `acmefrag` (mise à jour, tests, mesure `--dry-run`).
- Auto-mise à jour d'Acmechanic en fin de run (`ACMECHANIC_AUTO_MAJ=oui|signaler|non`).
- `etape` (lib/service.sh) : comme `run_etape`, mais renvoie 1 en cas d'échec.
- `ROADMAP.md` : 1.5 multi-distributions (dnf, pacman, zypper, apk).
- Thèmes d'affichage en français et en anglais : `droides`, `kaiju`, `matrice`, `cyborg`, `delorean`, `vaisseau` (`ACMECHANIC_THEME`, aperçu : `acmechanic --themes`).
- Langues : catalogues `locale/fr.sh` et `locale/en.sh`, `ACMECHANIC_LANGUE`, autres langues par simple catalogue (test de complétude).
- Points d'attention : `point_attention "message" "commande"` pour tout service, regroupés en fin de passage (redémarrage requis, micrologiciel, auto-mise à jour non appliquée…).
- `bureau` : gestionnaire de fenêtres et barre de menu (ex. nwg-panel installé depuis git avec des correctifs locaux : fusion des branches, `git rerere`, retour arrière, relance proposée).
- `outils-ia` : mise à jour d'Ollama par l'installeur officiel (`OLLAMA_MAJ=oui`), état du service conservé, retour à l'ancienne version en cas d'échec.
- Actions proposées : en fin de passage, chaque commande des points d'attention est proposée (non par défaut, redémarrage en dernier, rien hors terminal) ; `acmechanic --actions` les repropose ; `ACMECHANIC_PROPOSER=non` pour désactiver.
- Ascenseur à la molette et au clavier (flèches, Page préc./suiv., Début/Fin), reprise du suivi automatique après 20 s (`ACMECHANIC_DEFIL_PAUSE`) ; `ACMECHANIC_SOURIS=non` pour garder la sélection à la souris.
- Écran vidé en toute première action (affichage fixe).
- Ascenseur : au moins `ACMECHANIC_LIGNES_MIN` (6) lignes par cadre ; si la grille dépasse l'écran, elle défile et les services terminés sont poussés vers le haut. Une dernière rangée incomplète prend toute la largeur.
- Cadres rangés du plus rapide au plus lent selon les durées réelles du passage précédent (`~/logs/acmechanic/durees`).

### Modifié
- Cadres : lignes colorées et iconées selon leur niveau, comme à l'écran, sans horodatage ; l'écran en mode ligne à ligne perd aussi l'horodatage (gardé au journal).
- Bilan : services par statut (mis à jour, inchangés, en échec…) puis total des étapes, au lieu d'un « réussies » ambigu.
- Versions : seule la partie qui change est colorée (façon nala) ; une version trop longue passe à la ligne.
- Icônes de cadre pour tous les services de la bibliothèque ; `ICONES_SERVICES` (local.conf) pour les vôtres.

## [1.0.0] - 2026-09-28

Première version publique, extraite d'un usage quotidien sur Raspberry Pi.

### Ajouté
- Orchestrateur `acmechanic.sh` : découverte automatique des services (`<nom>/<nom>.sh` sourçant `lib/common.sh`), ordre imposable par liens `ordre.d/NN-<nom>.sh`, exécution parallèle bornée (cgroup `systemd-run --user`, `nice`, `ionice`), mise à jour système Nala/APT avec rafraîchissement anticipé des dépôts.
- Gate Docker `maintenir_service_docker` : pull uniquement si le digest Docker Hub diffère, si la config compose a changé (`config --hash`), si le conteneur est arrêté ou tourne une ancienne image ; attente du `healthy` Docker ; cache du registre préchauffé en une connexion.
- Sauvegardes `.tar.gz` + manifeste SHA-256, rotation, `restore.sh` interactif (Docker, Flatpak, fichiers) avec mise de côté de l'état précédent.
- Tableau fixe (`lib/tableau.sh`) : cases pré-dimensionnées selon la fenêtre, icônes Nerd Font, 16 couleurs du thème du terminal, pastilles de statut, bilan des versions avant → après.
- Arrêt propre de tout l'arbre sur Ctrl+C / fermeture du terminal, watchdog anti-fige, verrous `flock`.
- Bibliothèque de services standardisés (`bibliotheque/`) : Jellyfin, *arr, Syncthing, cross-seed, Beszel, Flatpak et `_modele`, chacun avec un `docker-compose.yml` modèle ; socle `lib/service.sh` (`docker_preparer`, `docker_standard`, `docker_terminer`) et convention `<NOM>_PROJET/_DONNEES/_URL/_CANAL`.
- Services activables par lien symbolique (`find -L`), fichier compose non standard via `COMPOSE_FICHIER`, digests des images officielles (`nginx`, `library/nginx`) reconnus.
- `config.sh` + `local.conf` (ignoré par git), `make lint test`, CI GitHub Actions.
