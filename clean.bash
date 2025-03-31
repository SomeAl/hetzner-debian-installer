mdadm --stop /dev/md*
wipefs -a /dev/nvme{0,1}n1
mdadm --detail --scan >> /etc/mdadm/mdadm.conf