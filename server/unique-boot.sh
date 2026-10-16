#!/bin/bash
# Make the receiver's own disk unambiguous for booting.
#
# Job volumes attached to the receiver are byte copies of source disks. When a source was made
# from the same cloud image as the receiver, its filesystems carry the same UUIDs and labels
# (cloudimg-rootfs, BOOT, UEFI). On the next reboot GRUB (search --fs-uuid for /boot), the
# initramfs (root=UUID=...) and fstab (LABEL=...) may then pick the job volume and the receiver
# boots the copy of a source VM (seen on VK Cloud: root on /dev/vdc1 after a flavor resize).
# This script gives the receiver's root, /boot and EFI filesystems new UUIDs and labels, writes
# fstab by UUID and reinstalls GRUB and the initramfs. Idempotent. Ubuntu 22.04+/Debian 12+.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
log() { echo "unique-boot: $*"; }
ROOT=$(findmnt -no SOURCE /)
[ "$(blkid -s LABEL -o value "$ROOT")" = d2g-root ] && { log "already done"; exit 0; }
[ "$(findmnt -no FSTYPE /)" = ext4 ] || { log "root is not ext4 — skipped, keep job volumes detached when rebooting"; exit 0; }
DISK=/dev/$(lsblk -no PKNAME "$ROOT" | head -1)
BOOT=$(findmnt -no SOURCE /boot || true)
EFI=$(findmnt -no SOURCE /boot/efi || true)
declare -A OLD
for d in $ROOT $BOOT $EFI; do OLD[$d]=$(blkid -s UUID -o value "$d"); done

# root: online (kernel 6.x + e2fsprogs 1.47 change the UUID of a mounted ext4 with csum_seed)
tune2fs -O metadata_csum_seed "$ROOT" >/dev/null
tune2fs -U random "$ROOT" >/dev/null
e2label "$ROOT" d2g-root
# /boot and EFI: unmounted for the change
[ -n "$EFI" ] && umount /boot/efi
if [ -n "$BOOT" ]; then
  umount /boot
  tune2fs -O metadata_csum_seed "$BOOT" >/dev/null 2>&1 || true
  tune2fs -U random "$BOOT" >/dev/null
  e2label "$BOOT" d2g-boot
fi
if [ -n "$EFI" ]; then
  fatlabel "$EFI" D2GEFI >/dev/null
  fatlabel -i "$EFI" "$(od -An -N4 -tx4 /dev/urandom | tr -d ' \n')" >/dev/null
fi

# fstab by UUID for /, /boot, /boot/efi
cp -a /etc/fstab /etc/fstab.d2g-orig
awk -v r="$(blkid -s UUID -o value "$ROOT")" -v b="${BOOT:+$(blkid -s UUID -o value "$BOOT")}" \
    -v e="${EFI:+$(blkid -s UUID -o value "$EFI")}" '
  $1 !~ /^#/ && $2 == "/"         { $1 = "UUID=" r }
  $1 !~ /^#/ && $2 == "/boot"     && b != "" { $1 = "UUID=" b }
  $1 !~ /^#/ && $2 == "/boot/efi" && e != "" { $1 = "UUID=" e }
  { print }' /etc/fstab.d2g-orig >/etc/fstab
systemctl daemon-reload
[ -n "$BOOT" ] && mount /boot
[ -n "$EFI" ] && mount /boot/efi

# the EFI stub config searches /boot by UUID too
if [ -f /boot/efi/EFI/ubuntu/grub.cfg ] && [ -n "$BOOT" ]; then
  sed -i "s/${OLD[$BOOT]}/$(blkid -s UUID -o value "$BOOT")/g" /boot/efi/EFI/ubuntu/grub.cfg
fi
update-grub >/dev/null 2>&1
# BIOS core.img embeds the /boot UUID it searches for
[ -d /boot/grub/i386-pc ] && grub-install --target=i386-pc "$DISK" >/dev/null 2>&1
[ -d /sys/firmware/efi ] && grub-install --target=x86_64-efi --no-nvram >/dev/null 2>&1 || true
update-initramfs -u >/dev/null 2>&1
grep -q "root=UUID=$(blkid -s UUID -o value "$ROOT")" /boot/grub/grub.cfg || { log "ERROR: grub.cfg does not use the new root UUID"; exit 1; }
log "root $ROOT, boot ${BOOT:-none}, efi ${EFI:-none}: new UUIDs and labels, fstab by UUID, GRUB and initramfs updated"
