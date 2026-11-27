#!/usr/bin/env bash
# setup-nouveau-pc.sh — configuration automatique d'un nouveau PC EndeavourOS / Arch
#
# Usage : ./setup-nouveau-pc.sh      (utilisateur normal, jamais en root)
#
# Le script peut être relancé sans risque : chaque étape vérifie l'état existant
# avant d'agir, et les fichiers modifiés sont sauvegardés.
#
# Fichiers optionnels à placer à côté du script :
#   variables.lua   -> copié vers ~/.config/caelestia/hypr-vars.lua
#                      (surcharges utilisateur des variables Caelestia)
#   Wallpapers/     -> copié dans le dossier Images de l'utilisateur
#
# Mise en veille : veille et hibernation sont bloquées (sleep.target et consorts
# masqués, logind configuré, raccourci Caelestia et hypridle neutralisés).
# Voir disable_sleep() et neutralize_session_sleep(). Pour revenir en arrière,
# la commande est rappelée dans le résumé final.
#
# Caelestia (nouvelle version Lua) : les fichiers de ~/.config/hypr/ sont
# écrasés par « caelestia install ». Ce script n'y touche plus : clavier, écrans
# et surcharges vont dans ~/.config/caelestia/hypr-user.lua et hypr-vars.lua.
#
# Bibliothèques Python : les dépendances des projets (numpy, scipy, matplotlib,
# numba, torch, PySide6, opencv...) sont installées via pacman, PyTorch en
# version CUDA si un GPU NVIDIA est présent et le noyau non figé.
# Voir setup_python_libs().
#
# Outils pentest de brain_worm : ajoutés aux listes de paquets existantes
# (voir install_daily_software() et install_aur_software()).
#
# Gel du noyau (variable d'environnement KERNEL_HOLD) :
#   Une régression du noyau 7.2.x casse le Wi-Fi des puces Realtek rtw89
#   (RTL8851BE : « probe failed with error -110 », plus d'interface Wi-Fi).
#   Le script évite donc de mettre à jour le noyau (IgnorePkg dans pacman.conf).
#     KERNEL_HOLD=auto   (défaut) gèle si une carte rtw89 est détectée et qu'il n'y a
#                        pas de GPU NVIDIA (nvidia-open est lié à la version du noyau)
#     KERNEL_HOLD=yes    gèle toujours (le pilote NVIDIA n'est alors pas installé)
#     KERNEL_HOLD=no     ne gèle jamais
#   Exemple : KERNEL_HOLD=no ./setup-nouveau-pc.sh

set -uo pipefail   # pas de -e : les erreurs sont gérées étape par étape

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
# Sauvegardes des fichiers utilisateur : volontairement HORS de ~/.config/hypr,
# pour qu'un « source = dossier/* » ne les recharge pas par erreur.
BACKUP_DIR="$HOME/.local/state/setup-nouveau-pc/backups/$TIMESTAMP"

C_RESET="\033[0m"
C_BLUE="\033[1;34m"
C_GREEN="\033[1;32m"
C_YELLOW="\033[1;33m"
C_RED="\033[1;31m"

log_step() { echo -e "\n${C_BLUE}==>${C_RESET} $*"; }
log_sub()  { echo -e "\n  ${C_BLUE}--${C_RESET} $*"; }
log_ok()   { echo -e "${C_GREEN}  [OK]${C_RESET} $*"; }
log_warn() { echo -e "${C_YELLOW}  [ATTENTION]${C_RESET} $*"; }
log_err()  { echo -e "${C_RED}  [ERREUR]${C_RESET} $*"; }

ISSUES=()            # points à vérifier, affichés dans le résumé final
MISSING_PKGS=()      # paquets absents des dépôts (rempli par install_pkgs)
BOOTLOADER="unknown" # grub | systemd-boot | unknown
SUDO_KEEPALIVE_PID=""

KERNEL_HOLD="${KERNEL_HOLD:-auto}"   # auto | yes | no (voir l'en-tête)
KERNEL_HELD=false                    # vrai si le noyau a été figé par ce script
HELD_PKGS=()                         # paquets figés (noyaux + headers)
PACMAN_CONF="/etc/pacman.conf"
SYSFS_PCI="/sys/bus/pci/devices"

# Fichiers personnels Caelestia (jamais écrasés par « caelestia install »).
CAELESTIA_DIR="$HOME/.config/caelestia"
HYPR_USER_LUA="$CAELESTIA_DIR/hypr-user.lua"
HYPR_VARS_LUA="$CAELESTIA_DIR/hypr-vars.lua"

# ──────────────────────────────────────────────────────────────────────────────
# Fonctions utilitaires
# ──────────────────────────────────────────────────────────────────────────────

have_pkg()     { pacman -Qq "$1" &>/dev/null; }
pkg_in_repos() { pacman -Si "$1" &>/dev/null; }
is_laptop()    { compgen -G '/sys/class/power_supply/BAT*' >/dev/null; }

# Détection par sysfs : fonctionne dès le début du script, sans pciutils (lspci).
# Affiche le chemin sysfs de la première carte Wi-Fi Realtek gérée par le pilote
# rtw89 (RTL8851BE, 8852xE, 8922AE...). Code retour 1 s'il n'y en a pas.
find_rtw89_wifi() {
    local dev mods
    for dev in "$SYSFS_PCI"/*; do
        [[ -r "$dev/vendor" && -r "$dev/class" && -r "$dev/modalias" ]] || continue
        # 0x10ec = Realtek ; classe 0x0280 = contrôleur réseau sans fil
        [[ "$(<"$dev/vendor")" == 0x10ec && "$(<"$dev/class")" == 0x0280* ]] || continue
        # Quel module le noyau associerait-il à cette carte ? (rtw89_* ou rtw88_*...)
        mods="$(modprobe -R "$(<"$dev/modalias")" 2>/dev/null)"
        # Alias non résolu : par prudence, on considère la carte comme concernée
        if [[ -z "$mods" || "$mods" == *rtw89* ]]; then
            echo "$dev"
            return 0
        fi
    done
    return 1
}

# 0x10de = NVIDIA ; classe 0x03xxxx = contrôleur d'affichage (VGA, 3D...)
has_nvidia_gpu() {
    local dev
    for dev in "$SYSFS_PCI"/*; do
        [[ -r "$dev/vendor" && -r "$dev/class" ]] || continue
        [[ "$(<"$dev/vendor")" == 0x10de && "$(<"$dev/class")" == 0x03* ]] && return 0
    done
    return 1
}

backup_user_file() {
    mkdir -p "$BACKUP_DIR" && cp -a "$1" "$BACKUP_DIR/$(basename "$1")"
}

# Installe des paquets des dépôts officiels.
#  - ignore les doublons ;
#  - sépare les paquets inconnus (MISSING_PKGS) pour qu'un seul nom invalide
#    ne fasse pas échouer toute la transaction pacman ;
#  - si l'installation groupée échoue, réessaie paquet par paquet.
install_pkgs() {
    local label="$1"; shift
    local found=() failed=() pkg
    local -A seen=()
    MISSING_PKGS=()

    for pkg in "$@"; do
        [[ -n "${seen[$pkg]:-}" ]] && continue
        seen[$pkg]=1
        if pkg_in_repos "$pkg"; then
            found+=("$pkg")
        else
            MISSING_PKGS+=("$pkg")
        fi
    done

    if (( ${#found[@]} > 0 )); then
        if ! sudo pacman -S --needed --noconfirm "${found[@]}"; then
            log_warn "$label : installation groupée échouée, nouvel essai paquet par paquet..."
            for pkg in "${found[@]}"; do
                sudo pacman -S --needed --noconfirm "$pkg" || failed+=("$pkg")
            done
        fi
    fi

    if (( ${#failed[@]} > 0 )); then
        log_err "$label : échec pour : ${failed[*]}"
        ISSUES+=("$label : ${failed[*]}")
        return 1
    fi
    (( ${#found[@]} > 0 )) && log_ok "$label : installés"
    return 0
}

install_aur_pkg() {
    local pkg="$1"
    if paru -S --needed --noconfirm "$pkg"; then
        log_ok "$pkg installé"
    else
        log_err "$pkg a échoué — vous pourrez réessayer avec : paru -S $pkg"
        ISSUES+=("$pkg (AUR)")
    fi
}

# Dépôts officiels d'abord ; ce qui n'y est pas est tenté via l'AUR.
install_official_then_aur() {
    local label="$1"; shift
    install_pkgs "$label" "$@"

    local missing=("${MISSING_PKGS[@]}") pkg
    (( ${#missing[@]} == 0 )) && return 0

    if command -v paru &>/dev/null; then
        log_warn "Absents des dépôts officiels, tentative via l'AUR : ${missing[*]}"
        for pkg in "${missing[@]}"; do
            install_aur_pkg "$pkg"
        done
    else
        log_err "Absents des dépôts officiels et paru indisponible : ${missing[*]}"
        ISSUES+=("$label (introuvables) : ${missing[*]}")
    fi
}

cleanup() {
    [[ -n "$SUDO_KEEPALIVE_PID" ]] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# Vérifications préalables
# ──────────────────────────────────────────────────────────────────────────────

preflight() {
    if [[ $EUID -eq 0 ]]; then
        log_err "Ne lancez pas ce script en root ni avec 'sudo ./script.sh'."
        log_err "Lancez-le avec votre utilisateur normal : ./setup-nouveau-pc.sh"
        exit 1
    fi

    if ! command -v pacman &>/dev/null; then
        log_err "pacman est introuvable : ce script est prévu pour Arch / EndeavourOS."
        exit 1
    fi

    if ! command -v sudo &>/dev/null; then
        log_err "sudo est introuvable. Installez-le et configurez-le avant de relancer."
        exit 1
    fi

    if ! curl -fsS --max-time 10 -o /dev/null https://archlinux.org; then
        log_err "Pas de connexion Internet (archlinux.org injoignable)."
        exit 1
    fi
}

start_sudo_keepalive() {
    echo "Ce script va vous demander votre mot de passe (sudo) une seule fois."
    if ! sudo -v; then
        log_err "Authentification sudo impossible."
        exit 1
    fi
    ( while true; do sudo -n true; sleep 60; kill -0 "$$" 2>/dev/null || exit; done ) &
    SUDO_KEEPALIVE_PID=$!
}

# ──────────────────────────────────────────────────────────────────────────────
# 1) Miroirs, multilib, mise à jour complète
# ──────────────────────────────────────────────────────────────────────────────

# Gel du noyau via IgnorePkg. Raison : le noyau 7.2.x casse le Wi-Fi des puces rtw89
# (RTL8851BE). On fige la version installée à l'installation du système, qui marchait.
# Les autres paquets sont mis à jour normalement (un noyau figé reste compatible avec
# le reste du système). Pour reprendre les mises à jour du noyau : supprimer les deux
# lignes « setup-nouveau-pc » de /etc/pacman.conf.
setup_kernel_hold() {
    log_sub "Gel du noyau (protection contre la régression Wi-Fi rtw89)"

    case "$KERNEL_HOLD" in
        yes) KERNEL_HELD=true ;;
        no)  KERNEL_HELD=false ;;
        *)
            if find_rtw89_wifi >/dev/null; then
                if has_nvidia_gpu; then
                    log_warn "Carte Wi-Fi rtw89 ET GPU NVIDIA détectés : noyau NON figé"
                    log_warn "(nvidia-open dépend de la version exacte du noyau)."
                    log_warn "Si le Wi-Fi disparaît après le redémarrage : sudo downgrade linux linux-headers"
                else
                    KERNEL_HELD=true
                fi
            fi
            ;;
    esac

    if [[ "$KERNEL_HELD" != true ]]; then
        log_ok "Noyau non figé (KERNEL_HOLD=$KERNEL_HOLD, aucune carte rtw89 concernée ou exception ci-dessus)"
        return
    fi

    local k
    HELD_PKGS=()
    for k in linux linux-lts linux-zen linux-hardened; do
        have_pkg "$k" && HELD_PKGS+=("$k" "${k}-headers")
    done
    if (( ${#HELD_PKGS[@]} == 0 )); then
        log_warn "Aucun noyau standard installé : rien à figer"
        KERNEL_HELD=false
        return
    fi

    if grep -q 'setup-nouveau-pc : noyau figé' "$PACMAN_CONF"; then
        log_ok "Noyau déjà figé dans $PACMAN_CONF"
    else
        sudo cp -a "$PACMAN_CONF" "$PACMAN_CONF.backup-noyau.$TIMESTAMP"
        sudo sed -i \
            -e '/^\[options\]/a # setup-nouveau-pc : noyau figé (régression Wi-Fi rtw89) - supprimer ces 2 lignes pour reprendre les mises à jour du noyau' \
            -e "/^\[options\]/a IgnorePkg = ${HELD_PKGS[*]}" \
            "$PACMAN_CONF"
    fi

    if grep -qE "^IgnorePkg[[:space:]]*=.*\blinux" "$PACMAN_CONF"; then
        log_ok "Noyau figé : ${HELD_PKGS[*]}"
    else
        log_err "Impossible de figer le noyau dans $PACMAN_CONF"
        KERNEL_HELD=false
        ISSUES+=("gel du noyau (IgnorePkg)")
    fi
}

step_system() {
    log_step "[1/5] Miroirs (France), multilib et mise à jour complète du système"

    # multilib doit être actif AVANT la première synchronisation (Steam, lib32-*)
    if ! grep -q '^\[multilib\]' $PACMAN_CONF; then
        log_warn "Le dépôt multilib n'est pas activé, activation en cours..."
        sudo cp -a $PACMAN_CONF "$PACMAN_CONF.backup.$TIMESTAMP"
        sudo sed -i '/^#\[multilib\]/{s/^#//; n; s/^#Include/Include/}' $PACMAN_CONF
        if grep -q '^\[multilib\]' $PACMAN_CONF; then
            log_ok "multilib activé"
        else
            log_err "Impossible d'activer multilib automatiquement (Steam et lib32-* échoueront)"
            ISSUES+=("multilib")
        fi
    fi

    log_sub "Miroirs pacman"
    install_pkgs "reflector" reflector
    sudo cp -a /etc/pacman.d/mirrorlist "/etc/pacman.d/mirrorlist.backup.$TIMESTAMP"

    # On écrit dans un fichier temporaire : la liste actuelle n'est remplacée
    # que si reflector a réellement réussi.
    local tmp_mirrors countries mirrors_ok=false
    tmp_mirrors="$(mktemp)"
    for countries in "France" "France,Germany,Belgium"; do
        if sudo reflector --country "$countries" --age 12 --protocol https --latest 10 \
                --sort rate --save "$tmp_mirrors" && [[ -s "$tmp_mirrors" ]]; then
            mirrors_ok=true
            break
        fi
        log_warn "reflector : aucun résultat avec « $countries »"
    done

    if [[ "$mirrors_ok" == true ]]; then
        sudo install -m 644 "$tmp_mirrors" /etc/pacman.d/mirrorlist
        log_ok "Nouvelle liste de miroirs enregistrée dans /etc/pacman.d/mirrorlist ($countries)"
    else
        log_err "reflector a échoué : l'ancienne liste de miroirs est conservée."
        ISSUES+=("reflector : régénération des miroirs")
    fi
    rm -f "$tmp_mirrors"

    # Sur Arch, installer des paquets sans mettre à jour le système (-Sy puis -S)
    # provoque des « mises à jour partielles » non supportées. On fait donc un
    # -Syu complet. Les trousseaux de clés d'abord : une install fraîche a
    # souvent des clés périmées.
    setup_kernel_hold

    log_sub "Mise à jour complète du système"
    local held_before="" held_after=""
    if [[ "$KERNEL_HELD" == true ]]; then
        held_before="$(pacman -Q "${HELD_PKGS[@]}" 2>/dev/null)"
    fi
    local keyrings=(archlinux-keyring)
    pkg_in_repos endeavouros-keyring && keyrings+=(endeavouros-keyring)

    if ! sudo pacman -Sy --needed --noconfirm "${keyrings[@]}" \
        || ! sudo pacman -Su --noconfirm; then
        log_err "La mise à jour du système a échoué : arrêt pour ne pas laisser un système à moitié à jour."
        log_err "Corrigez le problème (réseau, clés PGP, conflit...) puis relancez le script."
        exit 1
    fi
    log_ok "Système à jour"

    # Garde-fou : un paquet dépendant de la version du noyau peut forcer sa mise à jour
    if [[ "$KERNEL_HELD" == true ]]; then
        held_after="$(pacman -Q "${HELD_PKGS[@]}" 2>/dev/null)"
        if [[ "$held_before" == "$held_after" ]]; then
            log_ok "Noyau inchangé (figé)"
        else
            log_err "Le noyau a été mis à jour malgré le gel (dépendance d'un autre paquet ?)"
            log_err "Si le Wi-Fi disparaît au redémarrage : sudo downgrade linux linux-headers"
            ISSUES+=("noyau mis à jour malgré le gel")
        fi
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# 2) Bootloader (GRUB + os-prober)
# ──────────────────────────────────────────────────────────────────────────────

detect_bootloader() {
    if [[ -f /boot/grub/grub.cfg ]]; then
        echo grub
    elif sudo bootctl is-installed &>/dev/null; then
        echo systemd-boot
    else
        echo unknown
    fi
}

step_bootloader() {
    log_step "[2/5] Bootloader (GRUB + os-prober)"

    BOOTLOADER="$(detect_bootloader)"
    case "$BOOTLOADER" in
        grub)
            # ntfs-3g : aide os-prober à lire les partitions Windows
            install_pkgs "GRUB / os-prober" grub os-prober ntfs-3g

            local cfg=/etc/default/grub
            sudo cp -a "$cfg" "$cfg.backup.$TIMESTAMP"
            if grep -qE '^#?GRUB_DISABLE_OS_PROBER=' "$cfg"; then
                sudo sed -i -E 's/^#?GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=false/' "$cfg"
            else
                echo 'GRUB_DISABLE_OS_PROBER=false' | sudo tee -a "$cfg" > /dev/null
            fi
            log_ok "GRUB_DISABLE_OS_PROBER=false défini dans $cfg"
            log_ok "grub.cfg sera régénéré une seule fois, en fin de script"
            ;;
        systemd-boot)
            log_warn "systemd-boot détecté : GRUB et os-prober sont inutiles, étape ignorée."
            log_warn "(systemd-boot détecte Windows tout seul s'il partage la partition EFI.)"
            ;;
        *)
            log_warn "Bootloader non reconnu : étape ignorée (aucun fichier modifié)."
            ;;
    esac
}

# ──────────────────────────────────────────────────────────────────────────────
# 3) paru
# ──────────────────────────────────────────────────────────────────────────────

# Compile et installe un assistant AUR, puis vérifie qu'il démarre vraiment
# (un paru-bin lié à une ancienne libalpm s'installe mais ne se lance pas).
build_aur_helper() {
    local name="$1" dir
    dir="$(mktemp -d)"
    if git clone --quiet "https://aur.archlinux.org/${name}.git" "$dir/$name" \
        && (cd "$dir/$name" && makepkg -si --noconfirm --needed) \
        && paru --version &>/dev/null; then
        rm -rf "$dir"
        return 0
    fi
    rm -rf "$dir"
    return 1
}

step_paru() {
    log_step "[3/5] Installation de paru"

    # Nécessaires à makepkg même si paru est déjà présent (builds AUR plus loin)
    install_pkgs "Outils de compilation" base-devel git

    if command -v paru &>/dev/null; then
        log_ok "paru est déjà installé, on passe à la suite"
        return
    fi

    # 1) paquet précompilé des dépôts (EndeavourOS ou autre), s'il existe
    if pkg_in_repos paru && install_pkgs "paru" paru && command -v paru &>/dev/null; then
        return
    fi

    # 2) paru-bin (binaire, rapide), 3) paru depuis les sources (long : compile du Rust)
    local name
    for name in paru-bin paru; do
        log_sub "Construction de $name depuis l'AUR"
        if build_aur_helper "$name"; then
            log_ok "$name installé avec succès"
            return
        fi
        log_warn "$name a échoué"
    done

    log_err "L'installation de paru a échoué : les paquets AUR seront ignorés"
    ISSUES+=("paru")
}

# ──────────────────────────────────────────────────────────────────────────────
# 4) Pilotes, ly, logiciels, confort
# ──────────────────────────────────────────────────────────────────────────────

setup_drivers() {
    log_sub "Détection du matériel et pilotes"

    install_pkgs "pciutils" pciutils

    local drivers=() cpu_vendor gpu_info

    cpu_vendor="$(grep -m1 'vendor_id' /proc/cpuinfo | awk '{print $3}')"
    case "$cpu_vendor" in
        GenuineIntel)
            drivers+=(intel-ucode)
            log_ok "CPU Intel détecté -> intel-ucode"
            ;;
        AuthenticAMD)
            drivers+=(amd-ucode)
            log_ok "CPU AMD détecté -> amd-ucode"
            ;;
        *)
            log_warn "Fabricant du CPU non reconnu, microcode ignoré"
            ;;
    esac

    # Détection par identifiants PCI (fabricant) : fiable, contrairement à un
    # grep sur le nom (« ati » est contenu dans « Corporation » !).
    # Classes : 0300 = VGA, 0302 = 3D, 0380 = autre contrôleur d'affichage.
    gpu_info="$(lspci -nn | grep -E '\[03(00|02|80)\]')"
    echo "$gpu_info"

    # Les paquets lib32-* sont installés ici, AVANT Steam : sinon pacman
    # demande quel pilote Vulkan 32 bits choisir et --noconfirm prend le 1er.
    if grep -q '\[8086:' <<<"$gpu_info"; then
        drivers+=(mesa vulkan-intel intel-media-driver lib32-mesa lib32-vulkan-intel)
        log_ok "GPU Intel détecté"
    fi
    if grep -q '\[1002:' <<<"$gpu_info"; then
        drivers+=(mesa vulkan-radeon libva-mesa-driver lib32-mesa lib32-vulkan-radeon)
        log_ok "GPU AMD détecté"
    fi
    if grep -q '\[10de:' <<<"$gpu_info"; then
        # Pas de « grep -q » après un pipe avec pipefail : SIGPIPE ferait échouer le test
        if pacman -Qq | grep -E '^nvidia' >/dev/null; then
            log_ok "Un pilote NVIDIA est déjà installé, on ne le touche pas"
        elif [[ "$KERNEL_HELD" == true ]]; then
            # nvidia-open exige la version exacte du noyau : l'installer ferait
            # sauter le gel (ou échouerait). On laisse donc le choix à l'utilisateur.
            log_warn "GPU NVIDIA détecté mais noyau figé : pilote NVIDIA NON installé."
            log_warn "Installez-le à la main avec le noyau figé (nvidia-open-dkms + linux-headers"
            log_warn "de la même version), ou relancez avec KERNEL_HOLD=no."
            ISSUES+=("pilote NVIDIA non installé (noyau figé)")
        else
            drivers+=(nvidia-open nvidia-utils nvidia-settings lib32-nvidia-utils)
            log_ok "GPU NVIDIA détecté -> pilote nvidia-open"
            log_warn "nvidia-open ne supporte que les GPU Turing et plus récents (GTX 16xx / RTX 20xx+)."
            log_warn "Carte plus ancienne : il faut un pilote « legacy » de l'AUR (voir le wiki Arch, page NVIDIA)."
        fi
    fi

    if (( ${#drivers[@]} > 0 )); then
        install_pkgs "Pilotes matériel (CPU/GPU)" "${drivers[@]}"
        if (( ${#MISSING_PKGS[@]} > 0 )); then
            log_warn "Introuvables dans les dépôts (ignorés) : ${MISSING_PKGS[*]}"
        fi
    else
        log_warn "Aucun pilote à installer"
    fi
}

# Bibliothèques Python importées par les projets (Attracteur, empilement,
# fractale, hypercube, lib, minitel, pharma, regresion). Toutes viennent des
# dépôts officiels : pacman reste cohérent avec le Python système, et les venv
# créés en « --system-site-packages » les voient.
setup_python_libs() {
    log_sub "Bibliothèques Python des projets"

    local pkgs=(
        # Base, pip et tkinter (regresion/interface.py, minitel)
        python python-pip python-virtualenv tk
        # Calcul scientifique (empilement, fractales, regresion)
        python-numpy python-scipy python-numba python-tqdm python-sympy python-mpmath
        # Graphiques et images (Attracteur, hypercube, minitel)
        python-matplotlib python-opencv python-pillow
        # Interface de bureau (pharma)
        pyside6
        # Réseau, web et port série (pharma, minitel)
        python-requests python-beautifulsoup4 python-wikipedia python-pyserial
    )

    # PyTorch : version CPU par défaut, CUDA si un GPU NVIDIA est présent et que
    # le noyau n'est pas figé (le pilote NVIDIA est alors lié à sa version).
    if has_nvidia_gpu && [[ "$KERNEL_HELD" != true ]]; then
        if pkg_in_repos python-pytorch-cuda; then
            # python-pytorch-cuda fournit python-pytorch et le remplace : les
            # demander tous les deux provoquerait un conflit pacman.
            pkgs+=(python-pytorch-cuda)
            log_ok "GPU NVIDIA détecté -> PyTorch avec CUDA"
        else
            pkgs+=(python-pytorch)
            log_warn "python-pytorch-cuda absent des dépôts -> PyTorch CPU"
        fi
    else
        pkgs+=(python-pytorch)
        if [[ "$KERNEL_HELD" == true ]]; then
            log_ok "Noyau figé -> PyTorch CPU"
        else
            log_ok "Pas de GPU NVIDIA -> PyTorch CPU"
        fi
    fi

    install_pkgs "Bibliothèques Python" "${pkgs[@]}"

    # Vérification sans importer les modules lourds (torch, PySide6).
    local m missing=()
    for m in numpy scipy matplotlib numba tqdm sympy mpmath cv2 PIL serial \
             requests bs4 wikipedia PySide6 torch; do
        python -c "import importlib.util, sys; sys.exit(0 if importlib.util.find_spec('$m') else 1)" \
            &>/dev/null || missing+=("$m")
    done
    # find_spec réussit pour tkinter même si _tkinter (paquet tk) manque :
    # on tente donc un véritable import.
    python -c 'import tkinter' &>/dev/null || missing+=(tkinter)

    if (( ${#missing[@]} == 0 )); then
        log_ok "Tous les modules Python sont importables"
    else
        log_warn "Modules introuvables après installation : ${missing[*]}"
        ISSUES+=("modules Python manquants : ${missing[*]}")
    fi
}

setup_ly() {
    log_sub "Installation et activation de ly"

    install_pkgs "ly" ly || return

    # Désactive le gestionnaire de connexion actuel (alias display-manager.service)
    # ainsi que les plus courants, sinon l'activation de ly échoue.
    local dm current_dm=""
    if [[ -L /etc/systemd/system/display-manager.service ]]; then
        current_dm="$(basename "$(readlink -f /etc/systemd/system/display-manager.service)")"
    fi
    for dm in "$current_dm" gdm.service sddm.service lightdm.service lxdm.service; do
        [[ -z "$dm" || "$dm" == ly* ]] && continue
        if systemctl is-enabled --quiet "$dm" 2>/dev/null; then
            log_warn "Désactivation de ${dm%.service} (en conflit avec ly)"
            sudo systemctl disable "$dm"
        fi
    done
    sudo systemctl disable getty@tty2.service 2>/dev/null || true

    # Selon la version de ly, l'unité est un modèle (ly@.service) ou ly.service
    local ly_unit="ly.service"
    [[ -f /usr/lib/systemd/system/ly@.service ]] && ly_unit="ly@tty2.service"

    if sudo systemctl enable "$ly_unit"; then
        log_ok "$ly_unit activé — ly apparaîtra au prochain démarrage"
    else
        log_err "Impossible d'activer $ly_unit"
        ISSUES+=("ly (activation du service)")
    fi
}

install_daily_software() {
    log_sub "Installation des logiciels du quotidien"

    local pkgs=(
        # Bureautique, web, communication, multimédia
        libreoffice-fresh firefox discord vlc
        # Jeux
        steam
        # Création, CAO, sciences, radio
        blender freecad occt stellarium gnuradio-companion reaper
        # Développement
        neovim uv opencode
        # Réseau / pentest web (brain_worm)
        networkmanager-dmenu nmap mtr nethogs vnstat wireshark-qt ethtool tor
        sqlmap hydra nikto testssl.sh gobuster zaproxy
        # Utilitaires système (jq est utilisé plus bas par ce script)
        jq ncdu iotop ripgrep fzf bat p7zip unzip timeshift pacman-contrib
    )

    install_official_then_aur "Paquets officiels" "${pkgs[@]}"

    if have_pkg vnstat; then
        sudo systemctl enable --now vnstat.service 2>/dev/null || true
    fi
    if getent group wireshark &>/dev/null; then
        sudo usermod -aG wireshark "$USER"
        log_ok "Utilisateur ajouté au groupe wireshark (effectif après reconnexion)"
    fi
}

install_aur_software() {
    log_sub "Installation des paquets AUR"

    if ! command -v paru &>/dev/null; then
        log_err "paru est absent : paquets AUR ignorés"
        ISSUES+=("Paquets AUR (paru absent)")
        return
    fi

    local pkgs=(
        # Développement
        vscodium-bin pycharm-community-edition claude-desktop
        # Musique, audio
        spotify vcvrack-bin fl-studio-integrator
        # Radio / satellites
        satdump gpredict libsdrplay sdrpp-git
        # Astronomie / astrophoto
        opencv4 grapexpert-bin aladin siril
        # Électronique
        easyeda-bin
        # Réseau
        proton-vpn-gtk-app speedtest-cli google-chrome
        # Pentest web (brain_worm)
        ffuf nuclei subfinder dalfox katana whatweb arjun seclists
        httpx naabu dnsx amass theharvester-git sslyze feroxbuster kiterunner-bin dirsearch dirstalk
        # Système
        hyprmod downgrade tmog-bin
    )

    local pkg
    for pkg in "${pkgs[@]}"; do
        log_step "Installation AUR : $pkg"
        install_aur_pkg "$pkg"
    done
}

install_snap_software() {
    log_step "Installation de snapd puis de TrackMania Nations Forever"

    if ! command -v snap &>/dev/null && command -v paru &>/dev/null; then
        install_aur_pkg snapd
    fi
    if ! command -v snap &>/dev/null; then
        log_err "snapd est indisponible : TrackMania Nations Forever ignoré"
        ISSUES+=("tmnationsforever (snapd indisponible)")
        return
    fi

    sudo systemctl enable --now snapd.socket
    sudo ln -sfn /var/lib/snapd/snap /snap

    if snap list tmnationsforever &>/dev/null; then
        log_ok "tmnationsforever est déjà installé"
        return
    fi

    # snapd initialise ses « seeds » au premier lancement ; on attend sans
    # bloquer indéfiniment, puis on réessaie quelques fois.
    sudo timeout 180 snap wait system seed.loaded 2>/dev/null || true

    local essai snap_ok=false
    for essai in 1 2 3; do
        if sudo snap install tmnationsforever; then
            snap_ok=true
            break
        fi
        log_warn "snapd n'est pas encore prêt (essai $essai/3), nouvel essai dans 10 secondes..."
        sleep 10
    done

    if [[ "$snap_ok" == true ]]; then
        log_ok "TrackMania Nations Forever installé via Snap"
    else
        log_err "Impossible d'installer tmnationsforever pour le moment"
        log_err "Redémarrez le PC puis lancez : sudo snap install tmnationsforever"
        ISSUES+=("tmnationsforever (snap)")
    fi
}

setup_firewall() {
    have_pkg ufw || return 0

    sudo ufw default deny incoming
    sudo ufw default allow outgoing
    sudo systemctl enable ufw.service

    if sudo ufw --force enable; then
        log_ok "Pare-feu ufw actif (entrant bloqué, sortant autorisé)"
    else
        # Typique après une mise à jour du noyau sans redémarrage (modules absents)
        log_warn "ufw n'a pas pu être activé maintenant (modules noyau indisponibles avant redémarrage ?)."
        log_warn "Il sera appliqué au prochain démarrage (ufw.service est activé)."
    fi
}

setup_zram() {
    have_pkg zram-generator || return 0

    local conf=/etc/systemd/zram-generator.conf
    [[ -f "$conf" ]] && sudo cp -a "$conf" "$conf.backup.$TIMESTAMP"

    sudo tee "$conf" > /dev/null <<'EOF'
[zram0]
zram-size = min(ram / 2, 4096)
compression-algorithm = zstd
EOF
    log_ok "zram configuré (actif après le prochain redémarrage)"
}

# Désactive toute mise en veille et l'hibernation. sleep.target est requis par
# systemd-suspend.service, systemd-hibernate.service, systemd-hybrid-sleep.service
# et systemd-suspend-then-hibernate.service : le masquer bloque les quatre.
# Le raccourci Caelestia et hypridle sont neutralisés à l'étape 5, dans
# neutralize_session_sleep().
disable_sleep() {
    log_sub "Désactivation de la mise en veille et de l'hibernation"

    local targets=(sleep.target suspend.target hibernate.target hybrid-sleep.target)
    local t all_masked=true

    for t in "${targets[@]}"; do
        [[ "$(systemctl is-enabled "$t" 2>/dev/null)" == masked ]] || all_masked=false
    done

    if [[ "$all_masked" == true ]]; then
        log_ok "Cibles de veille déjà masquées"
    elif sudo systemctl mask --now "${targets[@]}"; then
        log_ok "Cibles masquées : ${targets[*]}"
    else
        log_err "Impossible de masquer les cibles de veille"
        ISSUES+=("désactivation de la veille")
        return
    fi

    # Redondant avec le masquage, mais explicite pour le capot, les boutons et
    # l'inactivité (certains chemins passent directement par logind).
    local conf=/etc/systemd/logind.conf.d/90-no-sleep.conf
    sudo mkdir -p /etc/systemd/logind.conf.d
    sudo tee "$conf" > /dev/null <<'EOF'
# Ajouté par setup-nouveau-pc.sh : aucune mise en veille automatique
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
HandleSuspendKey=ignore
HandleHibernateKey=ignore
IdleAction=ignore
EOF
    log_ok "logind : capot, boutons veille et inactivité ignorés ($conf)"

    # logind n'est pas redémarré (cela terminerait la session graphique) : le
    # drop-in s'appliquera au prochain démarrage. Le masquage, lui, est immédiat.
    log_warn "Le réglage logind s'appliquera après le prochain redémarrage."

    for t in "${targets[@]}"; do
        if [[ "$(systemctl is-enabled "$t" 2>/dev/null)" != masked ]]; then
            log_err "La cible $t n'est pas masquée"
            ISSUES+=("désactivation de la veille ($t)")
        fi
    done
}

install_comfort_packages() {
    log_sub "Autonomie, réseau et confort"

    local pkgs=(
        bluez bluez-utils blueman ufw zram-generator
        gvfs udiskie file-roller hyprpolkitagent
        noto-fonts noto-fonts-emoji ttf-liberation
    )
    if is_laptop; then
        pkgs+=(tlp)
    else
        log_ok "Pas de batterie détectée (PC fixe) : TLP ignoré"
    fi

    install_pkgs "Paquets autonomie/réseau/confort" "${pkgs[@]}"

    if have_pkg bluez; then
        sudo systemctl enable --now bluetooth.service
    fi
    setup_firewall
    setup_zram
    disable_sleep

    log_warn "Pensez à lancer udiskie, hyprpolkitagent et blueman-applet au démarrage de votre session Hyprland"
    log_warn "(programmes exécutés au lancement, dans votre config Hyprland)."
}

setup_maintenance() {
    log_sub "Entretien automatique"

    # Nettoyage hebdomadaire du cache pacman (garde 3 versions) et TRIM des SSD
    if have_pkg pacman-contrib; then
        sudo systemctl enable --now paccache.timer
    fi
    sudo systemctl enable --now fstrim.timer
    log_ok "paccache.timer et fstrim.timer activés"
}

step_software() {
    log_step "[4/5] Pilotes, ly, logiciels du quotidien et confort"

    setup_drivers            # d'abord : Steam a besoin des pilotes 32 bits
    setup_python_libs        # après les pilotes : PyTorch CUDA dépend du GPU
    setup_ly
    install_daily_software
    install_aur_software
    install_snap_software
    install_comfort_packages
    setup_maintenance
}

# ──────────────────────────────────────────────────────────────────────────────
# 5) Caelestia — en dernier
# ──────────────────────────────────────────────────────────────────────────────

# Depuis la version Lua de Caelestia, ~/.config/hypr/ est écrasé à chaque
# « caelestia install ». Les réglages personnels vont donc dans hypr-user.lua,
# chargé en dernier par la config upstream. Bloc délimité par des repères pour
# rester idempotent et ne pas écraser d'éventuelles personnalisations ajoutées
# par l'utilisateur autour.
configure_caelestia_user() {
    log_sub "Configuration Hyprland utilisateur (hypr-user.lua)"

    if ! mkdir -p "$CAELESTIA_DIR"; then
        log_err "Impossible de créer $CAELESTIA_DIR"
        ISSUES+=("dossier $CAELESTIA_DIR")
        return
    fi
    # Caelestia le crée vide ; on fait pareil s'il n'existe pas encore.
    [[ -e "$HYPR_USER_LUA" ]] || : > "$HYPR_USER_LUA"

    local block_file new_file json="" monitors=""
    block_file="$(mktemp)"
    new_file="$(mktemp)"

    if command -v hyprctl &>/dev/null \
        && json="$(hyprctl monitors -j 2>/dev/null)" \
        && jq -e 'length > 0' <<<"$json" &>/dev/null; then
        # Un bloc par écran. Le taux de rafraîchissement est formaté par jq :
        # un printf bash utiliserait la virgule décimale de la locale française.
        monitors="$(jq -r '.[] | "hl.monitor({\n    output   = \"\(.name)\",\n    mode     = \"\(.width)x\(.height)@\((.refreshRate * 100 | round) / 100)\",\n    position = \"\(.x)x\(.y)\",\n    scale    = \(.scale),\n})"' <<<"$json")"
        log_ok "Écran(s) détecté(s) via hyprctl : $(jq -r '[.[] | "\(.name) (\(.width)x\(.height))"] | join(", ")' <<<"$json")"
    else
        log_warn "Hyprland n'est pas lancé (ou jq absent) : règle d'écran par défaut de Caelestia conservée"
    fi

    {
        echo '-- BEGIN setup-nouveau-pc (bloc géré automatiquement)'
        echo 'hl.config({'
        echo '    input = {'
        echo '        kb_layout = "fr",'
        echo '        numlock_by_default = true,'
        echo '    },'
        echo '})'
        if [[ -n "$monitors" ]]; then
            echo "$monitors"
        else
            echo '-- Écrans : auto-détection (aucune règle spécifique ajoutée).'
        fi
        echo '-- END setup-nouveau-pc'
    } > "$block_file"

    # Remplace uniquement notre bloc. S'il n'existe pas, il est ajouté à la fin
    # (hypr-user.lua est chargé en dernier). Un repère de début sans fin fait
    # échouer awk (END) et laisse le fichier intact.
    local has_block=0
    grep -q '^-- BEGIN setup-nouveau-pc' "$HYPR_USER_LUA" && has_block=1

    if awk -v blockfile="$block_file" '
            /^-- BEGIN setup-nouveau-pc/ && !done {
                while ((getline line < blockfile) > 0) print line
                close(blockfile)
                skip = 1; done = 1
                next
            }
            skip && /^-- END setup-nouveau-pc/ { skip = 0; next }
            skip { next }
            { print }
            END { if (skip) exit 1 }
        ' "$HYPR_USER_LUA" > "$new_file"; then
        # Aucun bloc existant (fichier vide ou vierge) : on l'ajoute en fin.
        [[ "$has_block" -eq 0 ]] && cat "$block_file" >> "$new_file"
        if [[ -s "$new_file" ]]; then
            backup_user_file "$HYPR_USER_LUA"
            cat "$new_file" > "$HYPR_USER_LUA"   # « cat > » conserve droits et éventuel lien symbolique
            log_ok "Clavier fr et écrans configurés dans $HYPR_USER_LUA"
        else
            log_err "Résultat vide pour $HYPR_USER_LUA : fichier laissé intact"
            ISSUES+=("configuration Hyprland (hypr-user.lua)")
        fi
    else
        log_err "Bloc setup mal fermé dans $HYPR_USER_LUA : fichier laissé intact"
        ISSUES+=("configuration Hyprland (hypr-user.lua)")
    fi

    rm -f "$block_file" "$new_file"
}

copy_personal_files() {
    local vars_src="$SCRIPT_DIR/variables.lua"

    # Nouvelle version de Caelestia : les surcharges utilisateur vont dans
    # ~/.config/caelestia/hypr-vars.lua, fusionnées par hyprland.lua avec les
    # variables upstream. Ne jamais écrire dans ~/.config/hypr/ (écrasé).
    if [[ -f "$vars_src" ]]; then
        mkdir -p "$CAELESTIA_DIR"
        [[ -f "$HYPR_VARS_LUA" ]] && backup_user_file "$HYPR_VARS_LUA"
        cp "$vars_src" "$HYPR_VARS_LUA"
        log_ok "variables.lua copié vers $HYPR_VARS_LUA"
    else
        log_warn "variables.lua introuvable à côté du script, non copié"
    fi

    local wall_src="$SCRIPT_DIR/Wallpapers" images_dir
    images_dir="$(xdg-user-dir PICTURES 2>/dev/null)"
    # xdg-user-dir renvoie $HOME quand les dossiers utilisateur ne sont pas configurés
    if [[ -z "$images_dir" || "$images_dir" == "$HOME" ]]; then
        images_dir="$HOME/Images"
    fi

    if [[ -d "$wall_src" ]]; then
        mkdir -p "$images_dir"
        cp -r --update=none "$wall_src" "$images_dir/"
        log_ok "Wallpapers copié vers $images_dir"
    else
        log_warn "Dossier Wallpapers introuvable à côté du script, non copié"
    fi
}

# La veille est déjà bloquée au niveau système (disable_sleep). Ici on évite en
# plus les appels « systemctl suspend[‑then-hibernate] » côté session, qui
# échoueraient sur les unités masquées : raccourci Caelestia et hypridle.
# Le verrouillage et l'extinction de l'écran de hypridle restent intacts.
neutralize_session_sleep() {
    log_sub "Veille : neutralisation des déclencheurs de session"

    # 1) Raccourci Caelestia (gesture 4 doigts + SUPER + SHIFT + L).
    #    Caelestia fusionne hypr-vars.lua dans ses variables : c'est le bon
    #    endroit pour remplacer sleepGestureCmd, sans toucher à ~/.config/hypr/.
    mkdir -p "$CAELESTIA_DIR"
    local vars="$HYPR_VARS_LUA" tmp=""
    if [[ ! -f "$vars" ]]; then
        cat > "$vars" <<'EOF'
return {
    sleepGestureCmd = "true",
}
EOF
        log_ok "sleepGestureCmd neutralisé (fichier créé : $vars)"
    elif grep -qE '^[[:space:]]*sleepGestureCmd[[:space:]]*=[[:space:]]*"true"' "$vars"; then
        log_ok "sleepGestureCmd déjà neutralisé dans $vars"
    elif grep -qE '^[[:space:]]*sleepGestureCmd' "$vars"; then
        backup_user_file "$vars"
        sed -i -E \
            's/^([[:space:]]*sleepGestureCmd[[:space:]]*=[[:space:]]*).*/\1"true",/' \
            "$vars"
        log_ok "sleepGestureCmd neutralisé dans $vars"
    else
        # Fichier créé vide par Caelestia (« return {} ») : insère la clé avant
        # l'accolade fermante de premier niveau.
        tmp="$(mktemp)"
        if awk -v key='    sleepGestureCmd = "true",' '
                { lines[NR] = $0 }
                END {
                    last = 0
                    for (i = 1; i <= NR; i++) if (lines[i] ~ /^}/) last = i
                    if (!last) exit 1
                    for (i = 1; i <= NR; i++) {
                        if (i == last) print key
                        print lines[i]
                    }
                }
            ' "$vars" > "$tmp" && [[ -s "$tmp" ]]; then
            backup_user_file "$vars"
            cat "$tmp" > "$vars"
            log_ok "sleepGestureCmd neutralisé dans $vars"
        else
            # Forme inattendue (ex. « return {} » sur une ligne) : on repart du
            # modèle du dépôt plutôt que de risquer du Lua invalide.
            if [[ -f "$SCRIPT_DIR/variables.lua" ]]; then
                backup_user_file "$vars"
                cp "$SCRIPT_DIR/variables.lua" "$vars"
                log_ok "hypr-vars.lua remplacé par le modèle du dépôt (veille neutralisée)"
            else
                log_warn "sleepGestureCmd absent et modèle introuvable : à vérifier dans $vars"
                ISSUES+=("sleepGestureCmd ($vars)")
            fi
        fi
        [[ -n "$tmp" ]] && rm -f "$tmp"
    fi

    # 2) hypridle : commenter les blocs « listener » qui lancent une veille
    local idle="$HOME/.config/hypr/hypridle.conf"
    if [[ ! -f "$idle" ]]; then
        log_ok "hypridle.conf absent : rien à neutraliser"
        return
    fi
    if ! grep -qE '^[[:space:]]*[[:alnum:]_-]+[[:space:]]*=.*(suspend|hibernate)' "$idle"; then
        log_ok "hypridle : aucun déclencheur de veille"
        return
    fi

    local tmp
    tmp="$(mktemp)"
    if awk '
            /^[[:space:]]*listener[[:space:]]*\{/ {
                inblock = 1; count = 0; suspend = 0
                block[++count] = $0
                next
            }
            inblock {
                block[++count] = $0
                if ($0 ~ /^[[:space:]]*[[:alnum:]_-]+[[:space:]]*=.*(suspend|hibernate)/) suspend = 1
                if ($0 ~ /^[[:space:]]*\}/) {
                    inblock = 0
                    for (i = 1; i <= count; i++)
                        print (suspend ? "# " : "") block[i]
                    delete block
                }
                next
            }
            { print }
            END {
                # Bloc incomplet : on le réécrit tel quel, sans le commenter.
                if (inblock)
                    for (i = 1; i <= count; i++) print block[i]
            }
        ' "$idle" > "$tmp" && [[ -s "$tmp" ]]; then
        if cmp -s "$idle" "$tmp"; then
            log_warn "hypridle : déclencheur de veille hors d'un bloc listener, à vérifier à la main"
            rm -f "$tmp"
            return
        fi
        backup_user_file "$idle"
        cat "$tmp" > "$idle"   # « cat > » conserve droits et éventuel lien symbolique
        log_ok "hypridle : bloc(s) de veille commenté(s) dans $idle"
    else
        log_err "hypridle.conf : réécriture impossible, fichier laissé intact"
        ISSUES+=("hypridle.conf")
    fi
    rm -f "$tmp"
}

# Vérifie le variables.lua géré par Caelestia (~/.config/hypr/). Les anciennes
# versions de ce script y déposaient une copie de variables.lua ; si elle reste
# (ou est cassée), Hyprland échoue avec « '}' expected ... near 'kbGoToWs' ».
# On ne réécrit jamais ce fichier avec du contenu personnel : on le supprime
# avant installation pour que « caelestia install » le redéploie proprement,
# puis on le revérifie et on le restaure depuis upstream en dernier recours.
lua_file_ok() {
    command -v lua >/dev/null 2>&1 || return 0   # pas de lua : contrôle ignoré
    LUA_CHECK_FILE="$1" lua -e '
        local f, err = loadfile(os.getenv("LUA_CHECK_FILE"))
        if not f then
            io.stderr:write(err or "erreur Lua inconnue", "\n")
            os.exit(1)
        end
    ' >/dev/null 2>&1
}

ensure_caelestia_variables() {
    local phase="$1" vars="$HOME/.config/hypr/variables.lua" bad=0 tmp=""
    if [[ ! -e "$vars" ]]; then
        if [[ "$phase" == after ]]; then
            log_err "$vars absent après « caelestia install »"
            ISSUES+=("variables.lua Caelestia absent")
        fi
        return 0
    fi

    grep -Eq 'configuration du rice Caelestia|setup-nouveau-pc' "$vars" && bad=1
    if command -v lua >/dev/null 2>&1 && ! lua_file_ok "$vars"; then
        bad=1
    fi

    if [[ "$phase" == before ]]; then
        if [[ "$bad" -eq 1 ]]; then
            log_warn "$vars est obsolète ou invalide : sauvegarde puis suppression avant réinstallation"
            backup_user_file "$vars" || log_warn "Sauvegarde de $vars impossible"
            if [[ -f "$vars" || -L "$vars" ]]; then
                rm -f -- "$vars" || ISSUES+=("suppression de $vars")
            fi
        fi
        return 0
    fi

    # Après installation : le déploiement doit avoir fourni un fichier valide.
    if [[ "$bad" -eq 0 ]]; then
        log_ok "variables.lua Caelestia valide"
        return
    fi

    log_warn "$vars invalide après installation : tentative de restauration depuis upstream"
    tmp="$(mktemp)"
    if curl -fsSL --max-time 15 \
        -o "$tmp" https://raw.githubusercontent.com/caelestia-dots/caelestia/main/hypr/variables.lua \
        && lua_file_ok "$tmp"; then
        if backup_user_file "$vars"; then
            cat "$tmp" > "$vars"
            log_ok "variables.lua Caelestia restauré depuis upstream"
        else
            log_err "Sauvegarde impossible : $vars laissé intact"
            ISSUES+=("variables.lua Caelestia invalide")
        fi
    else
        log_err "Restauration automatique impossible : $vars reste invalide"
        ISSUES+=("variables.lua Caelestia invalide")
    fi
    rm -f "$tmp"
}

step_caelestia() {
    log_step "[5/5] Installation du rice Caelestia"

    if ! command -v paru &>/dev/null; then
        log_err "paru est absent : Caelestia ignoré"
        ISSUES+=("caelestia-cli (paru absent)")
        return
    fi

    if ! paru -S --needed --noconfirm caelestia-cli; then
        log_err "Impossible d'installer caelestia-cli (AUR)"
        ISSUES+=("caelestia-cli (AUR)")
        return
    fi
    log_ok "caelestia-cli installé"

    # Une ancienne copie (ou un fichier corrompu) dans ~/.config/hypr/ ferait
    # échouer le chargement de Hyprland : on la retire avant le déploiement.
    ensure_caelestia_variables before

    # --aur-helper paru : le script utilise paru comme assistant AUR, on évite
    # que le CLI reparte sur yay ou demande quel helper utiliser.
    if ! caelestia install --aur-helper paru; then
        log_err "\"caelestia install\" a rencontré une erreur"
        ISSUES+=("caelestia install")
        return
    fi
    log_ok "Rice Caelestia installé"
    ensure_caelestia_variables after

    # Après l'installation : ~/.config/hypr/ est écrasé, on ne touche que les
    # fichiers personnels de ~/.config/caelestia/.
    configure_caelestia_user
    copy_personal_files
    neutralize_session_sleep

    if command -v hyprctl &>/dev/null; then
        hyprctl reload &>/dev/null || true
        log_ok "Configuration Hyprland rechargée (hyprctl reload)"
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Finalisation (après Caelestia, qui peut installer d'autres paquets)
# ──────────────────────────────────────────────────────────────────────────────

finalize() {
    log_step "Finalisation"

    if have_pkg tlp; then
        # TLP et power-profiles-daemon ne doivent pas cohabiter. On le vérifie ICI
        # (et non plus tôt) car un paquet installé ensuite peut l'avoir ramené.
        # « mask » (et non « disable ») : le service est aussi lancé via D-Bus.
        if have_pkg power-profiles-daemon; then
            log_warn "Masquage de power-profiles-daemon (en conflit avec TLP)"
            sudo systemctl mask --now power-profiles-daemon.service
        fi
        # Recommandé par TLP pour la gestion des radios (wifi/bluetooth)
        sudo systemctl mask systemd-rfkill.service systemd-rfkill.socket

        # Par précaution : les puces rtw89 supportent mal les réglages d'énergie PCIe
        # (erreur « failed to power on »). TLP n'y touche donc pas.
        local wifi_dev wifi_addr
        if wifi_dev="$(find_rtw89_wifi)"; then
            wifi_addr="${wifi_dev##*/}"
            wifi_addr="${wifi_addr#0000:}"
            sudo mkdir -p /etc/tlp.d
            sudo tee /etc/tlp.d/90-wifi-realtek.conf > /dev/null <<EOF
# Ajouté par setup-nouveau-pc.sh : TLP ne modifie pas l'énergie PCIe de la carte Wi-Fi rtw89
PCIE_ASPM_ON_AC=default
PCIE_ASPM_ON_BAT=default
RUNTIME_PM_DENYLIST="$wifi_addr"
EOF
            log_ok "TLP : carte Wi-Fi $wifi_addr exclue de la gestion d'énergie PCIe"
        fi

        sudo systemctl enable --now tlp.service
        log_ok "TLP activé"
    fi

    if [[ "$BOOTLOADER" == grub ]]; then
        # Une seule génération, à la fin : le microcode, le noyau mis à jour
        # et os-prober sont alors tous pris en compte.
        log_sub "Régénération de grub.cfg"
        if sudo grub-mkconfig -o /boot/grub/grub.cfg; then
            log_ok "grub.cfg régénéré avec succès"
        else
            log_err "Échec de la génération de grub.cfg"
            ISSUES+=("grub-mkconfig")
        fi
    elif [[ "$BOOTLOADER" == systemd-boot ]]; then
        log_ok "systemd-boot : rien à régénérer"
    fi
}

print_summary() {
    echo -e "\n=============================================================="
    if [[ ${#ISSUES[@]} -eq 0 ]]; then
        log_ok "Tout s'est déroulé sans erreur !"
    else
        log_warn "Le script a terminé, mais avec ${#ISSUES[@]} point(s) à vérifier :"
        local issue
        for issue in "${ISSUES[@]}"; do
            echo -e "   - $issue"
        done
        echo "   (le script peut être relancé : il ne refait que ce qui manque)"
    fi
    echo "=============================================================="
    if [[ -d "$BACKUP_DIR" ]]; then
        echo ""
        echo "Sauvegardes de vos fichiers de config modifiés : $BACKUP_DIR"
    fi
    if [[ "$KERNEL_HELD" == true ]]; then
        echo ""
        echo "NOYAU FIGÉ (${HELD_PKGS[*]}) : il ne recevra plus de mises à jour,"
        echo "y compris de sécurité. Pour les reprendre, supprimez les 2 lignes"
        echo "« setup-nouveau-pc » de $PACMAN_CONF puis testez. Si le Wi-Fi disparaît :"
        echo "  sudo downgrade linux linux-headers"
    fi
    echo ""
    echo "MISE EN VEILLE DÉSACTIVÉE (veille et hibernation bloquées)."
    echo "Pour la réactiver :"
    echo "  sudo systemctl unmask sleep.target suspend.target hibernate.target hybrid-sleep.target"
    echo "  sudo rm /etc/systemd/logind.conf.d/90-no-sleep.conf"
    echo "  (puis rétablir sleepGestureCmd dans ~/.config/caelestia/hypr-vars.lua et"
    echo "   décommenter les blocs de veille de ~/.config/hypr/hypridle.conf)"
    echo ""
    echo "Prochaine étape recommandée : redémarrez le PC (groupe wireshark, zram,"
    echo "écran de connexion ly), puis démarrez votre session"
    echo "Hyprland/Caelestia."
    echo ""
    echo "  reboot"
    echo ""
}

# ──────────────────────────────────────────────────────────────────────────────
# Programme principal
# ──────────────────────────────────────────────────────────────────────────────

main() {
    trap cleanup EXIT
    trap 'echo; log_warn "Interrompu."; exit 130' INT TERM

    preflight
    log_step "Configuration du nouveau PC EndeavourOS — c'est parti !"
    start_sudo_keepalive

    step_system
    step_bootloader
    step_paru
    step_software
    step_caelestia
    finalize
    print_summary
}

# Permet de « source » le fichier pour tester les fonctions sans rien lancer
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
