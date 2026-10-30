# setup_linux — configuration automatique d'un nouveau PC

Script Bash qui installe et configure en une passe un **nouveau PC
EndeavourOS / Arch** : miroirs, pilotes, logiciels, gestionnaire de
connexion, rice **Caelestia**, pare-feu, zram, TLP, bibliothèques Python des
projets, veille désactivée. Idempotent : il peut être relancé sans risque,
chaque étape vérifie l'état avant d'agir et les fichiers modifiés sont
sauvegardés.

Projet **autonome** : il ne dépend pas du dépôt `lib`.

## Contenu

| Fichier | Rôle |
|---|---|
| `setup-nouveau-pc.sh` | le script d'installation (5 étapes) |
| `variables.lua` | configuration Caelestia/Hyprland (copiée vers `~/.config/hypr/`) |
| `Wallpapers/` | fonds d'écran copiés dans le dossier Images de l'utilisateur |

## Les 5 étapes

1. **Miroirs, multilib, mise à jour complète** — active `[multilib]`,
   régénère la liste de miroirs via `reflector` (France d'abord), puis
   `pacman -Syu` complet avec mise à jour des trousseaux de clés.
2. **Bootloader** — installe `os-prober` + `GRUB_DISABLE_OS_PROBER=false`
   si GRUB est détecté ; étape ignorée sous systemd-boot.
3. **paru** — installe l'assistant AUR (paquet dépôt, puis `paru-bin`, puis
   compilation depuis les sources), avec vérification que le binaire
   démarre réellement.
4. **Pilotes, ly, logiciels** — microcode CPU, pilotes GPU (Intel/AMD/NVIDIA
   détectés par identifiants PCI), **bibliothèques Python des projets**,
   gestionnaire de connexion `ly`, logiciels du quotidien (dépôts puis AUR),
   confort (Bluetooth/blueman, ufw, zram, TLP, **veille désactivée**), entretien
   (paccache, fstrim).
5. **Caelestia** — `caelestia install`, clavier français, détection des
   écrans via `hyprctl`/`jq`, copie de `variables.lua` et des wallpapers.

## Usage

```bash
./setup-nouveau-pc.sh
```

**Jamais en root ni avec `sudo ./script.sh`** : le script vérifie lui-même
qu'il n'est pas lancé en root, puis demande votre mot de passe sudo **une
seule fois** (keep-alive).

Prérequis : Arch ou EndeavourOS, `pacman`, `sudo`, une connexion Internet.

## Gel du noyau (`KERNEL_HOLD`)

Une régression des noyaux **7.2.x** casse le Wi-Fi des puces Realtek
`rtw89` (RTL8851BE : *probe failed with error −110*). Le script peut donc
figer la version du noyau via `IgnorePkg` dans `/etc/pacman.conf`.

| Variable | Effet |
|---|---|
| `KERNEL_HOLD=auto` *(défaut)* | gèle si une carte `rtw89` est détectée **et** qu'il n'y a pas de GPU NVIDIA (`nvidia-open` dépend de la version exacte du noyau) |
| `KERNEL_HOLD=yes` | gèle toujours (le pilote NVIDIA n'est alors pas installé) |
| `KERNEL_HOLD=no` | ne gèle jamais |

```bash
KERNEL_HOLD=no ./setup-nouveau-pc.sh
```

Pour reprendre les mises à jour du noyau : supprimer les deux lignes
`setup-nouveau-pc` de `/etc/pacman.conf`. Si le Wi-Fi disparaît après un
redémarrage :
```bash
sudo downgrade linux linux-headers
```

## Fichiers optionnels

Placez à côté du script :

- `variables.lua` → copié vers `~/.config/hypr/variables.lua`
- `Wallpapers/` → copié dans le dossier Images (`xdg-user-dir PICTURES`)

S'ils sont absents, le script le signale mais continue.

## Mise en veille désactivée

Le script bloque la veille et l'hibernation :

- `sleep.target`, `suspend.target`, `hibernate.target` et `hybrid-sleep.target`
  sont **masqués** (`systemctl mask`) — `sleep.target` étant requis par tous les
  services de veille, y compris `suspend-then-hibernate` ;
- un drop-in `logind` (`/etc/systemd/logind.conf.d/90-no-sleep.conf`) ignore le
  capot, les boutons veille/hibernation et l'inactivité (actif au redémarrage) ;
- le raccourci Caelestia (`sleepGestureCmd` dans `variables.lua`) et les blocs
  de veille de `~/.config/hypr/hypridle.conf` sont neutralisés, pour éviter des
  appels à des unités masquées. Le verrouillage et l'extinction de l'écran
  restent fonctionnels.

Pour réactiver la veille :

```bash
sudo systemctl unmask sleep.target suspend.target hibernate.target hybrid-sleep.target
sudo rm /etc/systemd/logind.conf.d/90-no-sleep.conf
# puis rétablir sleepGestureCmd dans ~/.config/hypr/variables.lua
# et décommenter les blocs de veille de ~/.config/hypr/hypridle.conf
```

## Bibliothèques Python

Installées via `pacman` (dépôts officiels), pour rester cohérentes avec le
Python système et visibles depuis les venv en `--system-site-packages` :

| Usage | Paquets |
|---|---|
| Base, venv, tkinter | `python`, `python-pip`, `python-virtualenv`, `tk` |
| Calcul scientifique | `python-numpy`, `python-scipy`, `python-numba`, `python-tqdm`, `python-sympy`, `python-mpmath` |
| Graphiques et images | `python-matplotlib`, `python-opencv`, `python-pillow` |
| Interface de bureau | `pyside6` |
| Réseau, web, série | `python-requests`, `python-beautifulsoup4`, `python-wikipedia`, `python-pyserial` |
| Deep learning | `python-pytorch` (ou `python-pytorch-cuda`, qui le remplace, si GPU NVIDIA et noyau non figé) |

Une vérification finale (`importlib.util.find_spec`) liste les modules
manquants dans le résumé.

## Sécurité et sauvegardes

- Tout fichier modifié est sauvegardé **hors** de `~/.config/hypr/`
  (pour qu'un `source = dossier/*` ne le recharge pas par erreur) :
  `~/.local/state/setup-nouveau-pc/backups/<horodatage>/`
- `pacman.conf` et `mirrorlist` sont copiés avec un suffixe horodaté avant
  toute modification.
- Le script ne fait jamais de `pacman -Sy` sans `-Su` (pas de mises à
  jour partielles non supportées par Arch).

## Résumé final

À la fin, un bilan liste les points à vérifier (`ISSUES`) s'il y en a, le
dossier des sauvegardes, l'état du gel du noyau et le rappel de la mise en
veille désactivée (avec la commande pour la réactiver). Un redémarrage est
recommandé (groupe `wireshark`, `zram`, service `ly`).

## Licence

Projet personnel — Paul Fournier.
