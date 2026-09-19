#!/usr/bin/env bash
set -e

# -- Configuration --
DISK="/dev/nvme0n1"
HOSTNAME="archlinux"
USERNAME="greg"
TIMEZONE="America/Los_Angeles"
LOCALE="en_US.UTF-8"

timedatectl set-ntp true

# Partition
sgdisk --zap-all "$DISK"
sgdisk --new=1:0:+1G --typecode=1:ef00 --change-name=1:"EFI" "$DISK"
sgdisk --new=2:0:0   --typecode=2:8300 --change-name=2:"ROOT" "$DISK"

EFI_PART="${DISK}p1"
ROOT_PART="${DISK}p2"

# Encrypt Root Partition
cryptsetup luksFormat "$ROOT_PART"
cryptsetup open "$ROOT_PART" root

# Format the partitions 
mkfs.fat -F32 "$EFI_PART"
mkfs.ext4 /dev/mapper/root

# Mount File Systems
mount /dev/mapper/cryptroot /mnt
mount --mkdir "$EFI_PART" /mnt/boot

# Create Swap File
dd if=/dev/zero of=/swapfile bs=1M count="$(free --mebi | awk '/^Mem:/{print $2}')" status=progress
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile

# Install Arch Linux
pacstrap -K /mnt base base-devel linux linux-firmware neovim

# Generate File System Table
genfstab -U /mnt >> /mnt/etc/fstab

# Switch to Your New Linux Installation
arch-chroot /mnt /bin/bash << EOF
set -e

pacman -S --no-confirm networkmanager efibootmgr intel-ucode intel-media-driver libva-intel-driver libva-mesa-driver mesa vulkan-intel vulkan-nouveau xf86-video-nouveau pipewire pipewire-pulse wireplumber bluez bluez-utils nftables reflector thermald auto-cpufreq xorg-server xorg-xinit

# Set Locales
ln -sf /usr/share/zoneinfo/"$TIMEZONE" /etc/localtime
hwclock --systohc
echo "$LOCALE UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=$LOCALE" > /etc/locale.conf

# Set Hostname
echo "$HOSTNAME" > /etc/hostname
cat <<EOB > /etc/hosts
127.0.0.1     localhost
::1           localhost
127.0.1.1     "$HOSTNAME".localdomain        "$HOSTNAME"
EOB 

# Configure Initramfs
sed -i 's/^HOOKS=(base udev autodetect modconf kms keyboard keymap consolefont block filesystems fsck)/HOOKS=(base udev autodetect modconf kms keyboard keymap consolefont block encrypt filesystems resume fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

# Create Boot Entry
efibootmgr --disk "$DISK" --part 1 --create --label "Arch Linux" --loader /vmlinuz-linux --unicode 'cryptdevice=UUID=$(blkid -s UUID -o value "$ROOT_PART"):root root=/dev/mapper/root resume_offset=$(filefrag -v /swapfile | awk '$1=="0:" {print $4}' | tr -d '.') rw initrd=\intel-ucode.img initrd=\initramfs-linux.img' --verbose

# Reflector Configuration
cat > /etc/xdg/reflector/reflector.conf << EOS
--save /etc/pacman.d/mirrorlist
--protocol https
--country "United States"
--sort rate
--latest 20
--age 12
EOS

# Add User
echo "%wheel ALL=(ALL:ALL) ALL" >> /etc/sudoers.d/wheel
useradd -m -G wheel "$USERNAME"
passwd "$USERNAME"
passwd --lock root

# Enable Services
systemctl enable NetworkManager
systemctl enable bluetooth.service
systemctl enable systemd-timesyncd.service
systemctl enable nftables.service
systemctl enable thermald.service
systemctl enable auto-cpufreq.service
systemctl enable fstrim.timer
systemctl enable reflector.timer

# Reduce Swappiness
echo 'vm.swappiness=10' | sudo tee /etc/sysctl.d/99-swappiness.conf

EOF

umount -R /mnt
echo "\nInstallation complete!"
