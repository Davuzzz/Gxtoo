#!/usr/bin/env bash
#
# gentoo-install.sh - interactive Gentoo Linux installer (amd64, OpenRC)
#
# Usage (from the official Gentoo minimal install ISO, as root, with network):
#   chmod +x gentoo-install.sh
#   ./gentoo-install.sh
#
# What it does:
#   - detects UEFI/BIOS, lists disks and lets you pick one
#   - auto-detects your country/timezone (you can override it)
#   - creates your user, optionally with sudo (wheel group)
#   - lets you pick a desktop: KDE Plasma, GNOME, Xfce, LXQt, MATE, Cinnamon,
#     i3, Openbox, Sway, dwm, or none
#   - partitions (GPT: EFI/BIOS-boot + swap + ext4 root), installs stage3,
#     kernel (prebuilt or compiled), GRUB, NetworkManager, and the desktop
#
# WARNING: this ERASES the whole disk you choose. Test in a VM first.
#
set -Eeo pipefail

MNT=/mnt/gentoo
CONF_NAME=gentoo-install.conf
BASE_URL="https://distfiles.gentoo.org/releases/amd64/autobuilds"

R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[1m'; N=$'\e[0m'
info() { printf '%s[+]%s %s\n' "$G" "$N" "$*"; }
warn() { printf '%s[!]%s %s\n' "$Y" "$N" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$R" "$N" "$*" >&2; exit 1; }
trap 'die "Command failed (line $LINENO). Aborting."' ERR

# ---------------------------------------------------------------- helpers ---
ask() { # ask "prompt" "default" varname
    local __r
    read -rp "$1 [$2]: " __r
    printf -v "$3" '%s' "${__r:-$2}"
}

yesno() { # yesno "prompt" y|n  -> returns 0 for yes
    local r
    while true; do
        read -rp "$1 [$2]: " r
        r=${r:-$2}
        case "${r,,}" in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
        esac
    done
}

ask_secret() { # ask_secret "prompt" varname
    local a b
    while true; do
        read -rsp "$1: " a; echo
        read -rsp "Confirm: " b; echo
        if [[ -n $a && $a == "$b" ]]; then
            printf -v "$2" '%s' "$a"
            return 0
        fi
        warn "Empty or mismatched, try again."
    done
}

DE_KEYS=(plasma gnome xfce lxqt mate cinnamon i3 openbox sway dwm none)
DE_NAMES=("KDE Plasma" "GNOME" "Xfce" "LXQt" "MATE" "Cinnamon"
          "i3 (tiling window manager)" "Openbox (stacking window manager)"
          "Sway (Wayland tiling window manager)"
          "dwm (suckless tiling window manager, very light)"
          "None (console only)")

# ================================================================ STAGE 1 ===
# Runs on the live ISO.

valid_tz() { # format check only: the live ISO's zoneinfo is unreliable; it is verified again inside the chroot
    [[ $1 =~ ^[A-Za-z_]+/[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)?$ || $1 == UTC ]]
}

detect_tz() {
    TZ_NAME=""; COUNTRY=""
    local out
    TZ_NAME=$(curl -fsS --max-time 8 https://ipapi.co/timezone 2>/dev/null || true)
    COUNTRY=$(curl -fsS --max-time 8 https://ipapi.co/country_name 2>/dev/null || true)
    if ! valid_tz "$TZ_NAME"; then
        out=$(curl -fsS --max-time 8 "http://ip-api.com/line/?fields=country,timezone" 2>/dev/null || true)
        COUNTRY=$(sed -n 1p <<<"$out")
        TZ_NAME=$(sed -n 2p <<<"$out")
    fi
    if ! valid_tz "$TZ_NAME"; then
        TZ_NAME=""
    fi
}

choose_timezone() {
    detect_tz
    if [[ -n $TZ_NAME ]]; then
        info "Detected: ${COUNTRY:-unknown country}, timezone ${B}${TZ_NAME}${N}"
        if yesno "Use this timezone?" y; then return; fi
    else
        warn "Could not auto-detect your timezone."
    fi
    while true; do
        read -rp "Enter timezone (e.g. Europe/London, Africa/Lagos, America/New_York): " TZ_NAME
        if valid_tz "$TZ_NAME"; then return; fi
        warn "Not a valid timezone. Use the Region/City format, e.g. America/New_York."
    done
}

choose_disk() {
    local live_dev live_disk="" line name i c
    live_dev=$(findmnt -no SOURCE /run/initramfs/live 2>/dev/null || true)
    if [[ -n $live_dev ]]; then
        live_disk=/dev/$(lsblk -no PKNAME "$live_dev" 2>/dev/null | head -n1)
    fi
    DISK_LIST=()
    while IFS= read -r line; do
        name=${line%% *}
        [[ $name == "$live_disk" ]] && continue
        DISK_LIST+=("$line")
    done < <(lsblk -dpno NAME,SIZE,MODEL -e 7,11)
    ((${#DISK_LIST[@]} > 0)) || die "No usable disks found."

    echo; echo "${B}Detected disks:${N}"
    for i in "${!DISK_LIST[@]}"; do
        printf '  %d) %s\n' $((i+1)) "${DISK_LIST[i]}"
    done
    while true; do
        read -rp "Install to which disk? [1]: " c
        c=${c:-1}
        if [[ $c =~ ^[0-9]+$ ]] && ((c >= 1 && c <= ${#DISK_LIST[@]})); then
            DISK=${DISK_LIST[c-1]%% *}
            return
        fi
    done
}

choose_de() {
    local i c
    echo; echo "${B}Choose a desktop / window manager:${N}"
    for i in "${!DE_KEYS[@]}"; do
        printf '  %2d) %s\n' $((i+1)) "${DE_NAMES[i]}"
    done
    while true; do
        read -rp "Selection [1]: " c
        c=${c:-1}
        if [[ $c =~ ^[0-9]+$ ]] && ((c >= 1 && c <= ${#DE_KEYS[@]})); then
            DE=${DE_KEYS[c-1]}; DE_NAME=${DE_NAMES[c-1]}
            return
        fi
    done
}

detect_gpu() {
    local gpu v=""
    gpu=$(lspci 2>/dev/null | grep -Ei 'vga|3d|display' || true)
    if grep -qi nvidia <<<"$gpu"; then v+="nouveau "; fi
    if grep -qiE 'amd|ati|radeon' <<<"$gpu"; then v+="amdgpu radeonsi "; fi
    if grep -qi intel <<<"$gpu"; then v+="intel "; fi
    if grep -qiE 'virtio|qxl|vmware|virtualbox' <<<"$gpu"; then v+="virgl "; fi
    if [[ -z $v ]]; then v="fbdev vesa"; fi
    VIDEO_CARDS=${v% }
}

gather_input() {
    choose_disk
    choose_timezone

    ask "Locale" "en_US.UTF-8" LOCALE
    ask "Console keymap (us, uk, de, fr ...)" "us" KEYMAP
    ask "Hostname" "gentoo" HOST_NAME

    while true; do
        ask "Username for your account" "user" USERNAME
        [[ $USERNAME =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] && break
        warn "Use lowercase letters, digits, '-' or '_' (must not start with a digit)."
    done

    if yesno "Give '$USERNAME' sudo (administrator) rights?" y; then
        USE_SUDO=yes
    else
        USE_SUDO=no
    fi

    ask_secret "Password for $USERNAME" USER_PW
    ask_secret "Password for root" ROOT_PW

    choose_de

    local k
    ask "Kernel: 1) prebuilt (fast)  2) compile from source (slow)" "1" k
    if [[ $k == 2 ]]; then KERNEL_TYPE=src; else KERNEL_TYPE=bin; fi

    if yesno "Use Gentoo's official binary packages where possible (much faster)?" y; then
        USE_BINPKG=yes
    else
        USE_BINPKG=no
    fi

    ask "Swap size (e.g. 2G, 4G, 8G)" "4G" SWAP_SIZE
    [[ $SWAP_SIZE =~ ^[0-9]+[MG]$ ]] || die "Invalid swap size."

    detect_gpu
    if [[ -d /sys/firmware/efi ]]; then BOOT_MODE=uefi; else BOOT_MODE=bios; fi
}

summary_and_confirm() {
    echo
    echo "${B}================ Summary ================${N}"
    echo " Disk       : $DISK  (${B}ALL DATA WILL BE ERASED${N})"
    echo " Boot mode  : $BOOT_MODE"
    echo " Timezone   : $TZ_NAME"
    echo " Locale     : $LOCALE   Keymap: $KEYMAP"
    echo " Hostname   : $HOST_NAME"
    echo " User       : $USERNAME (sudo: $USE_SUDO)"
    echo " Desktop    : $DE_NAME"
    echo " Kernel     : $KERNEL_TYPE   Binary pkgs: $USE_BINPKG"
    echo " Swap       : $SWAP_SIZE     GPU drivers: $VIDEO_CARDS"
    echo "${B}=========================================${N}"
    local c
    read -rp "Type the disk path ($DISK) to confirm and start: " c
    [[ $c == "$DISK" ]] || die "Aborted, nothing was changed."
}

part() { # part N -> partition device path
    if [[ $DISK =~ [0-9]$ ]]; then echo "${DISK}p$1"; else echo "${DISK}$1"; fi
}

partition_and_mount() {
    local size
    size=$(lsblk -bdno SIZE "$DISK")
    ((size >= 30 * 1024 * 1024 * 1024)) || die "Disk is smaller than 30 GB."

    info "Partitioning $DISK"
    umount -R "$MNT" 2>/dev/null || true
    swapoff -a 2>/dev/null || true
    wipefs -af "$DISK" >/dev/null

    if [[ $BOOT_MODE == uefi ]]; then
        sfdisk --wipe always "$DISK" <<EOF
label: gpt
size=1GiB, type=U
size=$SWAP_SIZE, type=S
type=L
EOF
    else
        sfdisk --wipe always "$DISK" <<EOF
label: gpt
size=2MiB, type=21686148-6449-6E6F-744E-656564454649
size=$SWAP_SIZE, type=S
type=L
EOF
    fi
    partprobe "$DISK" || true
    udevadm settle || true
    sleep 2

    info "Creating filesystems"
    if [[ $BOOT_MODE == uefi ]]; then mkfs.vfat -F32 "$(part 1)"; fi
    mkswap "$(part 2)"
    mkfs.ext4 -F -L gentoo "$(part 3)"

    info "Mounting"
    mkdir -p "$MNT"
    mount "$(part 3)" "$MNT"
    if [[ $BOOT_MODE == uefi ]]; then
        mkdir -p "$MNT/efi"
        mount "$(part 1)" "$MNT/efi"
    fi
    swapon "$(part 2)"
}

install_stage3() {
    info "Syncing clock"
    if command -v chronyd >/dev/null; then
        chronyd -q 'pool pool.ntp.org iburst' || true
    fi

    info "Finding latest OpenRC stage3"
    local path
    path=$(curl -fsS "$BASE_URL/latest-stage3-amd64-openrc.txt" | awk '/\.tar\.xz/ {print $1; exit}')
    [[ -n $path ]] || die "Could not determine the latest stage3."

    cd "$MNT"
    info "Downloading $(basename "$path")"
    curl -fL --retry 3 -o stage3.tar.xz "$BASE_URL/$path"

    local expected actual
    expected=$(curl -fsS "$BASE_URL/$path.sha256" 2>/dev/null | awk '/tar\.xz/ && !/^#/ {print $1; exit}' || true)
    if [[ -n $expected ]]; then
        actual=$(sha256sum stage3.tar.xz | awk '{print $1}')
        [[ $expected == "$actual" ]] || die "Stage3 checksum mismatch!"
        info "Checksum OK"
    else
        warn "Could not fetch checksum, skipping verification."
    fi

    info "Extracting stage3"
    tar xpf stage3.tar.xz --xattrs-include='*.*' --numeric-owner
    rm -f stage3.tar.xz
    cd /
}

write_fstab() {
    local root_uuid swap_uuid esp_uuid
    root_uuid=$(blkid -s UUID -o value "$(part 3)")
    swap_uuid=$(blkid -s UUID -o value "$(part 2)")
    {
        echo "UUID=$root_uuid  /      ext4  defaults,noatime  0 1"
        echo "UUID=$swap_uuid  none   swap  sw                0 0"
        if [[ $BOOT_MODE == uefi ]]; then
            esp_uuid=$(blkid -s UUID -o value "$(part 1)")
            echo "UUID=$esp_uuid  /efi   vfat  umask=0077        0 2"
        fi
    } > "$MNT/etc/fstab"
}

write_conf() {
    local f=$MNT/root/$CONF_NAME v
    umask 077
    : > "$f"
    for v in DISK BOOT_MODE TZ_NAME LOCALE KEYMAP HOST_NAME USERNAME USE_SUDO \
             DE DE_NAME KERNEL_TYPE USE_BINPKG VIDEO_CARDS ROOT_PW USER_PW; do
        printf 'export %s=%q\n' "$v" "${!v}" >> "$f"
    done
    umask 022
}

enter_chroot() {
    info "Preparing chroot"
    cp --dereference /etc/resolv.conf "$MNT/etc/"
    mount --types proc /proc "$MNT/proc"
    mount --rbind /sys "$MNT/sys";  mount --make-rslave "$MNT/sys"
    mount --rbind /dev "$MNT/dev";  mount --make-rslave "$MNT/dev"
    mount --bind /run "$MNT/run";   mount --make-slave "$MNT/run"
    install -m 700 "$SCRIPT_PATH" "$MNT/root/gentoo-install.sh"

    chroot "$MNT" /bin/bash /root/gentoo-install.sh --chroot

    info "Unmounting"
    umount -R "$MNT" 2>/dev/null || umount -l -R "$MNT" || true
    swapoff -a 2>/dev/null || true
}

stage1() {
    [[ $EUID -eq 0 ]] || die "Run as root (you are on the live ISO, so just: ./gentoo-install.sh)."
    [[ $(uname -m) == x86_64 ]] || die "This script supports amd64 only."
    local c
    for c in lsblk sfdisk curl mkfs.ext4 mkfs.vfat mkswap tar chroot blkid; do
        command -v "$c" >/dev/null || die "Missing required tool: $c"
    done
    curl -fsI --max-time 10 https://distfiles.gentoo.org >/dev/null \
        || die "No internet. Configure it first (net-setup, or nmcli/wpa_supplicant)."

    SCRIPT_PATH=$(readlink -f "$0")

    echo "${B}Gentoo automatic installer${N}"
    gather_input
    summary_and_confirm
    loadkeys "$KEYMAP" 2>/dev/null || true
    partition_and_mount
    install_stage3
    write_fstab
    write_conf
    enter_chroot

    echo
    info "${B}Installation finished.${N} Remove the install media and reboot."
    if yesno "Reboot now?" n; then reboot; fi
}

# ================================================================ STAGE 2 ===
# Runs inside the new system (chroot).

emerge_() {
    emerge --ask=n --autounmask=y --autounmask-continue=y --verbose "${EMERGE_EXTRA[@]}" "$@"
}

configure_portage() {
    local cores mem jobs base ver
    cores=$(nproc)
    mem=$(awk '/MemTotal/ {print int($2/1024/1024)}' /proc/meminfo)
    jobs=$cores
    if ((mem / 2 < jobs)); then jobs=$((mem / 2)); fi
    if ((jobs < 1)); then jobs=1; fi

    case "$BOOT_MODE" in
        uefi) GRUB_PLATFORMS="efi-64" ;;
        *)    GRUB_PLATFORMS="pc" ;;
    esac

    sed -i 's/^COMMON_FLAGS=.*/COMMON_FLAGS="-O2 -pipe -march=native"/' /etc/portage/make.conf
    cat >> /etc/portage/make.conf <<EOF

# --- added by gentoo-install.sh ---
MAKEOPTS="-j$jobs"
VIDEO_CARDS="$VIDEO_CARDS"
GRUB_PLATFORMS="$GRUB_PLATFORMS"
EOF

    mkdir -p /etc/portage/package.use
    cat > /etc/portage/package.use/installer <<EOF
sys-kernel/installkernel grub dracut
net-misc/networkmanager wifi
EOF

    EMERGE_EXTRA=()
    if [[ $USE_BINPKG == yes ]]; then
        base=$(eselect profile show | tail -n1 | xargs)
        base=${base%%/desktop*}
        ver=${base#default/linux/amd64/}
        if [[ ! -s /etc/portage/binrepos.conf && ! -d /etc/portage/binrepos.conf ]]; then
            cat > /etc/portage/binrepos.conf <<EOF
[gentoobinhost]
priority = 1
sync-uri = https://distfiles.gentoo.org/releases/amd64/binpackages/$ver/x86-64/
EOF
        fi
        echo 'FEATURES="${FEATURES} getbinpkg binpkg-request-signature"' >> /etc/portage/make.conf
        if command -v getuto >/dev/null; then getuto || warn "getuto failed; binary packages may not verify."; fi
        EMERGE_EXTRA=(--getbinpkg)
    fi
}

select_profile() {
    local cur base sfx=""
    [[ $DE == none ]] && return 0
    case "$DE" in
        plasma) sfx="/plasma" ;;
        gnome)  sfx="/gnome" ;;
    esac
    cur=$(eselect profile show | tail -n1 | xargs)
    base=${cur%%/desktop*}
    info "Setting profile $base/desktop$sfx"
    eselect profile set "$base/desktop$sfx" || warn "Could not set desktop profile; keeping $cur."
}

system_basics() {
    info "Timezone, locale, hostname, keymap"
    if [[ ! -f /usr/share/zoneinfo/$TZ_NAME ]]; then
        warn "Timezone '$TZ_NAME' not found in the new system; falling back to UTC. Fix later with: ln -sf /usr/share/zoneinfo/Region/City /etc/localtime"
        TZ_NAME=UTC
    fi
    echo "$TZ_NAME" > /etc/timezone
    ln -sf "/usr/share/zoneinfo/$TZ_NAME" /etc/localtime

    grep -qx "en_US.UTF-8 UTF-8" /etc/locale.gen || echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
    grep -qx "$LOCALE UTF-8" /etc/locale.gen || echo "$LOCALE UTF-8" >> /etc/locale.gen
    locale-gen
    cat > /etc/env.d/02locale <<EOF
LANG="$LOCALE"
LC_COLLATE="C.UTF-8"
EOF
    env-update

    echo "hostname=\"$HOST_NAME\"" > /etc/conf.d/hostname
    sed -i "s/^#\?keymap=.*/keymap=\"$KEYMAP\"/" /etc/conf.d/keymaps || true
    cat > /etc/hosts <<EOF
127.0.0.1 localhost $HOST_NAME
::1       localhost $HOST_NAME
EOF
}

install_kernel_and_boot() {
    info "Installing firmware, bootloader and kernel"
    emerge_ sys-kernel/linux-firmware sys-fs/dosfstools sys-boot/grub
    if [[ $BOOT_MODE == uefi ]]; then emerge_ sys-boot/efibootmgr; fi
    emerge_ sys-kernel/installkernel
    if [[ $KERNEL_TYPE == bin ]]; then
        emerge_ sys-kernel/gentoo-kernel-bin
    else
        emerge_ sys-kernel/gentoo-kernel
    fi

    info "Installing GRUB"
    if [[ $BOOT_MODE == uefi ]]; then
        grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id=Gentoo \
            || warn "NVRAM entry failed (normal in some VMs); using removable path."
        grub-install --target=x86_64-efi --efi-directory=/efi --removable
    else
        grub-install --target=i386-pc "$DISK"
    fi
    grub-mkconfig -o /boot/grub/grub.cfg
}

install_base_services() {
    info "Installing networking, logger, time sync"
    emerge_ net-misc/networkmanager app-admin/sysklogd net-misc/chrony
    rc-update add NetworkManager default
    rc-update add sysklogd default
    rc-update add chronyd default
}

create_users() {
    info "Creating users"
    echo "root:$ROOT_PW" | chpasswd

    local groups="users,audio,video,input,usb"
    getent group usb >/dev/null || groups="users,audio,video,input"
    if [[ $USE_SUDO == yes ]]; then
        emerge_ app-admin/sudo
        groups+=",wheel"
    fi
    useradd -m -G "$groups" -s /bin/bash "$USERNAME"
    echo "$USERNAME:$USER_PW" | chpasswd

    if [[ $USE_SUDO == yes ]]; then
        echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/10-wheel
        chmod 440 /etc/sudoers.d/10-wheel
    fi
}

install_desktop() {
    local pkgs="" dm="" xorg=yes
    case "$DE" in
        plasma)   pkgs="kde-plasma/plasma-meta kde-apps/konsole kde-apps/dolphin"; dm=sddm ;;
        gnome)    pkgs="gnome-base/gnome-light"; dm=gdm ;;
        xfce)     pkgs="xfce-base/xfce4-meta"; dm=lightdm ;;
        lxqt)     pkgs="lxqt-base/lxqt-meta"; dm=sddm ;;
        mate)     pkgs="mate-base/mate"; dm=lightdm ;;
        cinnamon) pkgs="gnome-extra/cinnamon"; dm=lightdm ;;
        i3)       pkgs="x11-wm/i3 x11-misc/i3status x11-misc/dmenu x11-terms/xterm"; dm=lightdm ;;
        openbox)  pkgs="x11-wm/openbox x11-misc/tint2 x11-terms/xterm"; dm=lightdm ;;
        sway)     pkgs="gui-wm/sway gui-apps/foot"; dm=""; xorg=no ;;
        dwm)      pkgs="x11-wm/dwm x11-misc/dmenu x11-terms/st x11-apps/xinit"; dm=lightdm ;;
        none)     return 0 ;;
    esac
    if [[ $xorg == yes ]]; then pkgs+=" x11-base/xorg-server"; fi
    case "$dm" in
        sddm)    pkgs+=" x11-misc/sddm" ;;
        gdm)     pkgs+=" gnome-base/gdm" ;;
        lightdm) pkgs+=" x11-misc/lightdm x11-misc/lightdm-gtk-greeter" ;;
    esac
    if [[ -n $dm ]]; then pkgs+=" gui-libs/display-manager-init"; fi
    pkgs+=" sys-auth/elogind sys-apps/dbus"

    info "Installing desktop: $DE_NAME (this can take a while)"
    # shellcheck disable=SC2086
    if ! emerge_ $pkgs; then
        warn "Desktop install failed. Your base system is bootable; retry after boot with:"
        warn "  emerge --ask $pkgs"
        return 0
    fi

    rc-update add elogind boot
    rc-update add dbus default

    if [[ -n $dm ]]; then
        echo "DISPLAYMANAGER=\"$dm\"" > /etc/conf.d/display-manager
        if [[ $dm == lightdm ]]; then
            sed -i 's/^#\?greeter-session=.*/greeter-session=lightdm-gtk-greeter/' /etc/lightdm/lightdm.conf || true
        fi
        rc-update add display-manager default
    fi

    if [[ $DE == dwm ]]; then
        echo 'exec dwm' > "/home/$USERNAME/.xinitrc"
        chown "$USERNAME:$USERNAME" "/home/$USERNAME/.xinitrc"
    fi
    if [[ $DE == i3 ]]; then
        echo 'exec i3' > "/home/$USERNAME/.xinitrc"
        chown "$USERNAME:$USERNAME" "/home/$USERNAME/.xinitrc"
    fi
}

install_audio() {
    [[ $DE == none ]] && return 0
    info "Installing PipeWire audio (optional, non-fatal)"
    echo 'media-video/pipewire sound-server' >> /etc/portage/package.use/installer
    if emerge_ media-video/pipewire media-video/wireplumber; then
        info "PipeWire installed. For dwm/i3/Openbox/Sway add 'gentoo-pipewire-launcher &' to your startup."
    else
        warn "PipeWire install failed (likely a USE conflict). Sort out audio after first boot."
    fi
}

chroot_stage() {
    # shellcheck disable=SC1091
    source /etc/profile 2>/dev/null || true
    # shellcheck disable=SC1090
    source "/root/$CONF_NAME"

    info "Syncing Portage tree"
    emerge-webrsync

    select_profile
    configure_portage

    info "Updating @world (profile/USE changes; may take a while)"
    emerge_ --update --deep --newuse @world

    system_basics
    install_kernel_and_boot
    install_base_services
    create_users
    install_desktop
    install_audio

    rm -f "/root/$CONF_NAME" /root/gentoo-install.sh
    info "Chroot stage complete."
    if [[ $DE == dwm ]]; then
        info "dwm: pick 'dwm' at the login screen, or run 'startx' from a TTY. Mod key is Alt."
    fi
    if [[ $DE == sway ]]; then
        info "Sway: log in on a TTY and run 'sway'."
    fi
}

# ================================================================= main ===
if [[ ${1:-} == --chroot ]]; then
    chroot_stage
else
    stage1
fi
