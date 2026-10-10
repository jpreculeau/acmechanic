# Changelog

Toutes les évolutions notables d'Acmechanic sont consignées ici.
Format inspiré de [Keep a Changelog](https://keepachangelog.com/fr/1.1.0/), versions [SemVer](https://semver.org/lang/fr/).

## [Non publié]

### Ajouté
- Questions avec décompte : sans réponse dans `ACMECHANIC_DELAI_REPONSE` secondes (30 par défaut, `0` = sans limite), la réponse par défaut (non) s'applique.
- Tâches anticipées visibles : le rafraîchissement des dépôts lancé pendant les services s'affiche dans la case « systeme » dès qu'il tourne ; il vaut désormais pour APT comme pour Nala.

### Modifié
- Service `bureau` renommé **`session-graphique`** (plus explicite : compositeur Wayland et barre). Réglages : `SESSION_GRAPHIQUE_PIP_GIT`, `SESSION_GRAPHIQUE_ETAT` ; les anciens `BUREAU_PIP_GIT` / `BUREAU_ETAT` restent lus. Mise à jour d'une installation : remplacer le lien `bureau` par `ln -s bibliotheque/session-graphique session-graphique`.

### Corrigé
- Mise à jour du système (Nala comme APT) en échec quand un paquet apporte une nouvelle version d'un fichier de configuration modifié sur la machine : dpkg posait une question, sans personne pour y répondre. Elle est désormais lancée avec `--force-confdef --force-confold` : le fichier modifié est gardé tel quel, et la version du paquet est posée à côté, en `.dpkg-dist`.
- Pulls Docker tués par un `docker image prune` lancé en parallèle (magasin d'images containerd, par défaut sur les installations neuves de Docker 29 : le prune supprime les baux de **tous** les pulls en cours ; erreurs « lease does not exist », « content digest not found »). Les `compose pull` et `compose up` lancés par Acmechanic prennent désormais un verrou partagé et les prune un verrou exclusif (`avec_verrou_images`) : un pull ou un `up` n'attend que les prune en cours (`DELAI_VERROU_PARTAGE`, défaut 120 s) ; au-delà, un pull ou une recréation (sans arrêt préalable) est compté en échec et retenté au passage suivant, un redémarrage après arrêt part sans verrou plutôt que de laisser le service coupé. Le prune de `nettoyage` attend qu'aucun pull ne tourne (`DELAI_VERROU_EXCLUSIF`, défaut `DELAI_PULL`), celui qui suit la mise à jour d'un service 60 s au plus ; au-delà, il est reporté sans échec (`nettoyage` peut donc durer plus longtemps). Le fichier de verrou suit désormais `VERROU_DIR` (défaut `/tmp`, inchangé) ; un fichier impossible à créer ou illisible vaut « verrou non obtenu ».
- `restore.sh` : le redémarrage du conteneur après une restauration prend lui aussi le verrou des images (`demarrer_service`) ; la sortie d'erreur de ce redémarrage (attente d'un prune en cours, erreurs de `compose up`) s'affiche désormais à l'écran en plus du journal.
- Verrou des images : un fichier de verrou qui disparaît, ou dont l'ouverture échoue, juste après avoir été contrôlé valait un échec ordinaire au lieu de « verrou non obtenu » ; après un arrêt, le service n'était alors pas relancé. Il est désormais relancé sans verrou, comme dans les autres cas où le verrou manque.
- Exécution déjà en cours : le message ne conseille plus de supprimer le fichier de verrou (le processus qui le tient garderait son verrou sur l'ancien fichier, et deux exécutions pourraient tourner à la fois) ; il indique comment trouver ce processus (`fuser -v`), et la liste des processus affichée ne contient plus le script refusé lui-même.
- Fichier de verrou d'un script (`prendre_verrou`) impossible à ouvrir (dossier `VERROU_DIR` absent ou non inscriptible, fichier laissé par un autre compte) : l'orchestrateur et les services qui sourcent `lib/service.sh` s'arrêtent aussitôt avec une erreur explicite, au lieu de continuer sans verrou (deux exécutions simultanées devenaient possibles).
- `maintenir_service_docker` : un conteneur en service n'est plus jamais arrêté quand l'image cible est absente en local après le pull (pull en échec, changement de tag) ; il reste sur son image actuelle jusqu'au passage suivant. Un pull réussi qui ne fournit pas l'image attendue (image du compose différente) est signalé en échec.

## [1.1.0] - 2026-09-29

### Ajouté
- Bibliothèque : `plex`, `audiobookshelf`, `vaultwarden`, `uptime-kuma`, `forgejo`, `portainer`, `open-webui` (script + `docker-compose.yml` modèle).
- Maintenance de la machine : `depots-git` (vos dépôts git en avance rapide, nouveautés chezmoi signalées), `outils-ia` (Claude Code, CLI npm, uv/pipx, pi.dev, Hermes ; Ollama signalé), `micrologiciel` (EEPROM Raspberry Pi et fwupd, signalés sans flasher), `nettoyage` (Docker sans volumes, journal, cache des paquets, journaux, vignettes), `acmefrag` (mise à jour, tests, mesure `--dry-run`).
- Auto-mise à jour d'Acmechanic en fin de run (`ACMECHANIC_AUTO_MAJ=oui|signaler|non`).
- `etape` (lib/service.sh) : comme `run_etape`, mais renvoie 1 en cas d'échec.
- `ROADMAP.md` : 1.5 multi-distributions (dnf, pacman, zypper, apk).
- `ACMECHANIC_THEME=hasard` et `ACMECHANIC_LANGUE=hasard` : thème / langue tirés au sort à chaque passage (tirage stable pendant le passage).
- Thèmes d'affichage en français et en anglais : `starwars`, `godzilla`, `matrix`, `terminator`, `delorean`, `enterprise` — répliques des films (VF et VO), couleurs et icône propres (`locale/themes/<thème>/style.sh`) ; `ACMECHANIC_THEME`, aperçu : `acmechanic --themes`.
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
