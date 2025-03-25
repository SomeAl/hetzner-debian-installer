#!/bin/bash
#exec 3>&1 4>&2  
#exec > >(tee hetzner-debian-installer.log) 2>&1  
#set -xe  

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

    echo "Saving configuration to $CONFIG_FILE..."
    cat > "$CONFIG_FILE" <<EOF
PART_DRIVE1="$PART_DRIVE1"
PART_DRIVE2="$PART_DRIVE2"
PART_USE_RAID="$PART_USE_RAID"
PART_RAID_LEVEL="$PART_RAID_LEVEL"
PART_BOOT_SIZE="$PART_BOOT_SIZE"
PART_SWAP_SIZE="$PART_SWAP_SIZE"
PART_ROOT_FS="$PART_ROOT_FS"
PART_BOOT_FS="$PART_BOOT_FS"
EOF
    echo "Configuration saved successfully."
}

configure_debian_install() {
    echo "[Configuring] Debian installation parameters..."

    # Prompt for Debian version; default is "stable"
    read -rp "Select Debian version (stable, testing, sid) [stable]: " DEBIAN_RELEASE
    DEBIAN_RELEASE="${DEBIAN_RELEASE:-stable}"
    case "$DEBIAN_RELEASE" in
        stable|testing|sid)
            ;;  
        *)
            echo "Invalid Debian version input, defaulting to 'stable'."
            DEBIAN_RELEASE="stable"
            ;;
    esac

    # Prompt for Debian repository mirror; default is http://ftp.de.debian.org/debian/
    read -rp "Enter Debian repository mirror [http://ftp.de.debian.org/debian/]: " DEBIAN_MIRROR
    DEBIAN_MIRROR="${DEBIAN_MIRROR:-http://ftp.de.debian.org/debian/}"
    # Validate mirror availability with a simple HTTP HEAD request
    if ! curl -Is "$DEBIAN_MIRROR" --max-time 5 | head -n 1 | grep -q "200"; then
        echo "Error: Debian mirror '$DEBIAN_MIRROR' is not reachable. Exiting."
        exit 1
    fi

    read -rp "Enter installation target mount point for boot [/mnt/md0p1]: " INSTALL_TARGET
    INSTALL_TARGET_BOOT="${INSTALL_TARGET_BOOT:-/mnt/md0p1}"
    
    read -rp "Enter installation target mount point for swap [/mnt/md0p2]: " INSTALL_TARGET
    INSTALL_TARGET_SWAP="${INSTALL_TARGET_SWAP:-/mnt/md0p1}"
    
    read -rp "Enter installation target mount point for / [/mnt/md0p3]: " INSTALL_TARGET
    INSTALL_TARGET_ROOT="${INSTALL_TARGET_ROOT:-/mnt/md0p1}"

    # Confirm that the target disk is unmounted in the run_debian_install function later.
    # Save parameters to configuration file.
    echo "Saving Debian installation parameters to $CONFIG_FILE..."
    cat >> "$CONFIG_FILE" <<EOF
DEBIAN_RELEASE="$DEBIAN_RELEASE"
DEBIAN_MIRROR="$DEBIAN_MIRROR"
INSTALL_TARGET_BOOT="$INSTALL_TARGET_BOOT"
INSTALL_TARGET_SWAP="$INSTALL_TARGET_SWAP"
INSTALL_TARGET_ROOT="$INSTALL_TARGET_ROOT"
EOF
    echo "Debian installation configuration saved successfully."
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

    # Ensure the installation target exists; create if necessary.
    if [ ! -d "$INSTALL_TARGET" ]; then
        echo "Target mount point $INSTALL_TARGET does not exist. Creating it..."
        mkdir -p "$INSTALL_TARGET"
    fi

    # Check if the target is already mounted.
    if mountpoint -q "$INSTALL_TARGET"; then
        echo "Warning: $INSTALL_TARGET is already mounted."
    else
        echo "Mounting target partition(s) to $INSTALL_TARGET..."
        # Mount the root partition; adjust partition identifier if necessary.
        mount "${PART_DRIVE1}p3" "$INSTALL_TARGET" || {
            echo "Error: Failed to mount root partition on $INSTALL_TARGET. Exiting."
            exit 1
        }
        # Optionally, mount /boot if separate; uncomment if applicable.
        # mkdir -p "$INSTALL_TARGET/boot"
        # mount "${PART_DRIVE1}p1" "$INSTALL_TARGET/boot" || {
        #     echo "Error: Failed to mount /boot partition. Exiting."
        #     exit 1
        # }
    fi

    # Run debootstrap to install the Debian base system.
    echo "Starting debootstrap for Debian $DEBIAN_RELEASE using mirror $DEBIAN_MIRROR..."
    debootstrap --arch=amd64 "$DEBIAN_RELEASE" "$INSTALL_TARGET" "$DEBIAN_MIRROR"
    if [ $? -ne 0 ]; then
        echo "Error: debootstrap failed. Exiting."
        exit 1
    fi

    echo "Debian base system installed successfully in $INSTALL_TARGET."
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
    read -rp "Start installation with these settings? (yes/no): " CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        echo "Installation aborted by user."
        exit 1
    fi
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
