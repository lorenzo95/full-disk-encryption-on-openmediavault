#!/bin/bash
set -e

################ Configuration ################

MAPPER_NAME=tardis

################ No changes below this line ################

echo "=== Detecting OS disk ==="
for disk in $(lsblk -nd -o NAME,TYPE | awk '$2=="disk"{print $1}'); do
    if lsblk -no PARTTYPE /dev/$disk 2>/dev/null | grep -q "c12a7328-f81f-11d2-ba4b-00a0c93ec93b"; then
        if [ "$(lsblk -no RM /dev/$disk | head -1 | tr -d ' ')" = "0" ]; then
            OSDISK=/dev/$disk
        fi
    fi
done

if [ -z "$OSDISK" ]; then
    echo "Error: Could not detect OS disk. Aborting."
    exit 1
fi

# Handle nvme partition naming (nvme0n1p1 vs sda1)
if echo "$OSDISK" | grep -q "nvme"; then
    PART="${OSDISK}p"
else
    PART="${OSDISK}"
fi

echo "Detected OS disk: $OSDISK (partitions: ${PART}1, ${PART}2, ...)"

echo "=== Detecting swap size ==="
SWAP_BYTES=$(lsblk -bno SIZE ${PART}3 2>/dev/null || echo 0)
SWAP_GB=$(awk "BEGIN {printf \"%.0f\", ${SWAP_BYTES}/1024/1024/1024}")
if [ -z "$SWAP_GB" ] || [ "$SWAP_GB" -eq 0 ]; then
    SWAP_GB=2
fi
echo "Swap size: ${SWAP_GB}GB"

echo "=== Detecting disk info ==="
DISK_SIZE=$(lsblk -nd -o SIZE ${OSDISK})
ROOT_SIZE=$(lsblk -nd -o SIZE ${PART}2)
RAM_SIZE=$(free -h | awk '/^Mem:/{print $2}')

echo
echo "=================================================="
echo "  OMV Full Disk Encryption - Pre-flight Summary"
echo "=================================================="
echo
echo "  OS disk:         ${OSDISK} (${DISK_SIZE})"
echo "  Current root:    ${PART}2 (${ROOT_SIZE})"
echo "  LUKS mapper:     /dev/mapper/${MAPPER_NAME}"
echo
echo "  New partition layout:"
echo "    ${PART}1  EFI        (existing, untouched)"
echo "    ${PART}2  /boot      1G unencrypted"
echo "    ${PART}3  /          rest of disk, LUKS encrypted"
echo "    ${PART}4  swap       ${SWAP_GB}G encrypted with random key"
echo
echo "  System RAM:      ${RAM_SIZE}"
echo
echo "=================================================="
echo
echo "  WARNING: This will DESTROY all data on ${OSDISK}."
echo "  The root filesystem will be backed up to RAM"
echo "  and restored to the new encrypted partition."
echo "  Make sure you have enough free RAM for the backup."
echo
echo "  Current root usage:"
mount ${PART}2 /mnt 2>/dev/null && df -h /mnt | tail -1 | awk '{print "    Used: "$3" / "$2" ("$5" full)"}' && umount /mnt
echo
echo "  Available RAM:"
free -h | awk '/^Mem:/{print "    Free: "$4" / "$2}'
echo
echo "=================================================="
echo
read -p "  Type YES to continue or anything else to abort: " CONFIRM
echo

if [ "$CONFIRM" != "YES" ]; then
    echo "Aborted."
    exit 1
fi

echo "=== Installing dependencies ==="
apt update && apt install -y gdisk

echo "=== Backing up root filesystem to RAM ==="
mkdir -p /oldroot
mount ${PART}2 /mnt
rsync -a /mnt/ /oldroot/
umount /mnt

echo "=== Repartitioning ==="
sgdisk ${OSDISK} \
  --delete=2 \
  --delete=3 \
  --new=2:0:+1G --typecode=2:8300 --change-name=2:boot \
  --new=3:0:-${SWAP_GB}G --typecode=3:8309 --change-name=3:luks \
  --new=4:0:0   --typecode=4:8200 --change-name=4:swap \
  --print

echo "=== Formatting /boot ==="
mkfs.ext4 -F ${PART}2

echo "=== Setting up LUKS on ${PART}3 ==="
cryptsetup --cipher aes-xts-plain64 -s 512 -h sha256 --iter-time 2000 luksFormat ${PART}3

echo "=== Opening LUKS container ==="
cryptsetup luksOpen ${PART}3 ${MAPPER_NAME}

echo "=== Formatting root ==="
mkfs.ext4 /dev/mapper/${MAPPER_NAME}

echo "=== Mounting new filesystem ==="
mkdir -p /newroot
mount /dev/mapper/${MAPPER_NAME} /newroot
mkdir -p /newroot/boot
mount ${PART}2 /newroot/boot
mkdir -p /newroot/boot/efi
mount ${PART}1 /newroot/boot/efi

echo "=== Restoring filesystem ==="
rsync -a /oldroot/ /newroot/

echo "=== Collecting UUIDs ==="
EFI_UUID=$(blkid -s UUID -o value ${PART}1)
BOOT_UUID=$(blkid -s UUID -o value ${PART}2)
LUKS_UUID=$(blkid -s UUID -o value ${PART}3)
SWAP_PARTUUID=$(blkid -s PARTUUID -o value ${PART}4)

echo "EFI:           $EFI_UUID"
echo "BOOT:          $BOOT_UUID"
echo "LUKS:          $LUKS_UUID"
echo "SWAP PARTUUID: $SWAP_PARTUUID"

if [ -z "$LUKS_UUID" ] || [ -z "$BOOT_UUID" ] || [ -z "$SWAP_PARTUUID" ]; then
    echo "Error: One or more UUIDs missing. Aborting."
    exit 1
fi

echo "=== Writing fstab ==="
cat > /newroot/etc/fstab << EOF
# <file system> <mount point> <type> <options> <dump> <pass>
/dev/mapper/${MAPPER_NAME} /              ext4   errors=remount-ro 0 1
UUID=${BOOT_UUID} /boot                   ext4   defaults          0 2
UUID=${EFI_UUID}  /boot/efi               vfat   umask=0077        0 1
/dev/mapper/swap  none                    swap   sw                0 0
/dev/sr0          /media/cdrom0           udf,iso9660 user,noauto  0 0
EOF

echo "=== Writing crypttab ==="
cat > /newroot/etc/crypttab << EOF
${MAPPER_NAME} UUID=${LUKS_UUID} none luks
swap PARTUUID=${SWAP_PARTUUID} /dev/urandom swap,plain,cipher=aes-xts-plain64,size=256
EOF

echo "=== Configuring chroot ==="
rm -f /newroot/etc/resolv.conf
echo "nameserver 9.9.9.9" > /newroot/etc/resolv.conf

echo "=== Chrooting and updating boot ==="
mount --bind /dev /newroot/dev
mount -t devpts devpts /newroot/dev/pts
mount --bind /sys /newroot/sys
mount --bind /proc /newroot/proc
mount --bind /sys/firmware/efi/efivars /newroot/sys/firmware/efi/efivars

chroot /newroot /bin/bash -e << 'CHROOT'
rm -f /etc/initramfs-tools/conf.d/resume
apt install -y cryptsetup-initramfs
rm -f /etc/initramfs-tools/conf.d/resume
echo 'GRUB_DISABLE_LINUX_UUID=true' >> /etc/default/grub
update-initramfs -u -k all
update-grub
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=debian --recheck
CHROOT

echo "=== Restoring resolv.conf ==="
rm -f /newroot/etc/resolv.conf
ln -s /run/systemd/resolve/stub-resolv.conf /newroot/etc/resolv.conf

echo "=== Cleaning up ==="
umount /newroot/sys/firmware/efi/efivars
umount /newroot/dev/pts
umount /newroot/dev
umount /newroot/sys
umount /newroot/proc
umount /newroot/boot/efi
umount /newroot/boot
umount /newroot
cryptsetup luksClose ${MAPPER_NAME}

echo "=== Done. Remove live USB and reboot ==="
