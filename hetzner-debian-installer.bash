#!/bin/bash
exec 3>&1 4>&2  

# Весь stdout и stderr пишем в лог, но скрываем отладку в консоли
exec > >(tee -a hetzner-debian-installer.log) 2> >(tee -a hetzner-debian-installer.log >&4)  

# Включаем отладочный режим ТОЛЬКО в логах
(set -x; exec 2> >(tee -a hetzner-debian-installer.log >&4))

log() {
    echo "[INFO] $@" | tee /dev/fd/3
}

log_error() {
    echo "[ERROR] $@" | tee /dev/fd/3 >&2
}



CONFIG_FILE="hetzner-debian-installer.conf"
SESSION_NAME="debian_install"

# Load config file if exists
if [ -f "$CONFIG_FILE" ]; then
    echo "Loading configuration from $CONFIG_FILE"
    source "$CONFIG_FILE"
else
    echo "No configuration file found, proceeding interactively."
fi

# Auto-start inside screen session
if [ -z "$STY" ]; then
    if ! command -v screen &>/dev/null; then
        echo "Installing screen..."
        apt update && apt install screen -y
    fi
    echo "Launching installation inside screen session '$SESSION_NAME'..."
    screen -dmS "$SESSION_NAME" bash "$0"
    echo "Reconnect with: screen -r $SESSION_NAME"
    exit 0
fi

screen -S "$STY" -X sessionname "$SESSION_NAME"


### HELPER FUNCTIONS ###

find_disks() {
    lsblk -dpno NAME,TYPE | awk '$2 == "disk" {print $1}'
}

validate_size() {
    local input="$1"
    if [[ "$input" =~ ^[0-9]+[MG]$ ]]; then
        return 0
    else
        return 1
    fi
}

### CONFIGURE FUNCTIONS ###

configure_partitioning() {
    echo "[Configuring] Partitioning parameters..."

    available_disks=( $(find_disks) )
    if [ ${#available_disks[@]} -eq 0 ]; then
        echo "No disks found. Exiting..."
        exit 1
    fi

    echo "Detected disks:"
    for disk in "${available_disks[@]}"; do
        size=$(lsblk -dnbo SIZE "$disk" | awk '{printf "%.1f GB", $1/1024/1024/1024}')
        echo "- $disk ($size)"
    done
    echo ""

    read -rp "Primary disk [${available_disks[0]}]: " PART_DRIVE1
    PART_DRIVE1="${PART_DRIVE1:-${available_disks[0]}}"
    if [ ! -b "$PART_DRIVE1" ]; then
        echo "Error: $PART_DRIVE1 is not a valid block device. Exiting."
        exit 1
    fi

    if [ ${#available_disks[@]} -ge 2 ]; then
        read -rp "Secondary disk for RAID (leave empty if none) [${available_disks[1]}]: " PART_DRIVE2
        PART_DRIVE2="${PART_DRIVE2:-${available_disks[1]}}"
        if [ ! -b "$PART_DRIVE2" ]; then
            echo "Error: $PART_DRIVE2 is not a valid block device. Exiting."
            exit 1
        fi

        read -rp "Use RAID? (yes/no) [yes]: " PART_USE_RAID
        PART_USE_RAID="${PART_USE_RAID:-yes}"
        if [[ "$PART_USE_RAID" != "yes" && "$PART_USE_RAID" != "no" ]]; then
            echo "Invalid input for RAID option. Defaulting to 'yes'."
            PART_USE_RAID="yes"
        fi

        if [ "$PART_USE_RAID" = "yes" ]; then
            read -rp "RAID Level [1]: " PART_RAID_LEVEL
            PART_RAID_LEVEL="${PART_RAID_LEVEL:-1}"
            if ! [[ "$PART_RAID_LEVEL" =~ ^[0-9]+$ ]]; then
                echo "Invalid RAID level. Defaulting to 1."
                PART_RAID_LEVEL="1"
            fi
        fi
    fi

    read -rp "Boot partition size [512M]: " PART_BOOT_SIZE
    if [ -z "$PART_BOOT_SIZE" ]; then
        PART_BOOT_SIZE="512M"
    elif ! validate_size "$PART_BOOT_SIZE"; then
        echo "Invalid boot partition size. Using default [512M]."
        PART_BOOT_SIZE="512M"
    fi

    read -rp "Swap partition size [32G]: " PART_SWAP_SIZE
    if [ -z "$PART_SWAP_SIZE" ]; then
        PART_SWAP_SIZE="32G"
    elif ! validate_size "$PART_SWAP_SIZE"; then
        echo "Invalid swap partition size. Using default [32G]."
        PART_SWAP_SIZE="32G"
    fi

    # Allowed root filesystem types
    allowed_root_fs=("ext4" "xfs" "btrfs" "ext3" "ext2")
    read -rp "Root filesystem type [ext4]: " PART_ROOT_FS
    PART_ROOT_FS="${PART_ROOT_FS:-ext4}"
    valid_root_fs="no"
    for fs in "${allowed_root_fs[@]}"; do
        if [ "$PART_ROOT_FS" = "$fs" ]; then
            valid_root_fs="yes"
            break
        fi
    done
    if [ "$valid_root_fs" = "no" ]; then
        echo "Invalid root filesystem type. Defaulting to ext4."
        PART_ROOT_FS="ext4"
    fi

    # Allowed boot filesystem types
    allowed_boot_fs=("ext3" "ext4" "vfat")
    read -rp "Boot filesystem type [ext3]: " PART_BOOT_FS
    PART_BOOT_FS="${PART_BOOT_FS:-ext3}"
    valid_boot_fs="no"
    for fs in "${allowed_boot_fs[@]}"; do
        if [ "$PART_BOOT_FS" = "$fs" ]; then
            valid_boot_fs="yes"
            break
        fi
    done
    if [ "$valid_boot_fs" = "no" ]; then
        echo "Invalid boot filesystem type. Defaulting to ext3."
        PART_BOOT_FS="ext3"
    fi
}

configure_debian_install() {
    echo "[Configuring] Debian installation parameters..."
    
    # Проверка прав (не запущен ли скрипт без root)
    if [ "$(id -u)" -ne 0 ]; then
        echo "Error: This script must be run as root!" >&2
        exit 1
    fi

    # Выбор версии Debian
    read -rp "Select Debian version (stable, testing, sid) [stable]: " DEBIAN_RELEASE
    DEBIAN_RELEASE="${DEBIAN_RELEASE:-stable}"
    case "$DEBIAN_RELEASE" in
        stable|testing|sid) ;;
        *)  
            echo "Invalid Debian version input, defaulting to 'stable'."
            DEBIAN_RELEASE="stable"
            ;;
    esac

    # Ввод зеркала Debian
    read -rp "Enter Debian repository mirror [http://deb.debian.org/debian/]: " DEBIAN_MIRROR
    DEBIAN_MIRROR="${DEBIAN_MIRROR:-http://deb.debian.org/debian/}"

    # Проверка доступности репозитория (более надежный метод)
    if ! wget --spider -q "$DEBIAN_MIRROR/dists/$DEBIAN_RELEASE/Release"; then
        echo "Error: Debian mirror '$DEBIAN_MIRROR' is not reachable. Exiting." >&2
        exit 1
    fi

    # Массив точек монтирования
    declare -A MOUNT_POINTS=(
        ["BOOT"]="/mnt/md0p1"
        ["SWAP"]="/mnt/md0p2"
        ["ROOT"]="/mnt/md0p3"
    )

    # Функция проверки и создания путей
    validate_mount_point() {
        local mount_point=$1
        if [ -z "$mount_point" ]; then
            echo "Error: Mount point cannot be empty. Exiting." >&2
            exit 1
        fi

        if [ ! -d "$mount_point" ]; then
            echo "Warning: Mount point '$mount_point' does not exist. Creating it..."
            mkdir -p "$mount_point" || { echo "Error: Failed to create $mount_point. Exiting."; exit 1; }
            echo "Successfully created: $mount_point"
        fi
    }

    # Функция проверки монтирования и размонтирования
    ensure_unmounted() {
        local mount_point=$1
        if findmnt -r "$mount_point" >/dev/null 2>&1; then
            echo "Warning: $mount_point is currently mounted."
            read -rp "Do you want to unmount it? (y/N): " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                umount -l "$mount_point" || { echo "Error: Failed to unmount $mount_point. Exiting."; exit 1; }
                echo "Unmounted: $mount_point"
            else
                echo "Error: Installation cannot proceed with mounted target. Exiting."
                exit 1
            fi
        fi
    }

    # Запрос у пользователя и проверка точек монтирования
    for key in "${!MOUNT_POINTS[@]}"; do
        read -rp "Enter installation target mount point for ${key} [${MOUNT_POINTS[$key]}]: " user_input
        MOUNT_POINTS[$key]="${user_input:-${MOUNT_POINTS[$key]}}"
        ensure_unmounted "${MOUNT_POINTS[$key]}"
        validate_mount_point "${MOUNT_POINTS[$key]}"
    done
}


configure_network() {
    echo "[Configuring] Network parameters"
    : "${NETWORK_USE_DHCP:?$(read -rp 'Use DHCP? (yes/no): ' NETWORK_USE_DHCP)}"
}

configure_bootloader() {
    echo "[Configuring] Bootloader parameters"
    if [ -z "${GRUB_TARGET_DRIVES[*]}" ]; then
        read -rp 'GRUB target drives (space-separated): ' -a GRUB_TARGET_DRIVES
    fi
}

configure_initial_config() {
    echo "[Configuring] Initial system settings"
    : "${HOSTNAME:?$(read -rp 'Hostname: ' HOSTNAME)}"
    : "${ROOT_PASSWORD:?$(read -rp 'Root password: ' ROOT_PASSWORD)}"
}

configure_cleanup() {
    echo "[Configuring] Cleanup parameters (usually nothing to configure)"
}

### RUN FUNCTIONS ###
run_partitioning() {
    echo "[Running] Partitioning and RAID setup..."

    if [ "${PART_USE_RAID:-no}" = "yes" ] && [ -n "${PART_DRIVE2:-}" ]; then
        echo "Creating RAID partitions on physical disks..."
        for disk in "$PART_DRIVE1" "$PART_DRIVE2"; do
            parted -s "$disk" mklabel gpt
            parted -s "$disk" mkpart primary ext4 1MiB 100%
        done

        RAID_PART1="${PART_DRIVE1}p1"
        RAID_PART2="${PART_DRIVE2}p1"
        echo "Creating RAID${PART_RAID_LEVEL} array on $RAID_PART1 and $RAID_PART2..."
        mdadm --create --verbose /dev/md0 --level="$PART_RAID_LEVEL" --raid-devices=2 "$RAID_PART1" "$RAID_PART2"
        RAID_DEVICE="/dev/md0"
        sleep 5
    else
        RAID_DEVICE="$PART_DRIVE1"
    fi

    echo "Partitioning RAID device $RAID_DEVICE..."
    parted -s "$RAID_DEVICE" mklabel gpt
    parted -s "$RAID_DEVICE" mkpart primary "$PART_BOOT_FS" 1MiB "$PART_BOOT_SIZE"
    parted -s "$RAID_DEVICE" mkpart primary linux-swap "$PART_BOOT_SIZE" "$PART_SWAP_SIZE"
    parted -s "$RAID_DEVICE" mkpart primary "$PART_ROOT_FS" "$PART_SWAP_SIZE" 100%
    sleep 2

    echo "Formatting partitions on $RAID_DEVICE..."
    mkfs."$PART_BOOT_FS" -F "${RAID_DEVICE}p1"
    mkswap "${RAID_DEVICE}p2"
    mkfs."$PART_ROOT_FS" -F "${RAID_DEVICE}p3"

    echo "[Running] Partitioning and formatting complete."
}

run_debian_install() {
    echo "[Running] Installing Debian base system with debootstrap..."

    # Проверка прав root
    if [ "$(id -u)" -ne 0 ]; then
        echo "Error: This script must be run as root!" >&2
        exit 1
    fi

    # Проверка наличия пути установки
    for key in "${!MOUNT_POINTS[@]}"; do
        if [ ! -d "${MOUNT_POINTS[$key]}" ]; then
            echo "Creating mount point: ${MOUNT_POINTS[$key]}..."
            mkdir -p "${MOUNT_POINTS[$key]}" || {
                echo "Error: Failed to create ${MOUNT_POINTS[$key]}. Exiting."
                exit 1
            }
        fi
    done

    # Проверка и монтирование ROOT-раздела
    if ! mountpoint -q "${MOUNT_POINTS[ROOT]}"; then
        echo "Mounting root partition (${PART_DRIVE1}p3) to ${MOUNT_POINTS[ROOT]}..."
        mount "${PART_DRIVE1}p3" "${MOUNT_POINTS[ROOT]}" || {
            echo "Error: Failed to mount root partition on ${MOUNT_POINTS[ROOT]}. Exiting."
            exit 1
        }
    else
        echo "Warning: ${MOUNT_POINTS[ROOT]} is already mounted."
    fi

    # Проверка и монтирование BOOT-раздела (если задан)
    if [ -n "${MOUNT_POINTS[BOOT]}" ] && [ -d "${MOUNT_POINTS[BOOT]}" ]; then
        if ! mountpoint -q "${MOUNT_POINTS[BOOT]}"; then
            echo "Mounting boot partition (${PART_DRIVE1}p1) to ${MOUNT_POINTS[BOOT]}..."
            mount "${PART_DRIVE1}p1" "${MOUNT_POINTS[BOOT]}" || {
                echo "Error: Failed to mount boot partition. Exiting."
                exit 1
            }
        else
            echo "Warning: ${MOUNT_POINTS[BOOT]} is already mounted."
        fi
    fi

    # Монтирование SWAP-раздела (если указан)
    if [ -n "${MOUNT_POINTS[SWAP]}" ] && [ -d "${MOUNT_POINTS[SWAP]}" ]; then
        if ! swapon --show | grep -q "${MOUNT_POINTS[SWAP]}"; then
            echo "Activating swap partition (${PART_DRIVE1}p2)..."
            swapon "${PART_DRIVE1}p2" || {
                echo "Error: Failed to activate swap partition. Exiting."
                exit 1
            }
        else
            echo "Warning: Swap partition is already active."
        fi
    fi

    # Запуск debootstrap
    echo "Starting debootstrap for Debian $DEBIAN_RELEASE using mirror $DEBIAN_MIRROR..."
    debootstrap --arch=amd64 "$DEBIAN_RELEASE" "${MOUNT_POINTS[ROOT]}" "$DEBIAN_MIRROR"
    if [ $? -ne 0 ]; then
        echo "Error: debootstrap failed. Exiting."
        exit 1
    fi

    echo "Debian base system installed successfully in ${MOUNT_POINTS[ROOT]}."
}


run_network() { echo "[Running] Network setup..."; }
run_bootloader() { echo "[Running] Bootloader installation..."; }
run_initial_config() { echo "[Running] Initial configuration..."; }
run_cleanup() { echo "[Running] Cleanup and reboot..."; }

### Summary and Confirmation ###
summary_and_confirm() {
    echo ""
    echo "🚀 Configuration Summary:"
    echo "----------------------------------------"
    echo "Primary disk:          $PART_DRIVE1"
    echo "Secondary disk:        $PART_DRIVE2"
    echo "Use RAID:              $PART_USE_RAID (Level: $PART_RAID_LEVEL)"
    echo "Boot size/filesystem:  $PART_BOOT_SIZE / $PART_BOOT_FS"
    echo "Swap size:             $PART_SWAP_SIZE"
    echo "Root filesystem:       $PART_ROOT_FS"
    echo "Debian release/mirror: $DEBIAN_RELEASE / $DEBIAN_MIRROR"
    echo "Use DHCP:              $NETWORK_USE_DHCP"
    echo "GRUB targets:          ${GRUB_TARGET_DRIVES[*]}"
    echo "Hostname:              $HOSTNAME"
    echo "----------------------------------------"
    read -rp "Start installation with these settings? (yes/no)[no]: " CONFIRM
    if [ "$CONFIRM" == "yes" ]; then
        read -rp "Do you want to save the configuration? (yes/no) [yes]: " ${SAVE_CONFIG:-yes}
        if [ "$SAVE_CONFIG" == "yes" ]; then
            save_configuration
        fi
        
    elif [ "$CONFIRM" == "no" ];then
        configuration
    else
        echo "Installation aborted by user."
        exit 1
    fi
}

save_configuration() {
    CONFIG_LINES=(
        "# Partitioning"
        "PART_DRIVE1=${PART_DRIVE1}"
        "PART_DRIVE2=${PART_DRIVE2}"
        "PART_USE_RAID=${PART_USE_RAID}"
        "PART_RAID_LEVEL=${PART_RAID_LEVEL}"
        "PART_BOOT_SIZE=${PART_BOOT_SIZE}"
        "PART_SWAP_SIZE=${PART_SWAP_SIZE}"
        "PART_ROOT_FS=${PART_ROOT_FS}"
        "PART_BOOT_FS=${PART_BOOT_FS}"
        ""
        "# Debian installation"
        "DEBIAN_RELEASE=${DEBIAN_RELEASE}"
        "DEBIAN_MIRROR=${DEBIAN_MIRROR}"
        "INSTALL_TARGET_BOOT=${INSTALL_TARGET_BOOT}"
        "INSTALL_TARGET_SWAP=${INSTALL_TARGET_SWAP}"
        "INSTALL_TARGET_ROOT=${INSTALL_TARGET_ROOT}"
        ""
        "# Network"
        "NETWORK_USE_DHCP=${NETWORK_USE_DHCP}"
        ""
        "# Bootloader"
        "GRUB_TARGET_DRIVES=${GRUB_TARGET_DRIVES[*]}"
        ""
        "# System settings"
        "HOSTNAME=${HOSTNAME}"
    )
    printf "%s\n" "${CONFIG_LINES[@]}" > "$CONFIG_FILE"
    echo "Configuration saved to $CONFIG_FILE"
    echo ""
}

### Entrypoints ###
configuring() {
    configure_partitioning
    configure_debian_install
    #configure_network
    #configure_bootloader
    #configure_initial_config
    #configure_cleanup
}

running() {
    run_partitioning
    run_debian_install
    run_network
    run_bootloader
    run_initial_config
    run_cleanup
}

main() {
    configuring
    summary_and_confirm
    running
}

main
