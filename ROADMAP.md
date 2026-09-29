# 🗺️ Feuille de route

Ce qui est prévu, par version. Les priorités peuvent bouger : les issues et PR sont bienvenues.

## ✅ 1.1 — livrée

- Bibliothèque élargie : Plex, Audiobookshelf, Vaultwarden, Uptime Kuma, Forgejo, Portainer, Open WebUI
- Maintenance de la machine : `depots-git`, `outils-ia`, `micrologiciel` (signalement), `nettoyage`, `acmefrag`
- Auto-mise à jour d'Acmechanic en fin de run (`ACMECHANIC_AUTO_MAJ`)

## 🎯 1.5 — au-delà de Debian

**Objectif** : la même commande sur les grandes familles Linux.

- [ ] Mise à jour système par famille, détectée via `/etc/os-release` :
  - Debian / Ubuntu / Raspberry Pi OS : Nala, APT (existant)
  - Fedora / RHEL : `dnf upgrade --refresh`, `dnf autoremove`, redémarrage requis via `dnf needs-restarting -r`
  - Arch / Manjaro : `pacman -Syu` (+ signalement des `.pacnew`), jamais d'AUR sans surveillance
  - openSUSE : `zypper refresh` + `zypper dup`/`update` selon Tumbleweed/Leap
  - Alpine : `apk upgrade`
- [ ] Code système extrait dans `lib/systeme.sh` (une fonction par famille, même contrat : rafraîchir, mettre à jour, nettoyer, redémarrage requis ?)
- [ ] `nettoyage` : caches `dnf` / `pacman -Sc` / `zypper clean`
- [ ] CI : tests dans des conteneurs `debian`, `fedora`, `archlinux`, `opensuse/tumbleweed`, `alpine`
- [ ] Snap (`snap refresh`) et Homebrew (`brew upgrade`) dans `outils` quand ils sont présents

## 🔭 Plus tard

- [ ] **Services avec base de données** : Immich (conteneurs mis à jour ensemble), Nextcloud (`occ upgrade`), Paperless-ngx — sauvegarde par `pg_dump` / `mariadb-dump` avant mise à jour
- [ ] **Proxys** (Traefik, Caddy, Nginx Proxy Manager) : validation de la configuration avant redémarrage
- [ ] **Home Assistant** : sauvegarde native avant mise à jour
- [ ] **Notifications** en fin de run : ntfy, Gotify, e-mail (uniquement si échec ou action à faire)
- [ ] **Installation du minuteur** : `acmechanic --installer-minuteur` (timer systemd utilisateur, heure réglable)
- [ ] **Registres hors Docker Hub** (ghcr.io, Codeberg, lscr.io) : digest distant sans pull, comme pour Docker Hub
- [ ] Version anglaise des messages et de la documentation
