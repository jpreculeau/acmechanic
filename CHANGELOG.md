# Changelog

Toutes les évolutions notables d'Acmechanic sont consignées ici.
Format inspiré de [Keep a Changelog](https://keepachangelog.com/fr/1.1.0/), versions [SemVer](https://semver.org/lang/fr/).

## [1.0.0] - 2026-09-28

Première version publique, extraite d'un usage quotidien sur Raspberry Pi.

### Ajouté
- Orchestrateur `acmechanic.sh` : découverte automatique des services (`<nom>/<nom>.sh` sourçant `lib/common.sh`), ordre imposable par liens `ordre.d/NN-<nom>.sh`, exécution parallèle bornée (cgroup `systemd-run --user`, `nice`, `ionice`), mise à jour système Nala/APT avec rafraîchissement anticipé des dépôts.
- Gate Docker `maintenir_service_docker` : pull uniquement si le digest Docker Hub diffère, si la config compose a changé (`config --hash`), si le conteneur est arrêté ou tourne une ancienne image ; attente du `healthy` Docker ; cache du registre préchauffé en une connexion.
- Sauvegardes `.tar.gz` + manifeste SHA-256, rotation, `restore.sh` interactif (Docker, Flatpak, fichiers) avec mise de côté de l'état précédent.
- Tableau fixe (`lib/tableau.sh`) : cases pré-dimensionnées selon la fenêtre, icônes Nerd Font, 16 couleurs du thème du terminal, pastilles de statut, bilan des versions avant → après.
- Arrêt propre de tout l'arbre sur Ctrl+C / fermeture du terminal, watchdog anti-fige, verrous `flock`.
- `config.sh` + `local.conf` (ignoré par git), modèles `examples/services/` (Docker Compose, Flatpak), `make lint test`, CI GitHub Actions.
