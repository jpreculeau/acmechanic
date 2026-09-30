# 🔧 ACMECHANIC

> **Le mécano ACME de votre serveur maison** — une seule commande pour sauvegarder, mettre à jour et vérifier vos conteneurs, vos Flatpak et le système. *Bip bip !*

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![Bash](https://img.shields.io/badge/bash-%23121011.svg?style=flat&logo=gnu-bash&logoColor=white)](https://www.gnu.org/software/bash/)
[![Platform](https://img.shields.io/badge/platform-Raspberry%20Pi%20%7C%20Debian-red)](https://www.raspberrypi.org/)
[![Version](https://img.shields.io/badge/version-1.1.0-green.svg)](CHANGELOG.md)

## 📖 Description

**ACMECHANIC** orchestre la maintenance d'un petit serveur (Raspberry Pi, NAS maison, mini-PC Debian) : chaque service est **sauvegardé**, **mis à jour seulement s'il y a du nouveau**, **relancé** puis **contrôlé** (healthcheck Docker ou sonde HTTP). Les services tournent **en parallèle**, bridés en CPU/RAM/E/S pour que la machine reste réactive, et le tout s'affiche dans un **tableau fixe façon dessin animé** aux couleurs de votre terminal.

### 🎬 Cas d'usage

- **Serveur maison** avec une poignée de conteneurs Docker Compose à tenir à jour sans casse
- **Raspberry Pi** où un `docker compose pull` de tout le parc fige le bureau
- **Mises à jour sans surveillance** (cron, timer systemd) avec sauvegarde restaurable avant chaque changement

### ✨ Fonctionnalités

- 📚 **Bibliothèque de services** standardisés : Jellyfin, Plex, *arr, Syncthing, Vaultwarden, Forgejo, Open WebUI… — réglables sans toucher au code
- 🧹 **Maintenance de la machine** : vos dépôts git, outils d'IA, micrologiciel (signalé), nettoyage prudent, [AcmeFrag](https://github.com/jpreculeau/AcmeFrag)
- 🔄 **Auto-mise à jour** d'Acmechanic en fin de run (avance rapide, jamais sur des modifications locales)
- 🔍 **Découverte automatique** : tout script `services/<nom>/<nom>.sh` qui source `lib/common.sh` est un service — rien à déclarer
- 🚦 **Mise à jour à bon escient** : l'image n'est tirée que si le registre (Docker Hub) a un digest plus récent, si la config compose a changé, ou si le conteneur est arrêté / tourne une ancienne image
- 💾 **Sauvegardes vérifiables** : archive `.tar.gz` + manifeste SHA-256, rotation, restauration interactive avec filet de sécurité (`restore.sh`)
- 🩺 **Santé réelle** : attente du `healthy` Docker (sonde définie par le service), repli sur une URL
- ⚡ **Parallèle et bridé** : un cgroup `systemd-run --user` par service (CPU, RAM, pids) + `nice`/`ionice`
- 🖥️ **Tableau fixe** : une case par service, rangées du plus rapide (en haut à gauche) au plus lent d'après les durées réelles du passage précédent ; au moins 6 lignes de détail par cadre (`ACMECHANIC_LIGNES_MIN`) avec un ascenseur quand tout ne tient pas (molette, flèches, Page préc./suiv., Début/Fin ; le suivi automatique reprend après 20 s ou avec Fin) : les services terminés, en haut, sont poussés pour laisser voir ceux qui travaillent encore ; une dernière rangée incomplète prend toute la largeur ; lignes colorées comme à l'écran (sans horodatage), icônes Nerd Font, 16 couleurs du thème du terminal
- 🔔 **Points d'attention** : toute action à faire par vous (micrologiciel, redémarrage, mise à jour non appliquée…) est regroupée en fin de passage, avec la commande à lancer — `point_attention` pour vos propres services
- ▶️ **Actions proposées** : en fin de passage, Acmechanic propose de lancer chaque commande (non par défaut, redémarrage en dernier) ; lancé par cron, `acmechanic --actions` les repropose plus tard
- 🔢 **Bilan lisible** : services mis à jour / inchangés / en échec, total des étapes, et versions dont seule la partie qui change est mise en évidence (façon nala)
- 🌍 **Multilingue** : français et anglais (textes « dessin animé » compris), autres langues par simple catalogue
- 🛡️ **Robuste** : verrous `flock`, délais par étape, watchdog anti-fige, Ctrl+C / fermeture de terminal qui arrêtent proprement tout l'arbre
- 🐧 **Système** : Nala (ou APT en repli), rafraîchissement des dépôts anticipé pendant les services, signalement du redémarrage requis

## 🚀 Installation

```bash
git clone https://github.com/jpreculeau/acmechanic.git ~/acmechanic
cd ~/acmechanic
cp local.conf.example local.conf        # réglages machine (optionnel)

# Activer des services de la bibliothèque (liens : suivent les mises à jour)
ln -s "$PWD/bibliotheque/jellyfin" services/jellyfin
ln -s "$PWD/bibliotheque/flatpak"  services/flatpak
acmechanic --liste                      # vérifier la détection

# Optionnel : commande globale
sudo ln -s ~/acmechanic/acmechanic.sh /usr/local/bin/acmechanic
```

**Dépendances** : `bash` ≥ 5, `docker` + plugin `compose`, `curl`, `tar`, `flock`, `timeout` (coreutils). Optionnel : `nala`, `flatpak`, `systemd-run` (bridage), une [Nerd Font](https://www.nerdfonts.com/) pour les icônes.

Pour les mises à jour système, `sudo` doit être utilisable sans mot de passe (`sudo -v` avant de lancer, ou règle `sudoers` dédiée) ; sinon ces étapes sont simplement **ignorées**.

## 💻 Utilisation

```bash
acmechanic              # services, puis système
acmechanic --liste      # ce qui serait fait, sans rien faire
./restore.sh            # sauvegardes disponibles
./restore.sh mon-app    # choisir une archive et restaurer
```

| Option | Description |
|---|---|
| *(aucune)* | Services en parallèle, puis mise à jour du système |
| `--services` | Uniquement les services |
| `--systeme` | Uniquement le système (Nala, ou APT) |
| `--liste` | Services détectés, écartés, ordre imposé — sans rien exécuter |
| `--themes` | Aperçu des thèmes d'affichage |
| `--actions` | Reproposer les actions du dernier passage (points d'attention) |
| `--version` | Version |
| `--aide`, `-h` | Aide |

Le code de sortie est le **nombre d'étapes en échec** (0 = tout va bien) : pratique en cron.

| Variable d'environnement | Effet |
|---|---|
| `ACMECHANIC_TABLEAU=non` | Affichage ligne à ligne (automatique hors terminal) |
| `ACMECHANIC_ICONES=non` | Symboles Unicode simples au lieu des icônes Nerd Font |
| `LIMITES_RESSOURCES=non` | Pas de cgroup ni de `nice`/`ionice` |
| `ACMECHANIC_PROPOSER=non` | Ne pas proposer de lancer les actions en fin de passage |
| `ACMECHANIC_SOURIS=non` | Pas de défilement à la molette (garde la sélection de texte à la souris) |
| `ACMECHANIC_LIGNES_MIN=8` | Lignes de détail minimum par cadre (défaut 6) ; au-delà de l'écran, la grille défile |
| `ACMECHANIC_THEME=kaiju` | Thème d'affichage (`acmechanic --themes` pour la liste) |
| `ACMECHANIC_LANGUE=en` | Langue de l'affichage (`fr`, `en`… ; défaut : celle du système, anglais à défaut) |
| `ACMECHANIC_AUTO_MAJ=signaler` | Prévenir d'une nouvelle version d'Acmechanic sans l'appliquer (`non` : ne rien faire) |

### 📚 Bibliothèque et services maison

La [bibliothèque](bibliotheque/README.md) fournit une vingtaine de services prêts à l'emploi : services Docker (Jellyfin, Plex, *arr, Syncthing, Vaultwarden, Forgejo, Open WebUI…) avec leur `docker-compose.yml` modèle, et maintenance de la machine (dépôts git, outils d'IA, micrologiciel, nettoyage, AcmeFrag, Flatpak). On les active par un lien dans `services/`, et on les règle dans `local.conf` selon une convention unique : `<NOM>_PROJET`, `<NOM>_DONNEES`, `<NOM>_URL`, `<NOM>_CANAL`.

Un service maison est un script `services/<nom>/<nom>.sh`, exécutable, qui source `lib/service.sh` (ou `lib/common.sh`). Le plus simple : partir de [`bibliotheque/_modele`](bibliotheque/_modele/). Briques disponibles : `docker_standard`, `point_attention "message" "commande"`, `run_etape "libellé" <délai> cmd...`, `ignorer_etape`, `log`/`ok`/`warn`/`err`, `enregistrer_version`, `creer_sauvegarde`.

Pour imposer un ordre : `ln -s ../services/a/a.sh ordre.d/10-a.sh` (les services liés passent d'abord, dans l'ordre des préfixes).

## 🌍 Langues

Les textes affichés viennent de catalogues `locale/<langue>.sh` : `fr.sh` (référence) et `en.sh`. La langue suit `ACMECHANIC_LANGUE`, sinon celle du système (`LANG`), et l'anglais s'il n'existe pas de catalogue. **Thèmes** : `acmechanic --themes` montre un aperçu de chacun, `ACMECHANIC_THEME=<thème>` dans `local.conf` l'active. Chaque thème existe en français et en anglais et ne remplace que les textes « fun » (statuts, onomatopées, fin) :

| Thème | Univers | Exemple de fin |
|---|---|---|
| `acme` *(défaut)* | dessin animé | Rideau ! Tout est en ordre. |
| `droides` | droïdes de protocole et d'astromécanique | Bip-bouip ! Les droïdes ont tout réparé. |
| `kaiju` | monstre géant sorti de l'océan | Le monstre retourne à l'océan. Tokyo est sauvée. |
| `matrice` | réalité simulée, code vert | Vous êtes libéré. Tout est en ordre. |
| `cyborg` | cyborg venu du futur | Mission accomplie. Je reviendrai. |
| `delorean` | voiture à remonter le temps | Des mises à jour ? Là où on va, on n'en a pas besoin. |
| `vaisseau` | vaisseau d'exploration spatiale | Journal de bord : tous les systèmes sont opérationnels. |

Les thèmes sont des clins d'œil de fans, sans lien avec les ayants droit des univers évoqués. Nouveau thème : un dossier `locale/themes/<nom>/` avec `fr.sh` et `en.sh` (voir un thème existant) ; `make test` vérifie les clés.

**Ajouter une langue** : copier `locale/en.sh` en `locale/<code>.sh`, traduire, `make test` vérifie qu'aucune clé ne manque. Les messages du journal restent en français pour l'instant (voir la [feuille de route](ROADMAP.md)).

## ⚙️ Configuration

Ne modifiez pas `config.sh` : surchargez ses variables dans **`local.conf`** (ignoré par git) ou `/etc/acmechanic.conf`.

| Variable | Défaut | Rôle |
|---|---|---|
| `SERVICES_DIR` | `<acmechanic>/services` | Dossier scanné (`<nom>/<nom>.sh`) |
| `SERVICES_EXTRA_DIRS` | `()` | Dossiers scannés en plus |
| `ORDRE_DIR` | `<acmechanic>/ordre.d` | Liens `NN-<nom>.sh` imposant l'ordre |
| `EXCLUS` | `(acmechanic restore)` | Scripts jamais lancés comme services |
| `DELAI_SERVICE` | `3000` | Délai max d'un service (s) |
| `DELAI_SYSTEME` | `1800` | Délai max de l'upgrade système (s) |
| `BACKUP_ROOT` | `~/backups` | Racine des sauvegardes |
| `BACKUP_GARDER` | `5` | Archives conservées par service |
| `LIMITE_CPU` / `LIMITE_RAM_SOUPLE` / `LIMITE_RAM_DURE` | `200%` / `1G` / `2G` | Bornes du cgroup de chaque service |
| `FLATPAK_SAUVEGARDES` | `()` | `nom:identifiant.flatpak` à sauvegarder |
| `SERVICES_CONNUS` + `config_service()` | vides | Services restaurables par `restore.sh` |

**Priorité** : `local.conf` > `/etc/acmechanic.conf` > variables d'environnement > défauts.

## 🏗️ Architecture

```
acmechanic/
├── acmechanic.sh          # orchestrateur : découverte, parallèle, tableau, système
├── restore.sh             # restauration interactive
├── config.sh              # défauts (+ local.conf)
├── local.conf.example
├── lib/
│   ├── common.sh          # journal, verrous, étapes, bridage, registre, gate Docker
│   ├── backup.sh          # archives + manifeste SHA-256 + rotation
│   ├── service.sh         # socle des services (docker_standard...)
│   └── i18n.sh            # langues (t, tv)
├── locale/                # catalogues fr.sh (référence), en.sh, themes/
│   └── tableau.sh         # affichage fixe (cases, icônes, couleurs)
├── services/              # VOS services (ignorés par git)
├── ordre.d/               # liens d'ordre (ignorés par git)
├── bibliotheque/          # services prêts à l'emploi + _modele
├── ROADMAP.md
└── tests/run_tests.sh
```

```bash
make lint    # shellcheck
make test    # tests unitaires (sans root, sans Docker, sans réseau)
make check   # les deux
```

## 🐛 Dépannage

| Symptôme | Piste |
|---|---|
| Icônes en carrés ou `?` | Installer une Nerd Font dans le terminal, ou `ACMECHANIC_ICONES=non` |
| Pas de tableau | Sortie non-terminal, fenêtre trop petite, ou `ACMECHANIC_TABLEAU=non` |
| « sudo demande un mot de passe » | `sudo -v` avant de lancer : les étapes système sont sinon ignorées |
| Un service n'apparaît pas | `acmechanic --liste` : nom du script = nom du dossier ? exécutable ? source `lib/service.sh` ou `lib/common.sh` ? |
| « docker-compose.yml introuvable » | Régler `<NOM>_PROJET` dans `local.conf`, ou partir du modèle `bibliotheque/<nom>/docker-compose.yml` |
| « Une autre exécution … est déjà en cours » | Une exécution tourne encore (`/tmp/maintenance-<nom>.lock`) |
| Détail d'un service | `~/logs/acmechanic/services/<nom>.sortie` |

## 🗺️ Feuille de route

Voir [ROADMAP.md](ROADMAP.md) — prochaine étape, la **1.5** : Fedora, Arch, openSUSE, Alpine.

## 📜 Licence

GPL-3.0-or-later — voir [LICENSE](LICENSE).
Copyright (C) 2026 Jean-Philippe Reculeau

## 👤 Auteur

**Jean-Philippe Reculeau** — [@jpreculeau](https://github.com/jpreculeau)

## 📚 Ressources

- [AcmeFrag](https://github.com/jpreculeau/AcmeFrag) — le défragmenteur de la même famille ACME
- [Docker Compose healthcheck](https://docs.docker.com/reference/compose-file/services/#healthcheck)
- [systemd-run --scope](https://www.freedesktop.org/software/systemd/man/latest/systemd-run.html)
- [Nala](https://gitlab.com/volian/nala) · [Nerd Fonts](https://www.nerdfonts.com/)
