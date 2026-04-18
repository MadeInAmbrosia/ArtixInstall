#!/bin/bash
set -euo pipefail

ROOTPASS=""
INIT=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE}")" && pwd)"

check_uefi() {
    [[ ! -d /sys/firmware/efi ]] && exit 1
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

verify_mounts() {
    if ! findmnt /mnt >/dev/null || ! findmnt /mnt/boot/efi >/dev/null; then
        exit 1
    fi
}

run_basestrap() {
    local ucode="amd-ucode"
    grep -q "GenuineIntel" /proc/cpuinfo && ucode="intel-ucode"
    basestrap /mnt base base-devel linux linux-firmware "$ucode" \
        "$INIT" elogind-"$INIT" grub efibootmgr os-prober \
        dhcpcd dhcpcd-"$INIT" iwd iwd-$INIT nano artix-archlinux-support
}

finalize_base() {
    fstabgen -U /mnt >> /mnt/etc/fstab
    artix-chroot /mnt /bin/bash <<EOF
echo "GRUB_DISABLE_OS_PROBER=false" >> /etc/default/grub
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ARTIX --recheck --removable
grub-mkconfig -o /boot/grub/grub.cfg
echo "root:$ROOTPASS" | chpasswd
sed -i 's/#ParallelDownloads = 5/ParallelDownloads = 10/' /etc/pacman.conf
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
    fi
}

main() {
    check_uefi
    choose_init
    verify_mounts
    read -rsp "Root password: " ROOTPASS; echo
    run_basestrap
    finalize_base
    setup_handoff
    umount -R /mnt
     echo "[✓] Core installation finished. Reboot to launch the wizard."
}
main
