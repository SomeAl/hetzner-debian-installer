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

