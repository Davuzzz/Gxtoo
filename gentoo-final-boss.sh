#!/bin/bash
set -euo pipefail

# ============================================================
# GENTOO FINAL BOSS INSTALLER
# Interactive Gentoo installer
#
# WARNING: This script can ERASE A SELECTED DISK.
# Review the source before running it.
# ============================================================

ROOT_MNT="/mnt/gentoo"
TARGET=""
EFI=""
SWAP=""
ROOT=""
STAGE3=""

die() {
    echo
    echo "[FATAL] $1"
    exit 1
}

pause() {
    read -rp "Press Enter to continue..."
}

require_root() {
    [[ $EUID -eq 0 ]] || die "Run this installer as root."
}

header() {
    clear
    echo "============================================================"
    echo "                 GENTOO FINAL BOSS"
    echo "============================================================"
    echo
}

detect_hardware() {
    header
    echo "Hardware detection"
    echo

    echo "CPU:"
    lscpu | grep -E 'Model name|Architecture|CPU\(s\)' || true
    echo

    echo "Memory:"
    free -h
    echo

    echo "GPU:"
    lspci | grep -Ei 'VGA|3D|Display' || echo "Unknown"
    echo

    echo "Network:"
    lspci | grep -Ei 'Ethernet|Network controller' || true
    echo

    pause
}

disk_menu() {
    header
    echo "Available disks:"
    echo

    mapfile -t DISKS < <(
        lsblk -dpno NAME,TYPE |
        awk '$2 == "disk" {print $1}'
    )

    [[ ${#DISKS[@]} -gt 0 ]] || die "No disks detected."

    for i in "${!DISKS[@]}"; do
        disk="${DISKS[$i]}"

        size_bytes=$(lsblk -dnbo SIZE "$disk")
        size=$(numfmt --to=iec "$size_bytes" 2>/dev/null || echo "?")
        model=$(lsblk -dno MODEL "$disk" | sed 's/^ *//')

        [[ -z "$model" ]] && model="Unknown model"

        printf "  [%d] %-15s %-10s %s\n" \
            "$((i+1))" "$disk" "$size" "$model"
    done

    echo
    read -rp "Select installation disk: " choice

    [[ "$choice" =~ ^[0-9]+$ ]] || die "Invalid selection."
    (( choice >= 1 && choice <= ${#DISKS[@]} )) ||
        die "Invalid disk number."

    TARGET="${DISKS[$((choice-1))]}"

    echo
    echo "YOU SELECTED:"
    lsblk "$TARGET"
    echo

    echo "WARNING: EVERYTHING ON $TARGET WILL BE DESTROYED."
    echo
    read -rp "Type ERASE $TARGET to continue: " confirmation

    [[ "$confirmation" == "ERASE $TARGET" ]] ||
        die "Disk operation cancelled."

    partition_disk
}

partition_disk() {
    header
    echo "Partitioning $TARGET..."
    echo

    umount "${TARGET}"* 2>/dev/null || true

    wipefs -a "$TARGET"

    parted -s "$TARGET" mklabel gpt
    parted -s "$TARGET" mkpart ESP fat32 1MiB 513MiB
    parted -s "$TARGET" set 1 esp on
    parted -s "$TARGET" mkpart swap linux-swap 513MiB 4609MiB
    parted -s "$TARGET" mkpart root ext4 4609MiB 100%

    partprobe "$TARGET"
    sleep 2

    if [[ "$TARGET" == *nvme* ]]; then
        EFI="${TARGET}p1"
        SWAP="${TARGET}p2"
        ROOT="${TARGET}p3"
    else
        EFI="${TARGET}1"
        SWAP="${TARGET}2"
        ROOT="${TARGET}3"
    fi

    echo "Formatting partitions..."

    mkfs.fat -F32 "$EFI"
    mkswap "$SWAP"
    mkfs.ext4 -F "$ROOT"

    mkdir -p "$ROOT_MNT"
    mount "$ROOT" "$ROOT_MNT"
    mkdir -p "$ROOT_MNT/boot"
    mount "$EFI" "$ROOT_MNT/boot"
    swapon "$SWAP"

    echo
    lsblk "$TARGET"
    echo
    echo "Disk prepared successfully."
    pause
}

choose_stage3() {
    header
    echo "Gentoo Stage3"
    echo

    ARCH=$(uname -m)

    case "$ARCH" in
        x86_64)
            echo "Detected architecture: amd64"
            ;;
        aarch64)
            echo "Detected architecture: arm64"
            ;;
        *)
            echo "Detected architecture: $ARCH"
            ;;
    esac

    echo
    echo "Searching for a local Gentoo Stage3 archive..."

    STAGE3=$(find /root /mnt/cdrom /tmp \
        -maxdepth 3 \
        -type f \
        \( -name 'stage3-*.tar.xz' -o -name 'stage3-*.tar.zst' \) \
        2>/dev/null | head -n1 || true)

    if [[ -n "$STAGE3" ]]; then
        echo
        echo "Found:"
        echo "$STAGE3"
        echo
        read -rp "Use this Stage3? [Y/n]: " ans

        if [[ "${ans,,}" != "n" ]]; then
            return
        fi
    fi

    echo
    echo "Paste a direct Gentoo Stage3 URL."
    echo "You can obtain the current URL from:"
    echo "https://www.gentoo.org/downloads/"
    echo

    read -rp "Stage3 URL: " STAGE3_URL
    [[ -n "$STAGE3_URL" ]] || die "No Stage3 URL supplied."

    case "$STAGE3_URL" in
        *.tar.xz) STAGE3="/tmp/stage3.tar.xz" ;;
        *.tar.zst) STAGE3="/tmp/stage3.tar.zst" ;;
        *) STAGE3="/tmp/stage3.tar.xz" ;;
    esac

    curl -L --fail --progress-bar "$STAGE3_URL" -o "$STAGE3"
}

extract_stage3() {
    header
    echo "Installing Stage3..."
    echo

    [[ -f "$STAGE3" ]] || die "Stage3 archive not found."

    cd "$ROOT_MNT"

    case "$STAGE3" in
        *.tar.xz)
            tar -xJpf "$STAGE3"
            ;;
        *.tar.zst)
            tar -I zstd -xpf "$STAGE3"
            ;;
        *)
            die "Unsupported Stage3 archive."
            ;;
    esac

    echo "Stage3 extracted."
}

configure_chroot() {
    header
    echo "Preparing Gentoo chroot..."
    echo

    mkdir -p "$ROOT_MNT"/{proc,sys,dev,run}

    cp --dereference /etc/resolv.conf \
        "$ROOT_MNT/etc/resolv.conf" 2>/dev/null || true

    mount --types proc /proc "$ROOT_MNT/proc"
    mount --rbind /sys "$ROOT_MNT/sys"
    mount --make-rslave "$ROOT_MNT/sys"

    mount --rbind /dev "$ROOT_MNT/dev"
    mount --make-rslave "$ROOT_MNT/dev"

    mount --rbind /run "$ROOT_MNT/run"
    mount --make-rslave "$ROOT_MNT/run"

    mkdir -p "$ROOT_MNT/etc/portage"

    cat > "$ROOT_MNT/etc/portage/make.conf" <<MAKECONF
COMMON_FLAGS="-O2 -pipe"

CFLAGS="\${COMMON_FLAGS}"
CXXFLAGS="\${COMMON_FLAGS}"
FCFLAGS="\${COMMON_FLAGS}"
FFLAGS="\${COMMON_FLAGS}"

MAKEOPTS="-j$(nproc)"

ACCEPT_LICENSE="*"

GRUB_PLATFORMS="efi-64"

VIDEO_CARDS="intel"

USE="X wayland elogind dbus udev"
MAKECONF
}

install_system() {
    header
    echo "Launching Gentoo configuration..."
    echo

    cat > "$ROOT_MNT/root/final-boss-stage2.sh" <<'STAGE2'
#!/bin/bash
set -euo pipefail

source /etc/profile

echo "=========================================="
echo " GENTOO FINAL BOSS - CHROOT"
echo "=========================================="
echo

echo "Syncing Portage..."
emerge-webrsync || emerge --sync

echo
echo "Updating @world..."
emerge --ask=n --verbose --update --deep --newuse @world

echo
echo "Installing base system..."
emerge --ask=n \
    sys-kernel/gentoo-kernel \
    sys-kernel/installkernel \
    sys-boot/grub \
    app-admin/sudo \
    net-misc/networkmanager \
    app-shells/bash-completion

systemctl enable NetworkManager 2>/dev/null || true

echo
echo "Timezone:"
read -rp "Enter timezone [America/Costa_Rica]: " TZONE
TZONE="${TZONE:-America/Costa_Rica}"

ln -sf "/usr/share/zoneinfo/$TZONE" /etc/localtime
hwclock --systohc

echo
echo "Generating locale..."

if grep -q '^#en_US.UTF-8 UTF-8' /etc/locale.gen 2>/dev/null; then
    sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
fi

locale-gen || true
eselect locale set en_US.utf8 || true

echo
echo "Hostname:"
read -rp "Hostname [gentoo]: " HOSTNAME
HOSTNAME="${HOSTNAME:-gentoo}"
echo "$HOSTNAME" > /etc/hostname

echo
echo "Installing GRUB..."

grub-install \
    --target=x86_64-efi \
    --efi-directory=/boot \
    --bootloader-id=Gentoo

grub-mkconfig -o /boot/grub/grub.cfg

echo
echo "Create your user."

read -rp "Username: " USERNAME

while [[ -z "$USERNAME" ]]; do
    read -rp "Username cannot be empty: " USERNAME
done

useradd -m -G wheel,audio,video,input "$USERNAME"

echo
echo "Set root password:"
passwd root

echo
echo "Set user password:"
passwd "$USERNAME"

echo
echo "Configuring sudo..."

mkdir -p /etc/sudoers.d
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel
chmod 440 /etc/sudoers.d/wheel

echo
echo "=========================================="
echo " DESKTOP / WINDOW MANAGER SELECTION"
echo "=========================================="
echo
echo "  [1] dwm"
echo "  [2] KDE Plasma"
echo "  [3] GNOME"
echo "  [4] XFCE"
echo "  [5] LXQt"
echo "  [6] Cinnamon"
echo "  [7] MATE"
echo "  [8] Hyprland"
echo "  [9] i3"
echo " [10] Openbox"
echo " [11] No DE / WM"
echo

read -rp "Selection: " DESKTOP

case "$DESKTOP" in
    1)
        emerge --ask=n x11-wm/dwm x11-misc/dmenu x11-terms/st
        ;;
    2)
        emerge --ask=n kde-plasma/plasma-meta
        ;;
    3)
        emerge --ask=n gnome-base/gnome
        ;;
    4)
        emerge --ask=n xfce-base/xfce4-meta
        ;;
    5)
        emerge --ask=n lxqt-base/lxqt-meta
        ;;
    6)
        emerge --ask=n gnome-extra/cinnamon
        ;;
    7)
        emerge --ask=n mate-base/mate
        ;;
    8)
        emerge --ask=n gui-apps/hyprland
        ;;
    9)
        emerge --ask=n x11-wm/i3
        ;;
    10)
        emerge --ask=n x11-wm/openbox
        ;;
    11)
        echo "No desktop environment selected."
        ;;
    *)
        echo "Invalid desktop selection."
        ;;
esac

echo
echo "=========================================="
echo " INSTALLATION COMPLETE"
echo "=========================================="
echo
echo "Type 'exit' to leave the chroot."
STAGE2

    chmod +x "$ROOT_MNT/root/final-boss-stage2.sh"

    chroot "$ROOT_MNT" /root/final-boss-stage2.sh
}

cleanup() {
    echo
    echo "Cleaning up mounts..."

    if [[ -n "${SWAP:-}" ]]; then
        swapoff "$SWAP" 2>/dev/null || true
    fi

    umount -R "$ROOT_MNT" 2>/dev/null || true
}

main() {
    require_root

    detect_hardware
    disk_menu
    choose_stage3
    extract_stage3
    configure_chroot
    install_system

    cleanup

    echo
    echo "=========================================="
    echo "       GENTOO FINAL BOSS DEFEATED"
    echo "=========================================="
    echo
    echo "You can now reboot."
}

main "$@"
