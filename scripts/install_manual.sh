#!/bin/bash
set -euo pipefail

#################
# CONFIG
#################

LOCALE="en_US.UTF-8"
TIMEZONE="Europe/Berlin"
H_NAME="artix"

DISK=""
WITH_HOME="n"

EFI_SIZE="1024"

ROOT_SIZE=""
SWAP_SIZE=""
HOME_SIZE=""

EFI_PART=""
ROOT_PART=""
SWAP_PART=""
HOME_PART=""

ROOTPASS=""
ROOTPASS_CONFIRM=""

#################
# UTILS
#################

pause() {
    read -rp "Press ENTER to continue..."
}

hr() {
    echo "---------------------------------------"
}

#################
# CHECKS
#################

check_efi() {
    [[ -d /sys/firmware/efi ]] || {
        echo "[ERROR] EFI mode required."
        exit 1
    }
}

ensure_tools() {
    echo "Installing required tools..."
    pacman -Sy --noconfirm gptfdisk parted
}

ask_passwords() {
    echo
    echo "[!] Root password setup"
    hr

    read -rsp "Enter root password: " ROOTPASS
    echo
    read -rsp "Confirm root password: " ROOTPASS_CONFIRM
    echo

    [[ "$ROOTPASS" == "$ROOTPASS_CONFIRM" ]] || {
        echo "[ERROR] Passwords do not match."
        exit 1
    }

    if [[ -z "$ROOTPASS" ]]; then
        echo "[ERROR] Empty password not allowed."
        exit 1
    fi
}

#################
# DISK SELECTION
#################

show_disks() {
    echo "[*] Current disks layout:"
    hr
    lsblk -f
    hr
}

detect_mounted() {
    echo
    echo "[*] Detecting mounted system..."
    hr

    ROOT_PART=$(findmnt -n -o SOURCE /mnt 2>/dev/null || true)
    EFI_PART=$(findmnt -n -o SOURCE /mnt/boot/efi 2>/dev/null || true)
    HOME_PART=$(findmnt -n -o SOURCE /mnt/home 2>/dev/null || true)

    SWAP_PART=$(swapon --noheadings --raw 2>/dev/null | awk 'NR==1 {print $1}' || true)

    echo "ROOT: $ROOT_PART"
    echo "EFI:  $EFI_PART"
    echo "HOME: ${HOME_PART:-[not mounted]}"
    echo "SWAP: ${SWAP_PART:-[not active]}"

    # REQUIRED check
    if [[ -z "$ROOT_PART" ]]; then
        echo "[ERROR] Root partition is not mounted at /mnt"
        exit 1
    fi

    # OPTIONAL: warn but don't fail
    if [[ -z "$EFI_PART" ]]; then
        echo "[WARN] EFI partition not mounted at /mnt/boot/efi"
    fi

    if [[ -z "$SWAP_PART" ]]; then
        echo "[WARN] No active swap detected"
    fi

    # HOME is optional by design
    if [[ -z "$HOME_PART" ]]; then
        echo "[INFO] No /home partition detected (optional)"
    fi
}

#################
# BASE INSTALL
#################

install_base() {
    echo "[5] Installing base system..."
    hr

    basestrap /mnt \
        base base-devel linux linux-firmware \
        runit elogind-runit \
        grub efibootmgr \
        fastfetch nano \
        dhcpcd dhcpcd-runit \
        iwd iwd-runit
}

gen_fstab() {
    echo "[6] Generating filesystem table..."
    fstabgen -U /mnt >>/mnt/etc/fstab
}

#################
# CHROOT CONFIG
#################

configure_system() {
    echo "[7] System config (chroot)..."
    hr

    read -rp "Timezone (e.g. Europe/Berlin [default]): " TIMEZONE

    artix-chroot /mnt /bin/bash <<EOF
set -e

ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

echo "$LOCALE UTF-8" >> /etc/locale.gen
locale-gen

echo "LANG=$LOCALE" > /etc/locale.conf

echo "$H_NAME" > /etc/hostname

echo "127.0.1.1        $H_NAME.localdomain        $H_NAME" >> /etc/hosts

grub-install \
    --target=x86_64-efi \
    --efi-directory=/boot/efi \
    --bootloader-id=ARTIX \
    --recheck

grub-mkconfig -o /boot/grub/grub.cfg

echo "root:$ROOTPASS" | chpasswd

EOF
}

#################
# CLEANUP
#################

cleanup() {
    echo "[8] Cleaning up..."
    umount -R /mnt || true
}

#################
# MAIN FLOW
#################

main() {
    check_efi
    ensure_tools

    echo "=== ARTIX EFI INSTALLER ==="
    echo "[!] This installer assumes:"
    echo "    - partitions are already created"
    echo "    - filesystems are already formatted"
    echo "    - everything is already mounted under /mnt"
    echo
    pause

    show_disks

    read -rp "Is your system mounted correctly at /mnt? (y/n): " CONFIRM
    [[ "$CONFIRM" == "y" ]] || exit 1

    ask_passwords
    detect_mounted

    install_base
    gen_fstab
    configure_system
    cleanup

    echo
    echo "[✓] INSTALL COMPLETE"
    echo "You may reboot now."
}

main
