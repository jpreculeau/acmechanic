# 📚 Bibliothèque de services

Des scripts de maintenance **prêts à l'emploi**, tous bâtis sur le même moule (`lib/service.sh`) : sauvegarde, mise à jour de l'image **seulement si le registre a du nouveau**, redémarrage, contrôle de santé. Chaque dossier fournit aussi un `docker-compose.yml` modèle compatible.

| Service | Images | Sonde par défaut | Sauvegardé |
|---|---|---|---|
| [`jellyfin`](jellyfin/) | `jellyfin/jellyfin` | `:8096/health` | `config/ data/ plugins/` (hors métadonnées, trickplay, cache) |
| [`arr`](arr/) | `linuxserver/{sonarr,radarr,prowlarr,lidarr}` | `:<port>/ping` | un dossier par service (hors logs, MediaCover) |
| [`syncthing`](syncthing/) | `syncthing/syncthing` | `:8384/rest/noauth/health` | `config/` (clés, dossiers partagés) |
| [`cross-seed`](cross-seed/) | `crossseed/cross-seed` | `:2468/api/ping` | `config/` |
| [`beszel`](beszel/) | `henrygd/beszel` + `beszel-agent` | `:8090` + bannière SSH de l'agent | `beszel_data/`, `beszel_agent_data/` |
| [`flatpak`](flatpak/) | — | `flatpak repair --dry-run` | apps de `FLATPAK_SAUVEGARDES` (à froid) |
| [`_modele`](_modele/) | à vous | à vous | à vous |

## 🚀 Activer un service

```bash
cd ~/acmechanic
ln -s "$PWD/bibliotheque/jellyfin" services/jellyfin   # lien : suit les mises à jour du dépôt
acmechanic --liste                                     # « jellyfin  détecté automatiquement »
```

Le script cherche son `docker-compose.yml` dans `<NOM>_PROJET` (par défaut `~/<nom>`). Partez du modèle fourni si vous n'en avez pas.

## ⚙️ Réglages

Aucun script n'est à modifier : tout se surcharge dans `local.conf`, selon une convention unique.

| Variable | Rôle | Exemple |
|---|---|---|
| `<NOM>_PROJET` | dossier du `docker-compose.yml` | `JELLYFIN_PROJET=/opt/media/jellyfin` |
| `<NOM>_DONNEES` | dossier source des sauvegardes | `SYNCTHING_DONNEES=$HOME/syncthing` |
| `<NOM>_URL` | sonde HTTP depuis l'hôte (vide = healthcheck Docker seul) | `JELLYFIN_URL=http://192.0.2.10:8096/health` |
| `<NOM>_CANAL` | tag suivi : `latest`, ou un canal de pointe | `SONARR_CANAL=develop` |

`<NOM>` = nom du conteneur en majuscules, `-` → `_` (`cross-seed` → `CROSS_SEED_*`).

Spécifiques : `JELLYFIN_SUDO=oui` (données appartenant à root), `ARR_SERVICES=(sonarr radarr)`, `BESZEL_AGENT_PORT`.

**Canal de pointe** : avec `develop`, `edge`, `unstable`…, `choisir_tag` compare la date de publication du canal et de `latest` et retient **le plus récent** — un canal abandonné ne vous fige jamais sur une vieille image. Le tag retenu est exporté en `<NOM>_TAG`, que le compose lit (`image: x:${<NOM>_TAG:-latest}`).

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

Puis adaptez `SERVICE_NAME`, les réglages et l'appel `docker_standard <conteneur> <image:canal> <url> <données> <éléments...>`. Plusieurs conteneurs dans un même compose : un appel `docker_standard` par conteneur (voir `arr`, `beszel`). Un service utile aux autres ? Les PR sont bienvenues.
