#!/usr/bin/env bash
set -euo pipefail;

EFI_SIZE="1024";
DISK="";
ROOTPASS="";
INIT="";
REMOVABLE_FLAG="";
USE_LUKS=1;
BOOTLOADER="grub";
MAPPER_NAME="cryptroot";

SELF_PATH="${BASH_SOURCE}";
[[ "${SELF_PATH}" != /* ]] && SELF_PATH="${PWD}/${SELF_PATH}";
SCRIPT_DIR="${SELF_PATH%/*}";

function _error_exit {
    local reason="${1}";
    printf "%b%s%b\n" "\e[1;31m" "${reason^}" "\e[m" >&2;
    exit 1;
}

function _ask {
    local question="${1}";
    local default="${2}";
    local options response;
    [[ "${default,,}" == "y" ]] && options="Y/n" || options="y/N";
    printf -v question "%s [%s]: " "${1}" "${options}";
    read -r -p "${question}" response </dev/tty;
    case "${response,,}" in
        "y"|"yes") return 0 ;;
        "n"|"no")  return 1 ;;
        *) [[ "${default,,}" == "y" ]] && return 0 || return 1 ;;
    esac
}

function _ensure_tools {
    printf "[*] Updating database and installing tools...\n";
    pacman -Sy --noconfirm gptfdisk util-linux cryptsetup btrfs-progs efibootmgr;
}

function _choose_init {
    printf "1) openrc  2) runit  3) dinit  4) s6\n";
    printf "Init: "; read -r ic;
    case "${ic}" in
        1) INIT="openrc" ;;
        2) INIT="runit" ;;
        3) INIT="dinit" ;;
        4) INIT="s6" ;;
        *) INIT="openrc" ;;
    esac
}

function _choose_bootloader {
    printf "1) GRUB (Standard)  2) rEFInd (Graphical/Auto-detect)\n";
    printf "Bootloader: "; read -r bc;
    [[ "${bc}" == "2" ]] && BOOTLOADER="refind" || BOOTLOADER="grub";
}

function _setup_encryption {
    if _ask "Enable LUKS Encryption?" "n"; then
        USE_LUKS=0;
        printf "LUKS Passphrase: "; read -rs LUKS_PASS; echo;
        printf "Confirm Passphrase: "; read -rs LUKS_PASS_CONFIRM; echo;
        [[ "${LUKS_PASS}" != "${LUKS_PASS_CONFIRM}" ]] && _error_exit "passwords do not match";
    fi
}

function _ask_info {
    lsblk -dpno NAME,SIZE,MODEL | grep -E "/dev/(sd|vd|nvme)";
    printf "Target Disk: "; read -r DISK;
    [[ ! -b "${DISK}" ]] && _error_exit "invalid device";
    if ! _ask "Destroy all data on ${DISK}?" "n"; then _error_exit "aborted"; fi
    printf "Root password: "; read -rs ROOTPASS; echo;
    _ask "External/removable drive?" "n" && REMOVABLE_FLAG="--removable";
}

function _partition_storage {
    printf "[*] Partitioning and creating BTRFS subvolumes...\n";
    wipefs -a "${DISK}";
    sgdisk --zap-all "${DISK}";
    sgdisk -n 1:0:+${EFI_SIZE}M -t 1:ef00 "${DISK}";
    sgdisk -n 2:0:0           -t 2:8300 "${DISK}";
    
    local efi_p root_p target_dev;
    if [[ "${DISK}" == *nvme* ]]; then
        efi_p="${DISK}p1"; root_p="${DISK}p2";
    else
        efi_p="${DISK}1"; root_p="${DISK}2";
    fi

    mkfs.fat -F32 "${efi_p}";
    target_dev="${root_p}";

    if [[ "${USE_LUKS}" -eq 0 ]]; then
        printf "%s" "${LUKS_PASS}" | cryptsetup luksFormat "${root_p}" -;
        printf "%s" "${LUKS_PASS}" | cryptsetup open "${root_p}" "${MAPPER_NAME}" -;
        target_dev="/dev/mapper/${MAPPER_NAME}";
    fi

    mkfs.btrfs -f "${target_dev}";
    mount "${target_dev}" /mnt;
    btrfs subvolume create /mnt/@;
    btrfs subvolume create /mnt/@home;
    btrfs subvolume create /mnt/@log;
    btrfs subvolume create /mnt/@pkg;
    umount /mnt;

    local m_opts="noatime,compress=zstd,ssd,discard=async";
    mount -o "${m_opts},subvol=@" "${target_dev}" /mnt;
    mount --mkdir -o "${m_opts},subvol=@home" "${target_dev}" /mnt/home;
    mount --mkdir -o "${m_opts},subvol=@log" "${target_dev}" /mnt/var/log;
    mount --mkdir -o "${m_opts},subvol=@pkg" "${target_dev}" /mnt/var/cache/pacman/pkg;
    mount --mkdir "${efi_p}" /mnt/boot/efi;
}

function _run_basestrap {
    local ucode="amd-ucode";
    [[ -f /proc/cpuinfo ]] && grep -q "GenuineIntel" /proc/cpuinfo && ucode="intel-ucode";
    local pkgs=("base" "base-devel" "linux" "linux-firmware" "${ucode}" "${INIT}" "elogind-${INIT}" "efibootmgr" "dhcpcd" "dhcpcd-${INIT}" "iwd" "iwd-${INIT}" "btrfs-progs" "nano");
    [[ "${USE_LUKS}" -eq 0 ]] && pkgs+=("cryptsetup");
    [[ "${BOOTLOADER}" == "grub" ]] && pkgs+=("grub" "os-prober") || pkgs+=("refind");
    
    basestrap /mnt "${pkgs[@]}";
}

function _finalize {
    local root_part uuid;
    if [[ "${DISK}" == *nvme* ]]; then
        root_part="${DISK}p2";
    else
        root_part="${DISK}2";
    fi
    
    read -r uuid < <(blkid -s UUID -o value "${root_part}");
    
    fstabgen -U /mnt >> /mnt/etc/fstab;
    
    artix-chroot /mnt /bin/bash <<EOF
sed -i 's/^HOOKS=(base udev/HOOKS=(base udev encrypt btrfs/' /etc/mkinitcpio.conf;
mkinitcpio -P;

if [[ "${BOOTLOADER}" == "grub" ]]; then
    echo "GRUB_DISABLE_OS_PROBER=false" >> /etc/default/grub;
    if [[ "${USE_LUKS}" -eq 0 ]]; then
        sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=\"|GRUB_CMDLINE_LINUX_DEFAULT=\"cryptdevice=UUID=${uuid}:${MAPPER_NAME} root=/dev/mapper/${MAPPER_NAME} rootflags=subvol=@ |" /etc/default/grub;
    else
        sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=\"|GRUB_CMDLINE_LINUX_DEFAULT=\"rootflags=subvol=@ |" /etc/default/grub;
    fi
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ARTIX --recheck ${REMOVABLE_FLAG};
    grub-mkconfig -o /boot/grub/grub.cfg;
else
    refind-install;
    if [[ "${USE_LUKS}" -eq 0 ]]; then
        printf "\"Boot with LUKS\" \"cryptdevice=UUID=%s:%s root=/dev/mapper/%s rw rootflags=subvol=@ initrd=/boot/intel-ucode.img initrd=/boot/amd-ucode.img initrd=/boot/initramfs-linux.img\"\n" "${uuid}" "${MAPPER_NAME}" "${MAPPER_NAME}" > /boot/refind_linux.conf;
    else
        printf "\"Boot BTRFS\" \"root=UUID=%s rw rootflags=subvol=@ initrd=/boot/intel-ucode.img initrd=/boot/amd-ucode.img initrd=/boot/initramfs-linux.img\"\n" "${uuid}" > /boot/refind_linux.conf;
    fi
fi

printf "root:%s" "${ROOTPASS}" | chpasswd;
case "${INIT}" in
    openrc) rc-update add dhcpcd default; rc-update add iwd default ;;
    runit)  ln -s /etc/runit/sv/dhcpcd /etc/runit/runsvdir/default/; ln -s /etc/runit/sv/iwd /etc/runit/runsvdir/default/ ;;
    dinit)  mkdir -p /etc/dinit.d/boot.d; ln -s ../dhcpcd /etc/dinit.d/boot.d/; ln -s ../iwd /etc/dinit.d/boot.d/ ;;
esac
EOF
}

function _setup_handoff {
    local p search_paths=( "${SCRIPT_DIR}/../" "${SCRIPT_DIR}/" );
    for p in "${search_paths[@]}"; do
        if [[ -f "${p}firstboot.sh" ]]; then
            install -Dm755 "${p}firstboot.sh" /mnt/usr/local/bin/firstboot.sh;
            install -Dm755 "${p}firstboot_trigger.sh" /mnt/etc/profile.d/firstboot.sh;
            break;
        fi
    done
}

function main {
    [[ ! -d /sys/firmware/efi ]] && _error_exit "no uefi";
    _ensure_tools;
    _choose_init;
    _choose_bootloader;
    _setup_encryption;
    _ask_info;
    _partition_storage;
    _run_basestrap;
    _finalize;
    _setup_handoff;
    umount -R /mnt;
    printf "Done. BTRFS system ready.\n";
}

main;
