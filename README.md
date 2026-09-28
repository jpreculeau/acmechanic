# 🔧 ACMECHANIC

> **Le mécano ACME de votre serveur maison** — une seule commande pour sauvegarder, mettre à jour et vérifier vos conteneurs, vos Flatpak et le système. *Bip bip !*

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![Bash](https://img.shields.io/badge/bash-%23121011.svg?style=flat&logo=gnu-bash&logoColor=white)](https://www.gnu.org/software/bash/)
[![Platform](https://img.shields.io/badge/platform-Raspberry%20Pi%20%7C%20Debian-red)](https://www.raspberrypi.org/)
[![Version](https://img.shields.io/badge/version-1.0.0-green.svg)](CHANGELOG.md)

## 📖 Description

**ACMECHANIC** orchestre la maintenance d'un petit serveur (Raspberry Pi, NAS maison, mini-PC Debian) : chaque service est **sauvegardé**, **mis à jour seulement s'il y a du nouveau**, **relancé** puis **contrôlé** (healthcheck Docker ou sonde HTTP). Les services tournent **en parallèle**, bridés en CPU/RAM/E/S pour que la machine reste réactive, et le tout s'affiche dans un **tableau fixe façon dessin animé** aux couleurs de votre terminal.

### 🎬 Cas d'usage

- **Serveur maison** avec une poignée de conteneurs Docker Compose à tenir à jour sans casse
- **Raspberry Pi** où un `docker compose pull` de tout le parc fige le bureau
- **Mises à jour sans surveillance** (cron, timer systemd) avec sauvegarde restaurable avant chaque changement

### ✨ Fonctionnalités

- 🔍 **Découverte automatique** : tout script `services/<nom>/<nom>.sh` qui source `lib/common.sh` est un service — rien à déclarer
- 🚦 **Mise à jour à bon escient** : l'image n'est tirée que si le registre (Docker Hub) a un digest plus récent, si la config compose a changé, ou si le conteneur est arrêté / tourne une ancienne image
- 💾 **Sauvegardes vérifiables** : archive `.tar.gz` + manifeste SHA-256, rotation, restauration interactive avec filet de sécurité (`restore.sh`)
- 🩺 **Santé réelle** : attente du `healthy` Docker (sonde définie par le service), repli sur une URL
- ⚡ **Parallèle et bridé** : un cgroup `systemd-run --user` par service (CPU, RAM, pids) + `nice`/`ionice`
- 🖥️ **Tableau fixe** : une case par service, lignes de détail pré-dimensionnées selon la fenêtre, icônes Nerd Font, 16 couleurs du thème du terminal
- 🛡️ **Robuste** : verrous `flock`, délais par étape, watchdog anti-fige, Ctrl+C / fermeture de terminal qui arrêtent proprement tout l'arbre
- 🐧 **Système** : Nala (ou APT en repli), rafraîchissement des dépôts anticipé pendant les services, signalement du redémarrage requis

## 🚀 Installation

```bash
git clone https://github.com/jpreculeau/acmechanic.git ~/acmechanic
cd ~/acmechanic
cp local.conf.example local.conf        # réglages machine (optionnel)

# Un premier service, à partir du modèle Docker
cp -r examples/services/docker-exemple services/mon-app
mv services/mon-app/docker-exemple.sh services/mon-app/mon-app.sh
$EDITOR services/mon-app/mon-app.sh     # PROJET, CONTENEUR, URL, IMAGE_REF...

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
| `--version` | Version |
| `--aide`, `-h` | Aide |

Le code de sortie est le **nombre d'étapes en échec** (0 = tout va bien) : pratique en cron.

| Variable d'environnement | Effet |
|---|---|
| `ACMECHANIC_TABLEAU=non` | Affichage ligne à ligne (automatique hors terminal) |
| `ACMECHANIC_ICONES=non` | Symboles Unicode simples au lieu des icônes Nerd Font |
| `LIMITES_RESSOURCES=non` | Pas de cgroup ni de `nice`/`ionice` |

### ✍️ Écrire un service

Un service est un script `services/<nom>/<nom>.sh`, exécutable, qui source `lib/common.sh`. Deux modèles sont fournis dans [`examples/services/`](examples/services/) :

- **`docker-exemple`** : un conteneur Docker Compose (+ `docker-compose.yml` avec healthcheck) via `maintenir_service_docker`
- **`flatpak`** : mise à jour des Flatpak, avec sauvegarde à froid des applications listées dans `FLATPAK_SAUVEGARDES`

Briques disponibles (`lib/common.sh`) : `run_etape "libellé" <délai> cmd...`, `ignorer_etape`, `log`/`ok`/`warn`/`err`, `prendre_verrou`, `enregistrer_version`, `bilan_service`, `creer_sauvegarde` (`lib/backup.sh`).

Pour imposer un ordre : `ln -s ../services/a/a.sh ordre.d/10-a.sh` (les services liés passent d'abord, dans l'ordre des préfixes).

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
│   └── tableau.sh         # affichage fixe (cases, icônes, couleurs)
├── services/              # VOS services (ignorés par git)
├── ordre.d/               # liens d'ordre (ignorés par git)
├── examples/services/     # modèles docker-exemple et flatpak
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
| Un service n'apparaît pas | `acmechanic --liste` : nom du script = nom du dossier ? exécutable ? source `lib/common.sh` ? |
| « Une autre exécution … est déjà en cours » | Une exécution tourne encore (`/tmp/maintenance-<nom>.lock`) |
| Détail d'un service | `~/logs/acmechanic/services/<nom>.sortie` |

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
