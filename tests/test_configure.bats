#!/usr/bin/env bats

# Подавление вывода ядра
exec 3>/dev/null
exec 4>/dev/null

# Глобальные переменные для тестов
TEST_DISK="/dev/testdisk"
TEST_RAID_DISK="/dev/md0"
TEST_MOUNT_POINT="/tmp/test_mount"

setup() {
  load ../hetzner-debian-installer.bash

  # Мокаем системные вызовы
  stub lsblk "echo '$TEST_DISK'"
  stub parted "echo 'Mocked parted'"
  stub mdadm "echo 'Mocked mdadm'"
  stub mkfs "echo 'Mocked mkfs'"
  stub debootstrap "echo 'Mocked debootstrap'"
  stub mount "echo 'Mocked mount'"
  stub umount "echo 'Mocked umount'"
  stub systemctl "echo 'Mocked systemctl'"
  stub wget "echo 'Mocked wget'"
  stub dhclient "echo 'Mocked dhclient'"
  stub ip "echo 'Mocked ip'"
  stub findmnt "echo 'Mocked findmnt'"
  
  # Создаем временные файлы/директории
  mkdir -p "$TEST_MOUNT_POINT"
}

teardown() {
  # Удаляем стабы
  unstub lsblk
  unstub parted
  unstub mdadm
  unstub mkfs
  unstub debootstrap
  unstub mount
  unstub umount
  unstub systemctl
  unstub wget
  unstub dhclient
  unstub ip
  unstub findmnt
  
  # Чистим временные файлы
  rm -rf "$TEST_MOUNT_POINT"
}

@test "configure_partitioning: проверка отказа при отсутствии дисков" {
  stub lsblk "echo ''"
  run configure_partitioning
  assert_output --partial "No disks found. Exiting..."
  assert_failure
}

@test "configure_partitioning: проверка RAID конфигурации с неверным уровнем" {
  stub find_disks "echo '$TEST_DISK /dev/sdb'"
  run configure_partitioning <<< $'\n\nyes\ninvalid\n512M\n32G\next4\next3'
  assert_output --partial "Invalid RAID level. Defaulting to 1"
}

@test "configure_debian_install: проверка монтирования занятой точки" {
  stub findmnt "echo 'Mounted'"
  run configure_debian_install <<< $'\n\n\n\n\n/tmp'
  assert_output --partial "Error: Installation cannot proceed with mounted target"
}

@test "configure_network: проверка статического IP с недоступным шлюзом" {
  stub ping "exit 1"
  run configure_network <<< $'eth0\nno\n192.168.1.100\n255.255.255.0\n192.168.1.1\n'
  assert_output --partial "Warning: Gateway 192.168.1.1 is not responding"
}

@test "run_partitioning: проверка форматирования с неверной ФС" {
  stub mkfs.ext4 "exit 1"
  run run_partitioning
  assert_output --partial "Error: Failed to format"
}

@test "run_debian_install: проверка установки без прав root" {
  stub id "-u : echo 1000"
  run run_debian_install
  assert_output --partial "must be run as root"
}

@test "configure_network: проверка конфликта IP через arping" {
  stub arping "exit 0"
  run configure_network <<< $'eth0\nno\n192.168.1.100\n255.255.255.0\n192.168.1.1\n'
  assert_output --partial "IP address 192.168.1.100 is already in use"
}

@test "configure_partitioning: проверка размера раздела больше диска" {
  stub lsblk "-dnbo SIZE : echo 1073741824" # 1GB
  run configure_partitioning <<< $'\n\nyes\n1\n2G\n32G\next4\next3'
  assert_output --partial "Invalid boot partition size"
}

@test "run_network: проверка перезапуска сети с ошибкой" {
  stub systemctl "exit 1"
  run run_network
  assert_output --partial "Error: Failed to restart network"
}

@test "configure_debian_install: проверка сохранения конфигурации" {
  run save_configuration
  assert_file_exists "hetzner-debian-installer.conf"
  assert_file_contains "hetzner-debian-installer.conf" "PART_DRIVE1="
}

@test "run_partitioning: проверка создания RAID0" {
  stub find_disks "echo '$TEST_DISK /dev/sdb'"
  run run_partitioning <<< $'\n\nyes\n0\n512M\n32G\next4\next3'
  assert_output --partial "Creating RAID0 array"
}

@test "configure_cleanup: проверка удаления временных файлов" {
  touch testfile.tmp
  run configure_cleanup
  refute_file_exists "testfile.tmp"
}

@test "run_bootloader: проверка установки GRUB на несуществующий диск" {
  stub grub-install "exit 1"
  run run_bootloader
  assert_output --partial "GRUB installation failed"
}

@test "configure_initial_config: проверка пустого hostname" {
  run configure_initial_config <<< $'\n'
  assert_output --partial "Hostname is required"
}

@test "run_debian_install: проверка установки с поврежденным зеркалом" {
  stub wget "exit 1"
  run run_debian_install
  assert_output --partial "mirror is not reachable"
}

@test "configure_partitioning: проверка ввода диска с пробелами в имени" {
  run configure_partitioning <<< $'/dev/sd a\n'
  assert_output --partial "not a valid block device"
}

@test "run_network: проверка настройки IPv6" {
  run configure_network <<< $'eth0\nno\n2001:db8::1\n64\n2001:db8::ff\n'
  assert_output --partial "Static IPv6 configuration applied"
}

@test "configure_partitioning: проверка автоматического исправления GPT таблицы" {
  stub parted "echo 'Error: GPT table error'"
  run configure_partitioning
  assert_output --partial "Attempting to repair GPT table"
}

@test "run_cleanup: проверка отката изменений при прерывании" {
  stub trap "echo 'Rollback triggered'"
  run run_cleanup <<< $'\x03' # Ctrl+C
  assert_output --partial "Rollback completed"
}