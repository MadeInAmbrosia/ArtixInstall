#!/bin/bash
set -euo pipefail

EFI_SIZE="1024"
DISK=""
ROOTPASS=""
INIT=""
REMOVABLE_FLAG=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE}")" && pwd)"

ensure_tools() {
    echo "[*] Installing partitioning tools..."
    pacman -Sy --noconfirm gptfdisk util-linux
}

choose_init() {
    echo "1) openrc  2) runit  3) dinit  4) s6"
    read -rp "Init: " ic
    case "$ic" in
        1) INIT="openrc" ;;
        2) INIT="runit" ;;
        3) INIT="dinit" ;;
        4) INIT="s6" ;;
        *) INIT="openrc" ;;
    esac
}

ask_info() {
    lsblk -dpno NAME,SIZE,MODEL | grep -E "/dev/(sd|vd|nvme)"
    read -rp "Disk: " DISK
    [[ ! -b "$DISK" ]] && exit 1
    read -rsp "Root password: " ROOTPASS; echo
    
    read -rp "Installing to an external/removable drive? (y/N): " rem
    if [[ "$rem" =~ ^([yY][eE][sS]|[yY])$ ]]; then
        REMOVABLE_FLAG="--removable"
    else
        REMOVABLE_FLAG=""
    fi
}

partition_storage() {
    wipefs -a "$DISK"
    sgdisk --zap-all "$DISK"
    sgdisk -n 1:0:+${EFI_SIZE}M -t 1:ef00 "$DISK"
    sgdisk -n 2:0:0           -t 2:8300 "$DISK"
    
    if [[ "$DISK" =~ "nvme" ]]; then
        EFI_PART="${DISK}p1"; ROOT_PART="${DISK}p2"
    else
        EFI_PART="${DISK}1"; ROOT_PART="${DISK}2"
    fi

    mkfs.fat -F32 "$EFI_PART"
    mkfs.ext4 -F "$ROOT_PART"
    mount "$ROOT_PART" /mnt
    mount --mkdir "$EFI_PART" /mnt/boot/efi
}

run_basestrap() {
    local ucode="amd-ucode"
    grep -q "GenuineIntel" /proc/cpuinfo && ucode="intel-ucode"
    basestrap /mnt base base-devel linux linux-firmware "$ucode" \
        "$INIT" elogind-$INIT grub efibootmgr os-prober \
        dhcpcd dhcpcd-$INIT iwd iwd-$INIT nano
}

finalize() {
    fstabgen -U /mnt >> /mnt/etc/fstab
    artix-chroot /mnt /bin/bash <<EOF
echo "GRUB_DISABLE_OS_PROBER=false" >> /etc/default/grub
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ARTIX --recheck $REMOVABLE_FLAG
grub-mkconfig -o /boot/grub/grub.cfg
echo "root:$ROOTPASS" | chpasswd
case "$INIT" in
    openrc) rc-update add dhcpcd default; rc-update add iwd default ;;
    runit)  ln -s /etc/runit/sv/dhcpcd /etc/runit/runsvdir/default/; ln -s /etc/runit/sv/iwd /etc/runit/runsvdir/default/ ;;
    dinit)  mkdir -p /etc/dinit.d/boot.d; ln -s ../dhcpcd /etc/dinit.d/boot.d/; ln -s ../iwd /etc/dinit.d/boot.d/ ;;
esac
EOF
}

setup_handoff() {
    if [ -f "$SCRIPT_DIR/../firstboot.sh" ]; then
        install -Dm755 "$SCRIPT_DIR/../firstboot.sh" /mnt/usr/local/bin/firstboot.sh
        install -Dm755 "$SCRIPT_DIR/../firstboot_trigger.sh" /mnt/etc/profile.d/firstboot.sh
    elif [ -f "$SCRIPT_DIR/firstboot.sh" ]; then
        install -Dm755 "$SCRIPT_DIR/firstboot.sh" /mnt/usr/local/bin/firstboot.sh
        install -Dm755 "$SCRIPT_DIR/firstboot_trigger.sh" /mnt/etc/profile.d/firstboot.sh
    fi
}

main() {
    ensure_tools
    choose_init
    ask_info
    partition_storage
    run_basestrap
    finalize
    setup_handoff
    umount -R /mnt
}
main

