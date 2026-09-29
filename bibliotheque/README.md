# 📚 Bibliothèque de services

Des scripts de maintenance **prêts à l'emploi**, tous bâtis sur le même moule (`lib/service.sh`). Les services Docker sont sauvegardés, mis à jour **seulement si le registre a du nouveau**, redémarrés puis contrôlés, et fournis avec un `docker-compose.yml` modèle.

## 🐳 Services Docker

| Service | Image | Sonde par défaut | Sauvegardé |
|---|---|---|---|
| [`jellyfin`](jellyfin/) | `jellyfin/jellyfin` | `:8096/health` | `config/ data/ plugins/` (hors métadonnées, trickplay, cache) |
| [`plex`](plex/) | `plexinc/pms-docker` | `:32400/identity` | `config/` (hors cache, métadonnées, logs) |
| [`audiobookshelf`](audiobookshelf/) | `advplyr/audiobookshelf` | `:13378/healthcheck` | `config/ metadata/` |
| [`arr`](arr/) | `linuxserver/{sonarr,radarr,prowlarr,lidarr}` | `:<port>/ping` | un dossier par service (hors logs, MediaCover) |
| [`cross-seed`](cross-seed/) | `crossseed/cross-seed` | `:2468/api/ping` | `config/` |
| [`syncthing`](syncthing/) | `syncthing/syncthing` | `:8384/rest/noauth/health` | `config/` (clés, dossiers partagés) |
| [`vaultwarden`](vaultwarden/) | `vaultwarden/server` | `:8081/alive` | `data/` (hors cache d'icônes) |
| [`uptime-kuma`](uptime-kuma/) | `louislam/uptime-kuma` | `:3001` | `data/` |
| [`forgejo`](forgejo/) | `codeberg.org/forgejo/forgejo` | `:3000/api/healthz` | `data/` (hors logs, sessions, files d'attente) |
| [`portainer`](portainer/) | `portainer/portainer-ce` | `:9000/api/system/status` | `data/` |
| [`beszel`](beszel/) | `henrygd/beszel` + `beszel-agent` | `:8090` + bannière SSH de l'agent | `beszel_data/`, `beszel_agent_data/` |
| [`open-webui`](open-webui/) | `ghcr.io/open-webui/open-webui` | `:3080/health` | `data/` (hors cache, fichiers envoyés) |
| [`_modele`](_modele/) | à vous | à vous | à vous |

Images hors Docker Hub (Forgejo sur Codeberg, Open WebUI sur ghcr.io) : l'image est tirée à chaque passage et le conteneur n'est recréé que si elle a changé.

## 🔧 Maintenance de la machine

| Service | Ce qu'il fait | Ce qu'il ne fait **jamais** |
|---|---|---|
| [`depots-git`](depots-git/) | Met à jour vos scripts et outils clonés par git (`DEPOTS_GIT`) en avance rapide ; signale les nouveautés du dépôt chezmoi | écraser des modifications locales ; appliquer `chezmoi update` |
| [`outils-ia`](outils-ia/) | Claude Code, CLI npm (`IA_NPM`), outils `uv`/`pipx`, pi.dev, Hermes (+ sauvegarde de leur configuration) ; Ollama par son installeur officiel avec `OLLAMA_MAJ=oui` (service remis dans son état, retour à l'ancienne version en cas d'échec) | mettre à jour Hermes depuis une session Hermes ; installer Ollama sans `OLLAMA_MAJ=oui` (signalé seulement) |
| [`bureau`](bureau/) | Gestionnaire de fenêtres (Hyprland, Sway, labwc, Wayfire, niri : version, greffons `hyprpm`) ; barre et outils installés par pip depuis git **avec vos correctifs** (branches fusionnées, conflits connus rejoués par `git rerere`), copie de sécurité et retour arrière ; relance de la barre proposée | installer si un correctif ne s'applique plus : rien ne change, point d'attention |
| [`micrologiciel`](micrologiciel/) | Signale les mises à jour de l'EEPROM du Raspberry Pi et des micrologiciels LVFS (`fwupd`) | flasher quoi que ce soit : la commande à lancer vous est donnée |
| [`nettoyage`](nettoyage/) | Images Docker sans étiquette, cache de construction, journal systemd, cache des paquets, journaux d'Acmechanic trop gros, vieilles vignettes | toucher aux volumes Docker, aux conteneurs arrêtés, à vos données |
| [`acmefrag`](acmefrag/) | Met à jour [AcmeFrag](https://github.com/jpreculeau/AcmeFrag), lance ses tests, mesure la fragmentation **sans modifier** (`--dry-run`) | défragmenter : c'est long, et ça reste dans sa propre tâche planifiée |
| [`flatpak`](flatpak/) | Met à jour les Flatpak, sauvegarde à froid les applications de `FLATPAK_SAUVEGARDES` | — |

**Et Acmechanic lui-même ?** Il se met à jour tout seul, **en fin de run** (jamais pendant : les services en cours liraient un mélange de deux versions), en avance rapide et seulement si son dossier n'a pas de modifications locales. `ACMECHANIC_AUTO_MAJ=signaler` pour être seulement prévenu, `non` pour désactiver.

## 🚀 Activer un service

```bash
cd ~/acmechanic
ln -s "$PWD/bibliotheque/jellyfin" services/jellyfin   # lien : suit les mises à jour du dépôt
acmechanic --liste                                     # « jellyfin  détecté automatiquement »
```

Les services Docker cherchent leur `docker-compose.yml` dans `<NOM>_PROJET` (par défaut `~/<nom>`). Partez du modèle fourni si vous n'en avez pas.

## ⚙️ Réglages

Aucun script n'est à modifier : tout se surcharge dans `local.conf` (modèle : [`local.conf.example`](../local.conf.example)).

**Services Docker** — une convention unique :

| Variable | Rôle | Exemple |
|---|---|---|
| `<NOM>_PROJET` | dossier du `docker-compose.yml` | `JELLYFIN_PROJET=/opt/media/jellyfin` |
| `<NOM>_DONNEES` | dossier source des sauvegardes | `SYNCTHING_DONNEES=$HOME/syncthing` |
| `<NOM>_URL` | sonde HTTP depuis l'hôte (vide = healthcheck Docker seul) | `JELLYFIN_URL=http://192.0.2.10:8096/health` |
| `<NOM>_CANAL` | tag suivi : `latest`, ou un canal de pointe | `SONARR_CANAL=develop` |

`<NOM>` = nom du conteneur en majuscules, `-` → `_` (`uptime-kuma` → `UPTIME_KUMA_*`). Spécifiques : `JELLYFIN_SUDO=oui`, `ARR_SERVICES=(sonarr radarr)`, `BESZEL_AGENT_PORT`.

**Canal de pointe** : avec `develop`, `edge`, `unstable`…, `choisir_tag` compare la date de publication du canal et de `latest` et retient **le plus récent** — un canal abandonné ne vous fige jamais sur une vieille image.

**Maintenance** — chaque service documente ses réglages en tête de script : `DEPOTS_GIT`, `DEPOTS_APPLIQUER`, `CHEZMOI_VERIFIER` ; `IA_OUTILS`, `IA_NPM`, `OLLAMA_MODELES_MAJ` ; `NETTOYAGE_*` ; `ACMEFRAG_DOSSIER`, `ACMEFRAG_CIBLE`.

## 🧩 Contrat d'un compose compatible

- `container_name` **identique** au nom du service ;
- tag piloté par `${<NOM>_TAG:-latest}` ;
- un `healthcheck` avec `start_interval: 5s` : « healthy » est constaté quelques secondes après le redémarrage ;
- un `name:` de projet explicite si plusieurs fichiers compose partagent un dossier (sinon `up --remove-orphans` de l'un supprime les conteneurs de l'autre) ;
- les secrets (clés, jetons) dans un `.env` à côté du compose, jamais dans un dépôt.

## ✍️ Ajouter un service

```bash
cp -r bibliotheque/_modele services/mon-app
mv services/mon-app/_modele.sh services/mon-app/mon-app.sh
```

Adaptez `SERVICE_NAME`, les réglages et l'appel `docker_standard <conteneur> <image:canal> <url> <données> <éléments...>`. Plusieurs conteneurs : un appel par conteneur (voir `arr`, `beszel`). Pour une étape dont le succès conditionne la suite : `etape "libellé" <délai> cmd...` (renvoie 1 en cas d'échec). Pour une action que l'utilisateur doit faire lui-même : `point_attention "message" "commande à lancer"` — elle apparaît dans le bloc « Points d'attention » du bilan. Un service utile aux autres ? Les PR sont bienvenues.
