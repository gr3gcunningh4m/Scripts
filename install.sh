#!/usr/bin/env bash
set -euo pipefail

DISK="/dev/nvme0n1"
HOSTNAME="archlinux"
USERNAME="greg"
TIMEZONE="America/Los_Angeles"
LOCALE="en_US.UTF-8"

# Sync system clock
timedatectl set-ntp true

# Partition disk
sgdisk --zap-all "$DISK"
sgdisk --new=1:0:+1G --typecode=1:ef00 --change-name=1:"EFI" "$DISK"
sgdisk --new=2:0:0   --typecode=2:8300 --change-name=2:"ROOT" "$DISK"

EFI_PART="${DISK}p1"
ROOT_PART="${DISK}p2"

# Encrypt root partition
cryptsetup luksFormat --type luks2 "$ROOT_PART"
cryptsetup open "$ROOT_PART" root

# Format the partitions 
mkfs.fat -F32 "$EFI_PART"
mkfs.ext4 /dev/mapper/root

# Mount file systems
mount /dev/mapper/root /mnt
mount --mkdir "$EFI_PART" /mnt/boot

# Create swapfile
dd if=/dev/zero of=/mnt/swapfile bs=1M count="$(free --mebi | awk '/^Mem:/{print $2}')" status=progress
chmod 600 /mnt/swapfile
mkswap /mnt/swapfile
swapon /mnt/swapfile

# Install system
pacstrap -K /mnt base base-devel linux linux-firmware intel-ucode mesa vulkan-intel pipewire pipewire-pulse wireplumber bluez bluez-utils efibootmgr cryptsetup networkmanager neovim git nftables throttled fwupd reflector

# Generate fstab
genfstab -U /mnt >> /mnt/etc/fstab

# Chroot into linux installation
arch-chroot /mnt /bin/bash << EOF
set -e

pacman -S --no-confirm ghostty feh ttf-liberation xorg-server xorg-xinit xorg-xrandr

# Set locales
ln -sf /usr/share/zoneinfo/"$TIMEZONE" /etc/localtime
hwclock --systohc
echo "$LOCALE UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=$LOCALE" > /etc/locale.conf

# Set hostname
echo "$HOSTNAME" > /etc/hostname
cat <<EOB > /etc/hosts
127.0.0.1     localhost
::1           localhost
127.0.1.1     "$HOSTNAME".localdomain        "$HOSTNAME"
EOB 

# Configure initramfs
sed -i 's/^HOOKS=(base udev autodetect modconf kms keyboard keymap consolefont block filesystems fsck)/HOOKS=(base udev autodetect modconf kms keyboard keymap consolefont block encrypt filesystems resume fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

# Create boot entry
efibootmgr --disk "$DISK" --part 1 --create --label "Arch Linux" --loader /vmlinuz-linux --unicode 'cryptdevice=UUID=$(blkid -s UUID -o value "$ROOT_PART"):root root=/dev/mapper/root resume_offset=$(filefrag -v /swapfile | awk '$1=="0:" {print $4}' | tr -d '.') rw initrd=\intel-ucode.img initrd=\initramfs-linux.img' --verbose

# Reflector configuration
cat > /etc/xdg/reflector/reflector.conf << EOS
--save /etc/pacman.d/mirrorlist
--protocol https
--country "United States"
--sort rate
--latest 20
--age 12
EOS

# Add user
echo "%wheel ALL=(ALL:ALL) ALL" >> /etc/sudoers.d/wheel
useradd -m -G wheel "$USERNAME"
passwd "$USERNAME"

# Lock root
passwd --lock root

# Enable services
systemctl enable NetworkManager
systemctl enable bluetooth
systemctl enable systemd-timesyncd
systemctl enable nftables
systemctl enable throttled
systemctl enable auto-cpufreq
#systemctl enable fwupd
systemctl enable fstrim
systemctl enable reflector

# Reduce swappiness
echo 'vm.swappiness=10' | sudo tee /etc/sysctl.d/99-swappiness.conf

EOF

umount -R /mnt
echo ""
echo "Installation complete!"
