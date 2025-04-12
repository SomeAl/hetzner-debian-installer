#!/bin/bash  
LOG_FILE="error.log"

exec 3>&1 4>&2  
# Весь stdout и stderr пишем в лог, но скрываем отладку в консоли
exec > >(tee -a $LOG_FILE) 2> >(tee -a $LOG_FILE >&4)  
# Включаем отладочный режим ТОЛЬКО в логах
(set -x; exec 2> >(tee -a $LOG_FILE >&4))

# функции логирования
log() {
    log "[INFO] $@" | tee /dev/fd/3
}

log_error() {
    log -e "\033[0;31m[ERROR] $@\033[0m" | tee /dev/fd/3 >&2
}


CONFIG_FILE="env.conf"
SESSION_NAME="debian_install"
# Массив точек монтирования
declare -A MOUNT_POINTS
# Массив точек монтирования
MOUNT_POINTS["BOOT"]="/mnt/md0p1"
MOUNT_POINTS["SWAP"]="/mnt/md0p2"
MOUNT_POINTS["ROOT"]="/mnt/md0p3"

if [ "$1" == "c" ];then
    log "======================================================================================================"
    log "Start cleaning"

    # umount 
    umount  "${MOUNT_POINTS[ROOT]}/proc"
    umount  "${MOUNT_POINTS[ROOT]}/sys"
    umount  "${MOUNT_POINTS[ROOT]}/sys"
    umount  "${MOUNT_POINTS[ROOT]}/dev"
    
    #disable swap
    swapoff /dev/md0p2

    #clear dabain install step
    umount /mnt/md0p1
    umount /mnt/md0p2
    umount /mnt/md0p3

    rm -rf /mnt/md0p1
    rm -rf /mnt/md0p2
    rm -rf /mnt/md0p3

    #clear raid install step
    mdadm --stop /dev/md0*
    wipefs -a /dev/nvme{0,1}n1
    mdadm --detail --scan >> /etc/mdadm/mdadm.conf

    log "Finish cleaning"
    log "======================================================================================================"
fi

set -eo pipefail

# Auto-start inside screen session
if [ -z "$STY" ]; then
    if ! command -v screen &>/dev/null; then
        log "Installing screen..."
        apt update && apt install screen -y
    fi
    log "Launching installation inside screen session '$SESSION_NAME'..."
    screen -dmS "$SESSION_NAME" bash "$0"
    log "Reconnect with: screen -r $SESSION_NAME"
    exit 0
fi

screen -S "$STY" -X sessionname "$SESSION_NAME"

################################################################################################################################################
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

# Функция проверки и создания путей
validate_mount_point() {
    local mount_point=$1
    if [ -z "$mount_point" ]; then
        log_error "Mount point cannot be empty. Exiting."
        exit 1
    fi

    if [ ! -d "$mount_point" ]; then
        log "Warning: Mount point '$mount_point' does not exist. Creating it..."
        mkdir -p "$mount_point" || { log_error "Failed to create $mount_point. Exiting."; exit 1; }
        log "Successfully created: $mount_point"
    fi
}

# Функция проверки монтирования и размонтирования
ensure_unmounted() {
    local mount_point=$1
    if findmnt -r "$mount_point" >/dev/null 2>&1; then
        log "Warning: $mount_point is currently mounted."
        read -rp "Do you want to unmount it? (y/N): " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            umount -l "$mount_point" || { log_error "Failed to unmount $mount_point. Exiting."; exit 1; }
            log "Unmounted: $mount_point"
        else
            log_error "Installation cannot proceed with mounted target. Exiting."
            exit 1
        fi
    fi
}

# Функция проверки и создания путей
validate_mount_point() {
    local mount_point=$1
    if [ -z "$mount_point" ]; then
        log_error "Mount point cannot be empty. Exiting."
        exit 1
    fi

    if [ ! -d "$mount_point" ]; then
        log "Warning: Mount point '$mount_point' does not exist. Creating it..."
        mkdir -p "$mount_point" || { log_error "Failed to create $mount_point. Exiting."; exit 1; }
        log "Successfully created: $mount_point"
    fi
}

# Функция проверки монтирования и размонтирования
ensure_unmounted() {
    local mount_point=$1
    if findmnt -r "$mount_point" >/dev/null 2>&1; then
        log "Warning: $mount_point is currently mounted."
        read -rp "Do you want to unmount it? (y/N): " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            umount -l "$mount_point" || { log_error "Failed to unmount $mount_point. Exiting."; exit 1; }
            log "Unmounted: $mount_point"
        else
            log_error "Installation cannot proceed with mounted target. Exiting."
            exit 1
        fi
    fi
}


gen_fstab() {
    local rootfs="$1"
    local fstab_path="$rootfs/etc/fstab"
    log "# /etc/fstab: static file system information." > "$fstab_path"
    log "# <file system> <mount point> <type> <options> <dump> <pass>" >> "$fstab_path"

    blkid -o export | awk -v mp_root="${MOUNT_POINTS[ROOT]}" '
    BEGIN { dev=""; uuid=""; type="" }
    /^DEVNAME=/ { dev=$1; sub(/^DEVNAME=/, "", dev) }
    /^UUID=/ { uuid=$1; sub(/^UUID=/, "", uuid) }
    /^TYPE=/ {
        type=$1; sub(/^TYPE=/, "", type)
        if (dev && uuid && type) {
            if (dev ~ /md0p3/) print "UUID=" uuid " / " type " defaults 0 1"
            else if (dev ~ /md0p1/) print "UUID=" uuid " /boot " type " defaults 0 2"
            else if (dev ~ /md0p2/) print "UUID=" uuid " none swap sw 0 0"
            dev=uuid=type=""
        }
    }' >> "$fstab_path"
}

# Функция проверки существования блочного устройства
device_exists() {
    if [ -b "$1" ]; then
        return 0
    else
        return 1
    fi
}

# Функция для определения, запущена ли система в режиме UEFI
is_uefi_system() {
    if [ -d /sys/firmware/efi ]; then
        return 0
    else
        return 1
    fi
}

# Функция валидации файла конфигурации GRUB
validate_grub_config() {
    if [ -f /boot/grub/grub.cfg ] && [ -s /boot/grub/grub.cfg ]; then
        return 0
    else
        return 1
    fi
}

################################################################################################################################################
### CONFIGURE FUNCTIONS ###

configure_partitioning() {
    log "[Configuring] Partitioning parameters..."

    available_disks=( $(find_disks) )
    if [ ${#available_disks[@]} -eq 0 ]; then
        log "No disks found. Exiting..."
        exit 1
    fi

    log "Detected disks:"
    for disk in "${available_disks[@]}"; do
        size=$(lsblk -dnbo SIZE "$disk" | awk '{printf "%.1f GB", $1/1024/1024/1024}')
        log "- $disk ($size)"
    done
    log ""

    read -rp "Primary disk [${available_disks[0]}]: " PART_DRIVE1
    PART_DRIVE1="${PART_DRIVE1:-${available_disks[0]}}"
    if [ ! -b "$PART_DRIVE1" ]; then
        log_error "$PART_DRIVE1 is not a valid block device. Exiting."
        exit 1
    fi

    if [ ${#available_disks[@]} -ge 2 ]; then
        read -rp "Secondary disk for RAID (leave empty if none) [${available_disks[1]}]: " PART_DRIVE2
        PART_DRIVE2="${PART_DRIVE2:-${available_disks[1]}}"
        if [ ! -b "$PART_DRIVE2" ]; then
            log_error "$PART_DRIVE2 is not a valid block device. Exiting."
            exit 1
        fi

        read -rp "Use RAID? (yes/no) [yes]: " PART_USE_RAID
        PART_USE_RAID="${PART_USE_RAID:-yes}"
        if [[ "$PART_USE_RAID" != "yes" && "$PART_USE_RAID" != "no" ]]; then
            log "Invalid input for RAID option. Defaulting to 'yes'."
            PART_USE_RAID="yes"
        fi

        if [ "$PART_USE_RAID" = "yes" ]; then
            read -rp "RAID Level [1]: " PART_RAID_LEVEL
            PART_RAID_LEVEL="${PART_RAID_LEVEL:-1}"
            if ! [[ "$PART_RAID_LEVEL" =~ ^[0-9]+$ ]]; then
                log "Invalid RAID level. Defaulting to 1."
                PART_RAID_LEVEL="1"
            fi
        fi
    fi

    read -rp "Boot partition size [512M]: " PART_BOOT_SIZE
    if [ -z "$PART_BOOT_SIZE" ]; then
        PART_BOOT_SIZE="512M"
    elif ! validate_size "$PART_BOOT_SIZE"; then
        log "Invalid boot partition size. Using default [512M]."
        PART_BOOT_SIZE="512M"
    fi

    read -rp "Swap partition size [32G]: " PART_SWAP_SIZE
    if [ -z "$PART_SWAP_SIZE" ]; then
        PART_SWAP_SIZE="32G"
    elif ! validate_size "$PART_SWAP_SIZE"; then
        log "Invalid swap partition size. Using default [32G]."
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
        log "Invalid root filesystem type. Defaulting to ext4."
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
        log "Invalid boot filesystem type. Defaulting to ext3."
        PART_BOOT_FS="ext3"
    fi
}

configure_debian_install() {
    log "[Configuring] Debian installation parameters..."
    
    # Проверка прав (не запущен ли скрипт без root)
    if [ "$(id -u)" -ne 0 ]; then
        log_error "This script must be run as root!" >&2
        exit 1
    fi

    # Выбор версии Debian
    read -rp "Select Debian version (stable, testing, sid) [stable]: " DEBIAN_RELEASE
    DEBIAN_RELEASE="${DEBIAN_RELEASE:-stable}"
    case "$DEBIAN_RELEASE" in
        stable|testing|sid) ;;
        *)  
            log "Invalid Debian version input, defaulting to 'stable'."
            DEBIAN_RELEASE="stable"
            ;;
    esac

    # Ввод зеркала Debian
    read -rp "Enter Debian repository mirror [http://deb.debian.org/debian/]: " DEBIAN_MIRROR
    DEBIAN_MIRROR="${DEBIAN_MIRROR:-http://deb.debian.org/debian/}"

    # Проверка доступности репозитория (более надежный метод)
    if ! wget --spider -q "$DEBIAN_MIRROR/dists/$DEBIAN_RELEASE/Release"; then
        log_error "Debian mirror '$DEBIAN_MIRROR' is not reachable. Exiting." >&2
        exit 1
    fi

    # Запрос у пользователя и проверка точек монтирования
    for key in "${!MOUNT_POINTS[@]}"; do
        read -rp "Enter installation target mount point for ${key} [${MOUNT_POINTS[$key]}]: " user_input
        MOUNT_POINTS[$key]="${user_input:-${MOUNT_POINTS[$key]}}"
        ensure_unmounted "${MOUNT_POINTS[$key]}"
    done
}

configure_network() {
    log "[Configuring] Network settings..."

    # Получаем список активных интерфейсов (кроме lo)
    AVAILABLE_IFACES=($(ip -o link show up | awk -F': ' '{print $2}' | grep -v lo))

    if [[ ${#AVAILABLE_IFACES[@]} -eq 0 ]]; then
        log_error "No active network interfaces found." >&2
        exit 1
    elif [[ ${#AVAILABLE_IFACES[@]} -eq 1 ]]; then
        NET_IFACE="${AVAILABLE_IFACES[0]}"
        log "Only one active interface detected: ${NET_IFACE}. Using it automatically."
    else
        log "Available network interfaces:"
        printf " - %s\n" "${AVAILABLE_IFACES[@]}"
        read -rp "Enter network interface to configure [${AVAILABLE_IFACES[0]}]: " NET_IFACE
        NET_IFACE="${NET_IFACE:-${AVAILABLE_IFACES[0]}}"
    fi

    # Проверка существования интерфейса
    if ! ip link show "$NET_IFACE" &>/dev/null; then
        log_error "Network interface '$NET_IFACE' not found. Exiting." >&2
        exit 1
    fi

    # DHCP или Static
    read -rp "Use DHCP? (yes/no) [yes]: " NETWORK_USE_DHCP
    NETWORK_USE_DHCP="${NETWORK_USE_DHCP,,}"  # в нижний регистр
    NETWORK_USE_DHCP="${NETWORK_USE_DHCP:-yes}"

    if [[ "$NETWORK_USE_DHCP" != "no" ]]; then
        log "Using DHCP configuration for interface '$NET_IFACE'."

        # Проверка, работает ли DHCP на интерфейсе
        log "Testing DHCP availability on $NET_IFACE..."
        if command -v dhclient &>/dev/null; then
            dhclient -1 -v "$NET_IFACE" &>/dev/null
            if [ $? -ne 0 ]; then
                log "Warning: Failed to obtain DHCP lease on '$NET_IFACE'."
                read -rp "Continue anyway? (y/N): " confirm
                [[ "$confirm" =~ ^[Yy]$ ]] || exit 1
            else
                log "DHCP lease successfully acquired."
            fi
        else
            log "Warning: dhclient not installed, skipping DHCP lease test."
        fi

        # Очистка переменных статической конфигурации
        NETWORK_IP=""
        NETWORK_MASK=""
        NETWORK_GATEWAY=""
        NETWORK_DNS=""
    else
        # 1. IP
        while true; do
            read -rp "Enter static IP address (e.g., 192.168.1.100): " ip
            [[ -z "$ip" ]] && log_error "IP address is required." && continue

            if ! ipcalc "$ip" &>/dev/null && ! ip addr add "$ip"/32 dev "$NET_IFACE" &>/dev/null; then
                log_error "Invalid IP format."
                continue
            fi

            # Проверка занятости IP
            if command -v arping &>/dev/null; then
                if arping -D -I "$NET_IFACE" "$ip" -c 2 &>/dev/null; then
                    log "Warning: IP address $ip is already in use."
                    read -rp "Continue anyway? (y/N): " confirm
                    [[ ! "$confirm" =~ ^[Yy]$ ]] && continue
                fi
            fi
            break
        done

        # 2. Маска
        read -rp "Enter netmask or CIDR (e.g., 255.255.255.0 or /24) [255.255.255.0]: " netmask
        netmask="${netmask:-255.255.255.0}"
        if [[ "$netmask" =~ ^/[0-9]{1,2}$ ]]; then
            cidr="${netmask#/}"
            if command -v ipcalc &>/dev/null; then
                netmask=$(ipcalc -m "$ip/$cidr" | awk -F'= ' '/Netmask/ {print $2}')
            else
                log "Warning: ipcalc not available to convert CIDR to netmask. Using default: $netmask"
                netmask="255.255.255.0"
            fi
        fi

        # 3. Gateway
        while true; do
            read -rp "Enter gateway (e.g., 192.168.1.1): " gateway
            [[ -z "$gateway" ]] && log_error "Gateway is required." && continue

            if [[ "$gateway" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
                # Проверка пинга
                if ping -c 1 -W 1 "$gateway" &>/dev/null; then
                    break
                else
                    log "Warning: Gateway $gateway is not responding to ping."
                    read -rp "Continue anyway? (y/N): " confirm
                    [[ "$confirm" =~ ^[Yy]$ ]] && break
                fi
            else
                log "Invalid gateway format."
            fi
        done

        # 4. DNS
        read -rp "Enter DNS servers (space-separated) [8.8.8.8]: " dns
        dns="${dns:-8.8.8.8}"
    fi

    # Обновление переменных окружения
    NETWORK_INTERFACE="$NET_IFACE"
    NETWORK_IP="${ip:-""}"
    NETWORK_MASK="${netmask:-"255.255.255.0"}"
    NETWORK_GATEWAY="${gateway:-""}"
    NETWORK_DNS="${dns:-"8.8.8.8"}"
}

# Дополненная функция конфигурации загрузчика
configure_bootloader() {
    log "[Configuring] Bootloader parameters"
    # Если переменная GRUB_TARGET_DRIVES не задана,
    # то в случае RAID используем оба диска, иначе – только основной диск.
    if [ -z "${GRUB_TARGET_DRIVES[*]}" ]; then
        if [ "${PART_USE_RAID:-no}" = "yes" ]; then
            GRUB_TARGET_DRIVES=("$PART_DRIVE1" "$PART_DRIVE2")
        else
            GRUB_TARGET_DRIVES=("$PART_DRIVE1")
        fi
        log "Default GRUB target drives set to: ${GRUB_TARGET_DRIVES[*]}"
        read -rp "Press Enter to accept or type alternative (space-separated list): " -a user_drives
        if [ ${#user_drives[@]} -gt 0 ]; then
            GRUB_TARGET_DRIVES=("${user_drives[@]}")
        fi
    fi

    # Валидация каждого указанного диска
    local valid_drives=()
    for disk in "${GRUB_TARGET_DRIVES[@]}"; do
        while true; do
            if device_exists "$disk"; then
                log "Disk $disk found."
                valid_drives+=("$disk")
                break
            else
                log_error "Disk $disk not found or is not a block device."
                read -rp "Enter a correct device for '$disk' or press Enter to skip: " newdisk
                if [ -z "$newdisk" ]; then
                    log_error "Skipping device $disk (this may affect boot reliability)."
                    break
                else
                    disk="$newdisk"
                fi
            fi
        done
    done
    if [ ${#valid_drives[@]} -eq 0 ]; then
        log_error "No valid GRUB target drives found. Exiting."
        exit 1
    fi
    GRUB_TARGET_DRIVES=("${valid_drives[@]}")
    log "Final GRUB target drives: ${GRUB_TARGET_DRIVES[*]}"
}

configure_initial_config() {
    log "[Configuring] Initial System Configuration"
    
    # Запрос имени хоста с дефолтом "debian-server"
    read -rp "Enter hostname [debian-server]: " input_hostname
    SYSTEM_HOSTNAME="${input_hostname:-debian-server}"
    
    # Запрос имени пользователя с sudo-доступом с дефолтом "admin"
    read -rp "Enter username for sudo access [admin]: " input_sudo_user
    SYSTEM_SUDO_USER="${input_sudo_user:-admin}"
    
    # Запрос пароля для пользователя (без эха)
    while true; do
        read -srp "Enter password for user '$SYSTEM_SUDO_USER': " user_password
        log
        read -srp "Confirm password: " user_password_confirm
        log
        if [ "$user_password" != "$user_password_confirm" ]; then
            log "Passwords do not match. Please try again."
        elif [ -z "$user_password" ]; then
            log "Password cannot be empty. Please try again."
        else
            break
        fi
    done
    
    # Генерация SHA-512 хеша пароля
    SYSTEM_USER_PASSWORD_HASH=$(openssl passwd -6 "$user_password")
    
    # Сохранение параметров в конфигурационный файл
    CONFIG_FILE_NAME="hetzner-debian-installer.conf.bash"
    {
        log "SYSTEM_HOSTNAME=\"$SYSTEM_HOSTNAME\""
        log "SYSTEM_SUDO_USER=\"$SYSTEM_SUDO_USER\""
        log "SYSTEM_USER_PASSWORD_HASH=\"$SYSTEM_USER_PASSWORD_HASH\""
    } > "$CONFIG_FILE_NAME"
    log "Configuration saved to $CONFIG_FILE_NAME"
}

configure_cleanup() {
    log "[Configuring] Cleanup parameters"
    # Если в будущем понадобятся дополнительные настройки очистки (например,
    # пути для удаления временных файлов), их можно задать здесь.
    # Пока данный этап не требует интерактивной настройки.
    log "Cleanup configuration: defaults will be used."
}

################################################################################################################################################
### RUN FUNCTIONS ###

run_partitioning() {
    log "[Running] Partitioning and RAID setup..."

    if [ "${PART_USE_RAID:-no}" = "yes" ] && [ -n "${PART_DRIVE2:-}" ]; then
        log "Creating RAID partitions on physical disks..."
        for disk in "$PART_DRIVE1" "$PART_DRIVE2"; do
            parted -s "$disk" mklabel gpt
            parted -s "$disk" mkpart primary ext4 1MiB 100%
        done

        RAID_PART1="${PART_DRIVE1}p1"
        RAID_PART2="${PART_DRIVE2}p1"
        log "Creating RAID${PART_RAID_LEVEL} array on $RAID_PART1 and $RAID_PART2..."
        mdadm --create --verbose /dev/md0 --level="$PART_RAID_LEVEL" --raid-devices=2 "$RAID_PART1" "$RAID_PART2"
        RAID_DEVICE="/dev/md0"
        sleep 5
    else
        RAID_DEVICE="$PART_DRIVE1"
    fi

    log "Partitioning RAID device $RAID_DEVICE..."
    parted -s "$RAID_DEVICE" mklabel gpt
    parted -s "$RAID_DEVICE" mkpart primary "$PART_BOOT_FS" 1MiB "$PART_BOOT_SIZE"
    parted -s "$RAID_DEVICE" mkpart primary linux-swap "$PART_BOOT_SIZE" "$PART_SWAP_SIZE"
    parted -s "$RAID_DEVICE" mkpart primary "$PART_ROOT_FS" "$PART_SWAP_SIZE" 100%
    sleep 2

    log "Formatting partitions on $RAID_DEVICE..."
    mkfs."$PART_BOOT_FS" -F "${RAID_DEVICE}p1"
    mkswap "${RAID_DEVICE}p2"
    mkfs."$PART_ROOT_FS" -F "${RAID_DEVICE}p3"

    log "[Running] Partitioning and formatting complete."
}

run_debian_install() {
    log "[Running] Installing Debian base system with debootstrap..."

    # Проверка прав root
    if [ "$(id -u)" -ne 0 ]; then
        log_error "This script must be run as root!" >&2
        exit 1
    fi

    # Проверка точек монтирования
    for key in "${!MOUNT_POINTS[@]}"; do
        if [ ! -d "${MOUNT_POINTS[$key]}" ]; then
            log "Creating mount point: ${MOUNT_POINTS[$key]}..."
            mkdir -p "${MOUNT_POINTS[$key]}" || {
                log_error "Failed to create ${MOUNT_POINTS[$key]}. Exiting."
                exit 1
            }
        fi
    done

    # Монтирование ROOT
    if ! mountpoint -q "${MOUNT_POINTS[ROOT]}"; then
        validate_mount_point "${MOUNT_POINTS[ROOT]}"
        log "Mounting root partition (/dev/md0p3) to ${MOUNT_POINTS[ROOT]}..."
        mount "/dev/md0p3" "${MOUNT_POINTS[ROOT]}"
    fi

    # Монтирование BOOT
    if [ -n "${MOUNT_POINTS[BOOT]}" ] && [ -d "${MOUNT_POINTS[BOOT]}" ]; then
        if ! mountpoint -q "${MOUNT_POINTS[BOOT]}"; then
            validate_mount_point "${MOUNT_POINTS[BOOT]}"
            log "Mounting boot partition (/dev/md0p1) to ${MOUNT_POINTS[BOOT]}..."
            mount "/dev/md0p1" "${MOUNT_POINTS[BOOT]}"
        fi
    fi

    # SWAP
    if [ -n "${MOUNT_POINTS[SWAP]}" ] && [ -d "${MOUNT_POINTS[SWAP]}" ]; then
        if ! swapon --show | grep -q "${MOUNT_POINTS[SWAP]}"; then
            validate_mount_point "${MOUNT_POINTS[SWAP]}"
            log "Activating swap partition (/dev/md0p2)..."
            swapon "/dev/md0p2"
        fi
    fi

    # debootstrap
    log "Starting debootstrap for Debian $DEBIAN_RELEASE using mirror $DEBIAN_MIRROR..."
    debootstrap --arch=amd64 "$DEBIAN_RELEASE" "${MOUNT_POINTS[ROOT]}" "$DEBIAN_MIRROR"
    if [ $? -ne 0 ]; then
        log_error "debootstrap failed. Exiting."
        exit 1
    fi

    # Монтирование системных директорий в chroot
    mount --types proc /proc "${MOUNT_POINTS[ROOT]}/proc"
    mount --rbind /sys "${MOUNT_POINTS[ROOT]}/sys"
    mount --make-rslave "${MOUNT_POINTS[ROOT]}/sys"
    mount --rbind /dev "${MOUNT_POINTS[ROOT]}/dev"
    mount --make-rslave "${MOUNT_POINTS[ROOT]}/dev"
    cp /etc/resolv.conf "${MOUNT_POINTS[ROOT]}/etc/"

    log "Generating /etc/fstab..."
    gen_fstab "${MOUNT_POINTS[ROOT]}"

    log "Debian base system installed successfully in ${MOUNT_POINTS[ROOT]}."
    log "You can now chroot into the system for further configuration."
}

run_network() {
    local chroot_dir="${MOUNT_POINTS[ROOT]}"
    local target_config="$chroot_dir/etc/network/interfaces"

    log "Generating /etc/network/interfaces for $NETWORK_INTERFACE..."

    # Формируем конфигурацию интерфейса
    {
        log "auto $NETWORK_INTERFACE"
        if [[ "$NETWORK_USE_DHCP" == "yes" ]]; then
            log "iface $NETWORK_INTERFACE inet dhcp"
        else
            log "iface $NETWORK_INTERFACE inet static"
            log "    address $NETWORK_IP"
            log "    netmask $NETWORK_MASK"
            log "    gateway $NETWORK_GATEWAY"
            log "    dns-nameservers $NETWORK_DNS"
        fi
    } > "$target_config"

    # Применяем конфигурацию (без использования systemctl)
    log "Restarting networking interface $NETWORK_INTERFACE..."

    # Если это DHCP, просто активируем интерфейс
    if [[ "$NETWORK_USE_DHCP" == "yes" ]]; then
        chroot "$chroot_dir" /sbin/ifdown "$NETWORK_INTERFACE" && chroot "$chroot_dir" /sbin/ifup "$NETWORK_INTERFACE"
    else
        # Для статической конфигурации перезапускаем сетевой интерфейс
        chroot "$chroot_dir" /sbin/ifdown "$NETWORK_INTERFACE" && chroot "$chroot_dir" /sbin/ifup "$NETWORK_INTERFACE"
    fi

    # Проверяем статус сети
    if chroot "$chroot_dir" /sbin/ip a show "$NETWORK_INTERFACE" | grep -q "inet"; then
        log "Networking interface $NETWORK_INTERFACE is up"
    else
        log_error "Networking interface $NETWORK_INTERFACE failed to start"
        return 1
    fi
}

# Обновлённая функция установки загрузчика с учётом RAID-массива
run_bootloader() {
    log "Running Bootloader installation..."
    if [ -z "${GRUB_TARGET_DRIVES[*]}" ]; then
        log_error "GRUB target drives not configured. Exiting."
        exit 1
    fi
    for disk in "${GRUB_TARGET_DRIVES[@]}"; do
        if ! device_exists "$disk"; then
            log_error "Device $disk not found. Exiting."
            exit 1
        fi
        if is_uefi_system; then
            log "UEFI system detected. Installing GRUB with EFI support on $disk..."
            grub-install --target=x86_64-efi --efi-directory=/boot/efi --recheck "$disk"
        else
            log "BIOS system detected. Installing GRUB on $disk..."
            grub-install --target=i386-pc --recheck "$disk"
        fi
        if [ $? -ne 0 ]; then
            log_error "Error installing GRUB on $disk"
            exit 1
        fi
    done
    log "Updating GRUB configuration..."
    if ! update-grub; then
        log_error "update-grub failed"
        exit 1
    fi
    if ! validate_grub_config; then
        log_error "GRUB configuration invalid or missing"
        exit 1
    fi
    log "Bootloader installation complete."
}

run_initial_config() {
    log "[Running] Applying initial system configuration..."
    
    # Установка hostname
    log "$SYSTEM_HOSTNAME" > /etc/hostname
    log "Hostname set to $SYSTEM_HOSTNAME"
    
    # Создание нового пользователя с домашней директорией и bash в качестве оболочки
    if id "$SYSTEM_SUDO_USER" &>/dev/null; then
        log "User $SYSTEM_SUDO_USER already exists, skipping creation."
    else
        useradd -m -s /bin/bash "$SYSTEM_SUDO_USER"
        log "User $SYSTEM_SUDO_USER created."
    fi

    # Установка хешированного пароля для созданного пользователя
    log "$SYSTEM_SUDO_USER:$SYSTEM_USER_PASSWORD_HASH" | chpasswd -e
    log "Password for $SYSTEM_SUDO_USER set (using hash)."

    # Добавление пользователя в группу sudo
    usermod -aG sudo "$SYSTEM_SUDO_USER"
    log "User $SYSTEM_SUDO_USER added to sudo group."

    # Отключение возможности входа по SSH через учетную запись root
    if grep -q "^PermitRootLogin yes" /etc/ssh/sshd_config; then
        sed -i 's/^PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config
        log "Root login via SSH has been disabled."
    else
        log "PermitRootLogin already disabled or not set."
    fi

    # Перезапуск сервиса SSH для применения изменений
    systemctl restart sshd
    log "SSH service restarted."
}
run_cleanup() {
    log "[Running] Final cleanup: unmounting file systems, cleaning temporary data and rebooting system."

    # Отмонтирование разделов, указанных в массиве MOUNT_POINTS
    for mount_point in "${MOUNT_POINTS[@]}"; do
        if mountpoint -q "$mount_point"; then
            log "Unmounting $mount_point..."
            run_cmd umount -l "$mount_point"
        else
            log "Mount point $mount_point is not mounted."
        fi
    done

    # Отмонтирование системных директорий, смонтированных в chroot
    chroot_dir="${MOUNT_POINTS[ROOT]}"
    if mountpoint -q "$chroot_dir/proc"; then
        log "Unmounting $chroot_dir/proc..."
        run_cmd umount -l "$chroot_dir/proc"
    fi
    if mountpoint -q "$chroot_dir/sys"; then
        log "Unmounting $chroot_dir/sys..."
        run_cmd umount -l "$chroot_dir/sys"
    fi
    if mountpoint -q "$chroot_dir/dev"; then
        log "Unmounting $chroot_dir/dev..."
        run_cmd umount -l "$chroot_dir/dev"
    fi

    # Очистка временных данных (при необходимости)
    # Например, можно удалить временные файлы, созданные во время установки.
    # Здесь можно добавить вызовы rm -rf для удаления временных каталогов,
    # если они не нужны после установки.

    log "Cleanup completed. System will reboot in 10 seconds..."
    sleep 10
    run_cmd reboot
}
################################################################################################################################################
### Summary and Confirmation ###
summary_and_confirm() {
    log ""
    log "🚀 Configuration Summary:"
    log "----------------------------------------"
    log "Primary disk:          $PART_DRIVE1"
    log "Secondary disk:        $PART_DRIVE2"
    log "Use RAID:              $PART_USE_RAID (Level: $PART_RAID_LEVEL)"
    log "Boot size/filesystem:  $PART_BOOT_SIZE / $PART_BOOT_FS"
    log "Swap size:             $PART_SWAP_SIZE"
    log "Root filesystem:       $PART_ROOT_FS"
    log "Debian release/mirror: $DEBIAN_RELEASE / $DEBIAN_MIRROR"
    log "Use DHCP:              $NETWORK_USE_DHCP"
    log "GRUB targets:          ${GRUB_TARGET_DRIVES[*]}"
    log "Hostname:              $HOSTNAME"
    log "----------------------------------------"
    read -rp "Start installation with these settings? (yes/no)[no]: " CONFIRM
    CONFIRM=${CONFIRM:-no}
    if [ "$CONFIRM" == "yes" ]; then
        read -rp "Do you want to save the configuration? (yes/no) [yes]: " SAVE_CONFIG
        SAVE_CONFIG=${SAVE_CONFIG:-yes}
        if [ "$SAVE_CONFIG" == "yes" ]; then
            save_configuration
        fi
    elif [ "$CONFIRM" == "no" ];then
        clear
        read -rp "Restart configuration? (yes/no) [yes]: " RESTART_CONFIGURATION
        RESTART_CONFIGURATION="${RESTART_CONFIGURATION,,}"  # lower case
        RESTART_CONFIGURATION="${RESTART_CONFIGURATION:-yes}"
        if [ "$RESTART_CONFIGURATION" == "yes" ];then 
            configuring
        else
            log "Installation aborted by user."
            exit 1
        fi
    else
        log "Installation aborted by user."
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
        "NETWORK_INTERFACE=${NETWORK_INTERFACE}"
        "NETWORK_IP=${NETWORK_IP}"
        "NETWORK_MASK=${NETWORK_MASK}"
        "NETWORK_GATEWAY=${NETWORK_GATEWAY}"
        "NETWORK_DNS=${NETWORK_DNS}"
        ""
        "# Bootloader"
        "GRUB_TARGET_DRIVES=${GRUB_TARGET_DRIVES[*]}"
        ""
        "# System settings"
        "HOSTNAME=${HOSTNAME}"
    )
    printf "%s\n" "${CONFIG_LINES[@]}" > "$CONFIG_FILE"
    log "Configuration saved to $CONFIG_FILE"
    log ""
}

################################################################################################################################################
### Entrypoints ###
configuring() {
    configure_partitioning
    configure_debian_install
    configure_network
    configure_bootloader
    configure_initial_config
    configure_cleanup
}

running() {
    run_partitioning
    run_debian_install
    run_network
    run_bootloader
    run_initial_config
    run_cleanup
}

# Load config file if exists
if [ -f "$CONFIG_FILE" ]; then
    log "Loading configuration from $CONFIG_FILE"
    source "$CONFIG_FILE"
    summary_and_confirm
    running
else
    log "No configuration file found, proceeding interactively."
fi

main() {
    configuring
    summary_and_confirm
    running
}

main

log "✅ Скрипт завершён. Нажми Enter для выхода..."
read