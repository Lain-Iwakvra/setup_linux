#!/usr/bin/env bash
# setup-nouveau-pc.sh — configuration automatique d'un nouveau PC EndeavourOS / Arch
#
# Usage : ./setup-nouveau-pc.sh      (utilisateur normal, jamais en root)
#
# Le script peut être relancé sans risque : chaque étape vérifie l'état existant
# avant d'agir, et les fichiers modifiés sont sauvegardés.
#
# Fichiers optionnels à placer à côté du script :
#   variables.lua   -> copié vers ~/.config/hypr/variables.lua
#   Wallpapers/     -> copié dans le dossier Images de l'utilisateur
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
        # Réseau
        networkmanager-dmenu nmap mtr nethogs vnstat wireshark-qt ethtool tor
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

install_comfort_packages() {
    log_sub "Autonomie, réseau et confort"

    local pkgs=(
        bluez bluez-utils ufw zram-generator
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

    log_warn "Pensez à lancer udiskie et hyprpolkitagent au démarrage de votre session Hyprland"
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

configure_keyboard() {
    local f="$HOME/.config/hypr/hyprland/input.lua"

    if [[ ! -f "$f" ]]; then
        log_warn "$f introuvable, clavier non configuré"
        return
    fi

    backup_user_file "$f"
    sed -i -E 's/(kb_layout[[:space:]]*=[[:space:]]*)"[^"]*"/\1"fr"/' "$f"
    sed -i -E 's/(numlock_by_default[[:space:]]*=[[:space:]]*)(true|false)/\1true/' "$f"

    if grep -Eq 'kb_layout[[:space:]]*=[[:space:]]*"fr"' "$f"; then
        log_ok "Clavier fr appliqué dans $f"
    else
        log_warn "kb_layout introuvable dans $f : à régler à la main"
    fi
}

configure_monitors() {
    local f="$HOME/.config/hypr/hyprland.lua"

    if [[ ! -f "$f" ]]; then
        log_warn "$f introuvable, écran non configuré"
        return
    fi
    if ! grep -q -- '-- Default monitor conf' "$f"; then
        log_warn "Repère « -- Default monitor conf » introuvable dans $f, écran non configuré"
        return
    fi

    local block_file new_file json=""
    block_file="$(mktemp)"
    new_file="$(mktemp)"

    if command -v hyprctl &>/dev/null \
        && json="$(hyprctl monitors -j 2>/dev/null)" \
        && jq -e 'length > 0' <<<"$json" &>/dev/null; then
        # Un bloc par écran. Le taux de rafraîchissement est formaté par jq :
        # un printf bash utiliserait la virgule décimale de la locale française.
        {
            echo '-- Default monitor conf'
            jq -r '.[] | "hl.monitor({\n    output   = \"\(.name)\",\n    mode     = \"\(.width)x\(.height)@\((.refreshRate * 100 | round) / 100)\",\n    position = \"\(.x)x\(.y)\",\n    scale    = \(.scale),\n})"' <<<"$json"
            echo '-- End default monitor conf'
        } > "$block_file"
        log_ok "Écran(s) détecté(s) via hyprctl : $(jq -r '[.[] | "\(.name) (\(.width)x\(.height))"] | join(", ")' <<<"$json")"
    else
        cat > "$block_file" <<'EOF'
-- Default monitor conf
hl.monitor({
    output   = "",
    mode     = "preferred",
    position = "auto",
    scale    = "auto",
})
-- End default monitor conf
EOF
        log_warn "Hyprland n'est pas lancé (ou jq absent) : config d'écran générique (auto-détection)"
    fi

    # Remplace l'ancien bloc. Il se termine au repère « -- End default monitor conf »
    # (présent après une première exécution) ou, pour la config d'origine, à la
    # première ligne « }) ». Si la fin est introuvable, awk échoue (END) et le
    # fichier n'est pas touché.
    local has_end=0
    grep -q -- '-- End default monitor conf' "$f" && has_end=1

    if awk -v blockfile="$block_file" -v has_end="$has_end" '
            /-- Default monitor conf/ && !done {
                while ((getline line < blockfile) > 0) print line
                close(blockfile)
                skip = 1; done = 1
                next
            }
            skip && has_end == 1 && /-- End default monitor conf/ { skip = 0; next }
            skip && has_end == 0 && /^[[:space:]]*}\)/ { skip = 0; next }
            skip { next }
            { print }
            END { if (skip) exit 1 }
        ' "$f" > "$new_file" && [[ -s "$new_file" ]]; then
        backup_user_file "$f"
        cat "$new_file" > "$f"   # « cat > » conserve droits et éventuel lien symbolique
        log_ok "Écran configuré dans $f"
    else
        log_err "Bloc moniteur non reconnu dans $f : fichier laissé intact"
        ISSUES+=("configuration de l'écran (hyprland.lua)")
    fi

    rm -f "$block_file" "$new_file"
}

copy_personal_files() {
    local vars_src="$SCRIPT_DIR/variables.lua"
    local vars_dst="$HOME/.config/hypr/variables.lua"

    if [[ -f "$vars_src" ]]; then
        mkdir -p "$(dirname "$vars_dst")"
        [[ -f "$vars_dst" ]] && backup_user_file "$vars_dst"
        cp "$vars_src" "$vars_dst"
        log_ok "variables.lua copié vers $vars_dst"
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

    if ! caelestia install; then
        log_err "\"caelestia install\" a rencontré une erreur"
        ISSUES+=("caelestia install")
        return
    fi
    log_ok "Rice Caelestia installé"

    configure_keyboard
    configure_monitors
    copy_personal_files
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
