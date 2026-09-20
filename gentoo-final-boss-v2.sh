#!/usr/bin/env bash
#
# Gentoo Final Boss v2
# Interactive Gentoo amd64 installer for UEFI systems.
#
# Features:
# - Automatic hardware detection
# - Automatic disk discovery
# - Automatic GPU VIDEO_CARDS detection
# - Intel/AMD CPU microcode selection
# - Dynamic current Gentoo Stage3 discovery
# - Costa Rica timezone default
# - Optional live-environment timezone detection
# - Filesystem choice: ext4 / btrfs
# - OpenRC service setup (no systemctl)
# - Username + root password customization
# - DE/WM chooser
# - Installation log
#
# WARNING: this script ERASES the selected disk.
#

set -Eeuo pipefail

LOG="/root/gentoo-final-boss-v2.log"
TARGET=""
ROOT_PART=""
SWAP_PART=""
EFI_PART=""
MNT="/mnt/gentoo"
STAGE3_URL=""
STAGE3_FILE=""
TARGET_FS="ext4"
TIMEZONE="America/Costa_Rica"
HOSTNAME="gentoo"
USERNAME=""
DE_CHOICE=""

mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
exec > >(tee -a "$LOG") 2>&1

die() {
    echo
    echo "[FATAL] $*" >&2
    exit 1
}

pause_screen() {
    read -r -p "Press Enter to continue..." _ || true
}

require_root() {
    [[ "${EUID}" -eq 0 ]] || die "Run this installer as root."
}

header() {
    clear || true
    echo "============================================================"
    echo "                    GENTOO FINAL BOSS v2"
    echo "============================================================"
    echo
}

detect_arch() {
    local arch
    arch="$(uname -m)"
    echo "Architecture: $arch"
    case "$arch" in
        x86_64|amd64) ;;
        *)
            die "This v2 installer currently targets amd64/x86_64."
            ;;
    esac
}

detect_hardware() {
    header
    echo "Hardware detection"
    echo "------------------"

    echo
    echo "CPU:"
    lscpu 2>/dev/null | grep -E 'Model name:|Socket|Core\(s\) per socket:|Thread\(s\) per core:|Architecture:' || true

    echo
    echo "Memory:"
    free -h 2>/dev/null || true

    echo
    echo "Graphics:"
    lspci 2>/dev/null | grep -Ei 'VGA compatible controller|3D controller|Display controller' || echo "No PCI GPU found."

    echo
    echo "Network:"
    lspci 2>/dev/null | grep -Ei 'Ethernet controller|Network controller' || true
    ip -br link 2>/dev/null || true

    echo
    echo "Audio:"
    lspci 2>/dev/null | grep -Ei 'Audio device|Audio controller' || true

    echo
    echo "Bluetooth:"
    if command -v lsusb >/dev/null 2>&1; then
        lsusb | grep -i bluetooth || echo "No USB Bluetooth controller found."
    else
        echo "lsusb unavailable."
    fi

    echo
    echo "Boot mode:"
    if [[ -d /sys/firmware/efi ]]; then
        echo "UEFI"
    else
        echo "Legacy BIOS/CSM"
        echo "WARNING: this v2 installer is designed for UEFI."
    fi

    echo
    detect_arch
    pause_screen
}

detect_cpu_microcode() {
    MICROCODE_PKG=""
    local vendor
    vendor="$(lscpu 2>/dev/null | awk -F: '/Vendor ID:/ {gsub(/^[ \t]+/, "", $2); print $2; exit}')"

    case "$vendor" in
        GenuineIntel)
            MICROCODE_PKG="sys-firmware/intel-microcode"
            ;;
        AuthenticAMD)
            MICROCODE_PKG="sys-firmware/amd-microcode"
            ;;
        *)
            MICROCODE_PKG=""
            ;;
    esac

    echo "CPU microcode package: ${MICROCODE_PKG:-none detected}"
}

detect_gpu_use() {
    GPU_USE=""
    local gpu_text
    gpu_text="$(lspci 2>/dev/null | grep -Ei 'VGA compatible controller|3D controller|Display controller' || true)"

    if grep -qi 'Intel' <<<"$gpu_text"; then
        GPU_USE+=" intel"
    fi
    if grep -Eqi 'AMD|ATI|Radeon' <<<"$gpu_text"; then
        GPU_USE+=" amdgpu"
    fi
    if grep -qi 'NVIDIA' <<<"$gpu_text"; then
        GPU_USE+=" nvidia"
    fi

    GPU_USE="$(xargs <<<"$GPU_USE" 2>/dev/null || true)"

    if [[ -z "$GPU_USE" ]]; then
        GPU_USE="intel"
        echo "GPU driver hint: no recognized PCI GPU; defaulting to intel."
    else
        echo "GPU driver hint: $GPU_USE"
    fi
}

disk_menu() {
    header
    echo "Available disks"
    echo "---------------"

    mapfile -t DISKS < <(lsblk -dpno NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1}')

    ((${#DISKS[@]} > 0)) || die "No disks detected."

    local i dev size model
    for i in "${!DISKS[@]}"; do
        dev="${DISKS[$i]}"
        size="$(lsblk -dnbo SIZE "$dev" 2>/dev/null | numfmt --to=iec 2>/dev/null || echo '?')"
        model="$(lsblk -dn -o MODEL "$dev" 2>/dev/null | xargs || true)"
        printf "  %2d) %-12s %-10s %s\n" "$((i+1))" "$dev" "$size" "${model:-Unknown model}"
    done

    echo
    read -r -p "Select disk number: " choice
    [[ "$choice" =~ ^[0-9]+$ ]] || die "Invalid disk selection."
    (( choice >= 1 && choice <= ${#DISKS[@]} )) || die "Invalid disk selection."

    TARGET="${DISKS[$((choice-1))]}"

    echo
    echo "SELECTED DISK: $TARGET"
    lsblk "$TARGET" || true
    echo
    echo "WARNING: EVERYTHING ON $TARGET WILL BE ERASED."
    read -r -p "Type exactly: ERASE $TARGET : " confirm
    [[ "$confirm" == "ERASE $TARGET" ]] || die "Disk erase cancelled."

    wipefs -a "$TARGET"
}

partition_disk() {
    header
    echo "Partitioning $TARGET"
    echo

    if [[ ! -d /sys/firmware/efi ]]; then
        die "UEFI was not detected. v2 currently requires UEFI."
    fi

    command -v parted >/dev/null 2>&1 || die "parted is required."
    command -v mkfs.fat >/dev/null 2>&1 || die "dosfstools/mkfs.fat is required."

    echo "Filesystem choices:"
    echo "  1) ext4 (recommended/simple)"
    echo "  2) btrfs"
    echo
    read -r -p "Filesystem [1]: " fs_choice
    fs_choice="${fs_choice:-1}"

    case "$fs_choice" in
        1) TARGET_FS="ext4" ;;
        2) TARGET_FS="btrfs" ;;
        *) die "Invalid filesystem choice." ;;
    esac

    parted -s "$TARGET" mklabel gpt
    parted -s "$TARGET" mkpart ESP fat32 1MiB 513MiB
    parted -s "$TARGET" set 1 esp on
    parted -s "$TARGET" mkpart swap linux-swap 513MiB 4609MiB
    parted -s "$TARGET" mkpart root "$TARGET_FS" 4609MiB 100%

    if [[ "$TARGET" =~ nvme|mmcblk ]]; then
        EFI_PART="${TARGET}p1"
        SWAP_PART="${TARGET}p2"
        ROOT_PART="${TARGET}p3"
    else
        EFI_PART="${TARGET}1"
        SWAP_PART="${TARGET}2"
        ROOT_PART="${TARGET}3"
    fi

    partprobe "$TARGET" 2>/dev/null || true
    sleep 2

    mkfs.fat -F32 "$EFI_PART"
    mkswap "$SWAP_PART"
    swapon "$SWAP_PART"

    if [[ "$TARGET_FS" == "ext4" ]]; then
        mkfs.ext4 -F "$ROOT_PART"
        mount "$ROOT_PART" "$MNT"
    else
        command -v mkfs.btrfs >/dev/null 2>&1 || die "btrfs-progs/mkfs.btrfs is required."
        mkfs.btrfs -f "$ROOT_PART"
        mount "$ROOT_PART" "$MNT"
    fi

    mkdir -p "$MNT/boot"
    mount "$EFI_PART" "$MNT/boot"

    echo
    lsblk "$TARGET"
    echo
    echo "Root filesystem: $TARGET_FS"
    echo "Root: $ROOT_PART"
    echo "EFI : $EFI_PART"
    echo "Swap: $SWAP_PART"
    pause_screen
}

choose_timezone() {
    header
    echo "Timezone"
    echo "--------"

    local live_tz=""
    if command -v timedatectl >/dev/null 2>&1; then
        live_tz="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
    fi

    if [[ -n "$live_tz" && "$live_tz" != "UTC" && -f "/usr/share/zoneinfo/$live_tz" ]]; then
        echo "Live environment timezone detected: $live_tz"
        TIMEZONE="$live_tz"
    else
        TIMEZONE="America/Costa_Rica"
        echo "No useful live timezone detected."
        echo "Defaulting to Costa Rica: $TIMEZONE"
    fi

    read -r -p "Timezone [$TIMEZONE]: " tz_input
    TIMEZONE="${tz_input:-$TIMEZONE}"

    [[ -f "/usr/share/zoneinfo/$TIMEZONE" ]] || die "Timezone not found: $TIMEZONE"
}

choose_identity() {
    header
    echo "System identity"
    echo "---------------"

    read -r -p "Hostname [$HOSTNAME]: " input
    HOSTNAME="${input:-$HOSTNAME}"

    while :; do
        read -r -p "Normal username [davito]: " USERNAME
        USERNAME="${USERNAME:-davito}"
        if [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
            break
        fi
        echo "Invalid username. Use lowercase letters/numbers/_/- and start with a letter or underscore."
    done

    echo
    echo "The Linux root account is always named 'root'."
    echo "You can customize its password, while '$USERNAME' will be the normal admin account."
    echo
    read -r -s -p "Root password: " ROOT_PASSWORD
    echo
    read -r -s -p "Confirm root password: " ROOT_PASSWORD2
    echo
    [[ "$ROOT_PASSWORD" == "$ROOT_PASSWORD2" ]] || die "Root passwords do not match."

    read -r -s -p "Password for $USERNAME: " USER_PASSWORD
    echo
    read -r -s -p "Confirm password for $USERNAME: " USER_PASSWORD2
    echo
    [[ "$USER_PASSWORD" == "$USER_PASSWORD2" ]] || die "User passwords do not match."
}

choose_desktop() {
    header
    echo "Desktop / Window Manager"
    echo "------------------------"
    echo "  1) dwm"
    echo "  2) KDE Plasma"
    echo "  3) GNOME"
    echo "  4) XFCE"
    echo "  5) LXQt"
    echo "  6) Cinnamon"
    echo "  7) MATE"
    echo "  8) Hyprland"
    echo "  9) i3"
    echo " 10) Openbox"
    echo " 11) None (CLI only)"
    echo
    read -r -p "Choose [1]: " choice
    choice="${choice:-1}"

    case "$choice" in
        1) DE_CHOICE="dwm" ;;
        2) DE_CHOICE="plasma" ;;
        3) DE_CHOICE="gnome" ;;
        4) DE_CHOICE="xfce" ;;
        5) DE_CHOICE="lxqt" ;;
        6) DE_CHOICE="cinnamon" ;;
        7) DE_CHOICE="mate" ;;
        8) DE_CHOICE="hyprland" ;;
        9) DE_CHOICE="i3" ;;
        10) DE_CHOICE="openbox" ;;
        11) DE_CHOICE="none" ;;
        *) die "Invalid desktop choice." ;;
    esac
}

fetch_stage3() {
    header
    echo "Gentoo Stage3"
    echo "-------------"

    local arch="amd64"
    local base="https://distfiles.gentoo.org/releases/$arch/autobuilds/current-stage3-$arch-openrc"
    local index="$base/latest-stage3-$arch-openrc.txt"
    local filename=""

    echo "Searching for a local Stage3 archive..."
    local local_stage
    local_stage="$(find /root /mnt/cdrom /tmp -maxdepth 4 -type f \
        \( -name "stage3-${arch}-*.tar.xz" -o -name "stage3-${arch}-*.tar.zst" \) \
        2>/dev/null | head -n1 || true)"

    if [[ -n "$local_stage" ]]; then
        echo "Found: $local_stage"
        read -r -p "Use this local archive? [Y/n]: " use_local
        use_local="${use_local:-Y}"
        if [[ "$use_local" =~ ^[Yy]$ ]]; then
            STAGE3_FILE="$local_stage"
            return
        fi
    fi

    command -v curl >/dev/null 2>&1 || die "curl is required to download Stage3."

    echo "Fetching the current official Gentoo OpenRC Stage3 index..."
    filename="$(curl -fsSL "$index" | awk '
        /^[^#[:space:]]/ && $1 ~ /^stage3-amd64-openrc-.*\.tar\.(xz|zst)$/ {
            print $1
            exit
        }' || true)"

    [[ -n "$filename" ]] || die "Could not determine the current Stage3 filename from $index."

    STAGE3_URL="$base/$filename"
    STAGE3_FILE="/tmp/$filename"

    echo "Current Stage3:"
    echo "  $STAGE3_URL"
    echo
    echo "Downloading..."
    curl -fL --progress-bar "$STAGE3_URL" -o "$STAGE3_FILE"

    [[ -s "$STAGE3_FILE" ]] || die "Stage3 download failed or is empty."

    echo
    echo "Stage3 downloaded: $STAGE3_FILE"
}

extract_stage3() {
    header
    echo "Extracting Stage3..."
    mkdir -p "$MNT"

    case "$STAGE3_FILE" in
        *.tar.xz)
            tar xpf "$STAGE3_FILE" -C "$MNT" --xattrs-include='*.*' --numeric-owner
            ;;
        *.tar.zst)
            tar xpf "$STAGE3_FILE" -C "$MNT" --xattrs-include='*.*' --numeric-owner
            ;;
        *)
            die "Unsupported Stage3 archive: $STAGE3_FILE"
            ;;
    esac
}

write_fstab() {
    mkdir -p "$MNT/etc"
    local root_uuid swap_uuid efi_uuid
    root_uuid="$(blkid -s UUID -o value "$ROOT_PART")"
    swap_uuid="$(blkid -s UUID -o value "$SWAP_PART")"
    efi_uuid="$(blkid -s UUID -o value "$EFI_PART")"

    cat > "$MNT/etc/fstab" <<EOF
# Generated by Gentoo Final Boss v2
UUID=$root_uuid  /      $TARGET_FS  noatime  0 1
UUID=$efi_uuid   /boot  vfat        noatime  0 2
UUID=$swap_uuid  none   swap        sw       0 0
EOF
}

prepare_chroot() {
    header
    echo "Preparing chroot..."

    cp -L /etc/resolv.conf "$MNT/etc/resolv.conf" 2>/dev/null || true

    mount --types proc /proc "$MNT/proc"
    mount --rbind /sys "$MNT/sys"
    mount --make-rslave "$MNT/sys"
    mount --rbind /dev "$MNT/dev"
    mount --make-rslave "$MNT/dev"
    mount --rbind /run "$MNT/run"
    mount --make-rslave "$MNT/run"

    mkdir -p "$MNT/etc/portage"

    cat > "$MNT/etc/portage/make.conf" <<EOF
COMMON_FLAGS="-O2 -pipe"
CFLAGS="\${COMMON_FLAGS}"
CXXFLAGS="\${COMMON_FLAGS}"
FCFLAGS="\${COMMON_FLAGS}"
FFLAGS="\${COMMON_FLAGS}"
MAKEOPTS="-j$(nproc)"
ACCEPT_LICENSE="*"
GRUB_PLATFORMS="efi-64"
VIDEO_CARDS="$GPU_USE"
USE="X wayland elogind dbus udev networkmanager"
EOF

    write_fstab
    detect_cpu_microcode
}

configure_chroot() {
    header
    echo "Writing installer configuration..."

    cat > "$MNT/root/gentoo-final-boss.conf" <<EOF
HOSTNAME=$(printf '%q' "$HOSTNAME")
USERNAME=$(printf '%q' "$USERNAME")
TIMEZONE=$(printf '%q' "$TIMEZONE")
DE_CHOICE=$(printf '%q' "$DE_CHOICE")
ROOT_PASSWORD=$(printf '%q' "$ROOT_PASSWORD")
USER_PASSWORD=$(printf '%q' "$USER_PASSWORD")
MICROCODE_PKG=$(printf '%q' "${MICROCODE_PKG:-}")
GPU_USE=$(printf '%q' "$GPU_USE")
EOF

    chmod 600 "$MNT/root/gentoo-final-boss.conf"
}

install_system() {
    header
    echo "Installing Gentoo..."
    echo "This can take a long time, especially while compiling."
    echo

    if [[ ! -x "$MNT/bin/bash" ]]; then
        die "Gentoo Stage3 extraction appears incomplete."
    fi

    cat > "$MNT/root/gentoo-final-boss-stage2.sh" <<'CHROOT'
#!/usr/bin/env bash
set -Eeuo pipefail

source /root/gentoo-final-boss.conf

export HOME=/root
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

echo "== Gentoo Final Boss v2 / Stage 2 =="

echo "Syncing Gentoo repository..."
emerge-webrsync || emerge --sync

echo "Updating @world..."
emerge --ask=n --verbose-conflicts @world

echo "Installing base packages..."
BASE_PKGS=(
    sys-kernel/gentoo-kernel
    sys-kernel/installkernel
    sys-boot/grub
    app-admin/sudo
    net-misc/networkmanager
    app-shells/bash-completion
    sys-kernel/linux-firmware
)

[[ -n "${MICROCODE_PKG:-}" ]] && BASE_PKGS+=("$MICROCODE_PKG")

emerge --ask=n "${BASE_PKGS[@]}"

echo "Configuring timezone..."
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
echo "$TIMEZONE" > /etc/timezone

echo "Configuring locale..."
if ! grep -q '^en_US.UTF-8 UTF-8$' /etc/locale.gen 2>/dev/null; then
    echo 'en_US.UTF-8 UTF-8' >> /etc/locale.gen
fi
locale-gen
eselect locale set en_US.utf8 || true
env-update
source /etc/profile || true

echo "Configuring hostname..."
echo "$HOSTNAME" > /etc/hostname

echo "Configuring root password..."
printf '%s\n%s\n' "$ROOT_PASSWORD" "$ROOT_PASSWORD" | passwd root

echo "Creating user $USERNAME..."
if ! id "$USERNAME" >/dev/null 2>&1; then
    useradd -m -G wheel,audio,video,input "$USERNAME"
fi
printf '%s\n%s\n' "$USER_PASSWORD" "$USER_PASSWORD" | passwd "$USERNAME"

echo "Configuring sudo..."
mkdir -p /etc/sudoers.d
cat > /etc/sudoers.d/wheel <<'EOF'
%wheel ALL=(ALL:ALL) ALL
EOF
chmod 440 /etc/sudoers.d/wheel

echo "Enabling NetworkManager under OpenRC..."
rc-update add NetworkManager default || true

echo "Installing selected desktop/window manager: $DE_CHOICE"

case "$DE_CHOICE" in
    dwm)
        emerge --ask=n x11-wm/dwm x11-misc/dmenu x11-terms/st x11-base/xorg-server x11-apps/xinit
        ;;
    plasma)
        emerge --ask=n kde-plasma/plasma-meta kde-plasma/sddm
        rc-update add display-manager default || true
        ;;
    gnome)
        emerge --ask=n gnome-base/gnome gnome-base/gdm
        rc-update add display-manager default || true
        ;;
    xfce)
        emerge --ask=n xfce-base/xfce4-meta x11-misc/lightdm
        rc-update add display-manager default || true
        ;;
    lxqt)
        emerge --ask=n lxqt-base/lxqt-meta x11-misc/sddm
        rc-update add display-manager default || true
        ;;
    cinnamon)
        emerge --ask=n gnome-extra/cinnamon x11-misc/lightdm
        rc-update add display-manager default || true
        ;;
    mate)
        emerge --ask=n mate-base/mate x11-misc/lightdm
        rc-update add display-manager default || true
        ;;
    hyprland)
        emerge --ask=n gui-apps/hyprland gui-apps/waybar gui-apps/wofi
        ;;
    i3)
        emerge --ask=n x11-wm/i3 x11-misc/i3status x11-misc/i3lock x11-base/xorg-server
        ;;
    openbox)
        emerge --ask=n x11-wm/openbox x11-misc/lightdm x11-base/xorg-server
        rc-update add display-manager default || true
        ;;
    none)
        echo "CLI-only installation selected."
        ;;
    *)
        echo "Unknown DE choice: $DE_CHOICE"
        exit 1
        ;;
esac

echo "Configuring GRUB..."
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=Gentoo
grub-mkconfig -o /boot/grub/grub.cfg

echo
echo "Stage 2 complete."
CHROOT

    chmod +x "$MNT/root/gentoo-final-boss-stage2.sh"

    chroot "$MNT" /root/gentoo-final-boss-stage2.sh
}

cleanup() {
    header
    echo "Cleaning up mounts..."

    rm -f "$MNT/root/gentoo-final-boss-stage2.sh" \
          "$MNT/root/gentoo-final-boss.conf" 2>/dev/null || true

    sync || true

    umount -R "$MNT" 2>/dev/null || true
    swapoff "$SWAP_PART" 2>/dev/null || true

    echo
    echo "============================================================"
    echo "              GENTOO FINAL BOSS v2 COMPLETE"
    echo "============================================================"
    echo
    echo "Installation log: $LOG"
    echo "Reboot into Gentoo when ready."
    echo
    echo "IMPORTANT: remove the Gentoo installer USB before rebooting."
    echo
}

main() {
    require_root
    detect_hardware
    detect_gpu_use
    disk_menu
    partition_disk
    choose_timezone
    choose_identity
    choose_desktop
    fetch_stage3
    extract_stage3
    prepare_chroot
    configure_chroot
    install_system
    cleanup
}

trap 'echo; echo "[ERROR] Gentoo Final Boss v2 stopped at line $LINENO."; echo "Log: $LOG"; exit 1' ERR

main "$@"
