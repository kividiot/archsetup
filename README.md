# Arch gaming desktop

Runbook and post-install script for a gaming desktop on vanilla Arch Linux.

- **Hardware:** Ryzen 7 5700X3D, 32 GB DDR4 3200 CL14, Radeon RX 9070 XT, 250 GB and 2 TB NVMe, 4K 165 Hz OLED
- **Checked against the Arch repositories and the AUR on:** 2026-11-19
- **Status:** written from documentation, not yet run on the hardware. See [Checks and known gotchas](#checks-and-known-gotchas).

## What you are building

Vanilla Arch with the system on the 250 GB NVMe and home, games and Ollama models on the 2 TB NVMe. Both drives are encrypted with LUKS2 and run btrfs, and snapper snapshots of the system are bootable from the boot menu. Hyprland is the only desktop session, and gamescope wraps the games that need it.

| Area | Choice | Reason |
| --- | --- | --- |
| Install method | Manual commands, pasted over SSH into the live ISO | Every step is visible and repeatable |
| Drives | System on the 250 GB NVMe, home, games and Ollama models on the 2 TB NVMe | A reinstall of the system never touches the data drive, and all of the 2 TB goes to home and games |
| Partitions | 250 GB: 4 GiB EFI partition at `/boot`, rest is one LUKS2 container. 2 TB: one LUKS2 container | Kernels sit on the EFI partition, so each snapshot keeps its own bootable kernel copy |
| Unlock | One passphrase at boot. It opens the system drive, and a key file stored there opens the data drive | Nothing depends on TPM or Secure Boot state |
| Filesystem | btrfs with zstd compression on both drives. Subvolumes for root, snapshots, logs and package cache on the system drive, for home and Ollama models on the data drive | Root snapshots stay small and never roll back your home or game libraries |
| Snapshots | snapper + snap-pac + limine-snapper-sync | A snapshot before and after every pacman transaction, each one bootable |
| Bootloader | Limine | The only bootloader with maintained snapper boot-entry sync for an unencrypted `/boot` |
| Kernel | `linux`, with `linux-lts` installed as fallback | Newest amdgpu code for the 9070 XT, plus a second kernel when an update misbehaves |
| Desktop | Hyprland with a stock install of the ML4W dotfiles | A complete, maintained rice with its own installer and updater |
| Shell | zsh with oh-my-zsh and the powerlevel10k prompt | ML4W's own zsh config, with its oh-my-posh prompt swapped for powerlevel10k |
| Terminal | kitty | ML4W's default terminal. ML4W ships its config and colours it from the wallpaper |
| Local LLMs | Ollama with the ROCm backend | Runs models on the 9070 XT. Arch's ROCm 10.1 carries kernels for the card |
| CPU tuning | Curve Optimizer offset of -5 on all cores, through ryzen_smu | A mild undervolt, applied at boot and changed in one config file |
| Updates | paru for repos and AUR, arch-update for the tray notifier | One command, news shown before upgrading |

The base install is pasted from this runbook, block by block. Everything after first boot is in [`post-install.sh`](post-install.sh), which is safe to run again.

## Before you start

Do the install over SSH from the laptop, so every block in this runbook can be pasted instead of typed.

**Firmware settings on the desktop**

- UEFI boot only, CSM off.
- Secure Boot off. Limine is unsigned in this build and the passphrase unlock does not need it.
- XMP/DOCP on, so the RAM runs at 3200 CL14 instead of the 2133 default.
- Above 4G Decoding and Resizable BAR on. The 9070 XT loses performance without ReBAR.

**Cable**

Use DisplayPort for 4K at 165 Hz. HDMI 2.1 high-bandwidth support for amdgpu was only posted as patches in May 2026 ([GamingOnLinux](https://www.gamingonlinux.com/2026/05/further-expanded-amd-hdmi-2-1-support-is-coming-to-linux-now-with-frl-and-dsc/)). It is reported to stay off by default before Linux 7.4, and Arch ships 7.3.4 today.

**Install media (on the laptop)**

```bash
# Download the ISO and its .sig from https://archlinux.org/download/ then:
gpg --keyserver-options auto-key-retrieve --verify archlinux-*-x86_64.iso.sig
lsblk -d -o NAME,SIZE,MODEL,TRAN          # find the USB stick
sudo dd bs=4M if=archlinux-*-x86_64.iso of=/dev/sdX conv=fsync oflag=direct status=progress
```

**Boot the ISO on the desktop and open it up for SSH**

```bash
loadkeys sv-latin1
passwd
ip -brief addr
```

The passwd command sets a throwaway root password for the live session, and the last line shows the address to SSH to. Wired Ethernet gets an address by itself. For Wi-Fi run `iwctl station wlan0 connect <SSID>` first.

**Connect from the laptop**

```bash
ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@<desktop-ip>
```

The two options keep the ISO's throwaway host key out of your `known_hosts`.

**Sanity checks in that SSH session**

Start `bash` first. The ISO's default shell is zsh, which can choke on pasted `#` comments. Stay in this one bash session for Phase 1 and Phase 2, because the variables set along the way live in it.

```bash
bash
cat /sys/firmware/efi/fw_platform_size    # must print 64
timedatectl | grep synchronized           # must say yes
lsblk -d -o NAME,SIZE,MODEL               # both NVMe drives must show up
```

## Phase 1: Disks

This phase wipes both NVMe drives. The 250 GB drive gets the EFI partition and the encrypted system, the 2 TB drive gets an encrypted btrfs for home, games and Ollama models. Everything ends up mounted under `/mnt`. Check the two disk variables twice, because the wipe is not reversible.

**Pick the drives**

```bash
lsblk -d -o NAME,SIZE,MODEL,SERIAL
OS_DISK=/dev/nvme0n1       # the 250 GB drive
DATA_DISK=/dev/nvme1n1     # the 2 TB drive

# Must print OK.
[ "$(lsblk -dnbo SIZE "$OS_DISK")" -lt "$(lsblk -dnbo SIZE "$DATA_DISK")" ] && echo OK || echo "STOP: swap the two variables"

ESP=${OS_DISK}p1
ROOT=${OS_DISK}p2
DATA=${DATA_DISK}p1
```

The kernel can number the two drives the other way round on another boot, so set the variables from what `lsblk` shows now and do not continue unless the check prints `OK`. The installed system refers to both drives by UUID and does not depend on the numbering.

**Partition**

```bash
blkdiscard -f "$OS_DISK"
sgdisk --zap-all "$OS_DISK"
sgdisk -n1:0:+4G -t1:ef00 -c1:EFI       "$OS_DISK"
sgdisk -n2:0:0   -t2:8309 -c2:cryptroot "$OS_DISK"

blkdiscard -f "$DATA_DISK"
sgdisk --zap-all "$DATA_DISK"
sgdisk -n1:0:0   -t1:8309 -c1:cryptdata "$DATA_DISK"

partprobe "$OS_DISK" "$DATA_DISK"
lsblk "$OS_DISK" "$DATA_DISK"
```

The EFI partition is 4 GiB on purpose. limine-snapper-sync stores a kernel and initramfs copy per bootable snapshot there, and its documentation recommends at least that size.

**Encrypt**

```bash
cryptsetup luksFormat --type luks2 --label cryptroot "$ROOT"
cryptsetup luksFormat --type luks2 --label cryptdata "$DATA"
cryptsetup open --allow-discards --perf-no_read_workqueue --perf-no_write_workqueue --persistent "$ROOT" cryptroot
cryptsetup open --allow-discards --perf-no_read_workqueue --perf-no_write_workqueue --persistent "$DATA" cryptdata
```

Give both drives the same passphrase. At boot you type it once, for the system drive, and the data drive opens with a key file that Phase 2 creates. The passphrase on the data drive is there for opening it from a rescue system.

The `--persistent` flags are stored in the LUKS2 header. They enable TRIM through the encryption layer and skip the dm-crypt work queues, which is faster on NVMe. You type the passphrase over SSH here and on the desktop keyboard at boot. Both produce the same characters as long as the console keymap is set in Phase 2.

**Format and create subvolumes**

```bash
mkfs.fat -F32 -n EFI "$ESP"
mkfs.btrfs -L arch /dev/mapper/cryptroot
mkfs.btrfs -L data /dev/mapper/cryptdata

mount /dev/mapper/cryptroot /mnt
for sv in @ @snapshots @log @pkg; do btrfs subvolume create /mnt/$sv; done
umount /mnt

mount /dev/mapper/cryptdata /mnt
for sv in @home @ollama; do btrfs subvolume create /mnt/$sv; done
umount /mnt
```

| Subvolume | Drive | Mounted at | Rolled back with root |
| --- | --- | --- | --- |
| `@` | 250 GB | `/` | Yes |
| `@snapshots` | 250 GB | `/.snapshots` | No, it holds the root snapshots |
| `@log` | 250 GB | `/var/log` | No, so logs from a broken boot survive the rollback |
| `@pkg` | 250 GB | `/var/cache/pacman/pkg` | No, the package cache is disposable |
| `@home` | 2 TB | `/home` | No, it gets its own snapshot timeline |
| `@ollama` | 2 TB | `/var/lib/ollama` | No, downloaded models are large and can be pulled again |

The Steam library, `~/Games` and the XIVLauncher data become subvolumes inside `@home` in Phase 3, so the games sit on the 2 TB drive as well.

**Mount**

```bash
OPTS=noatime,compress=zstd:1
mount -o $OPTS,subvol=@ /dev/mapper/cryptroot /mnt
mount --mkdir -o $OPTS,subvol=@snapshots /dev/mapper/cryptroot /mnt/.snapshots
mount --mkdir -o $OPTS,subvol=@log       /dev/mapper/cryptroot /mnt/var/log
mount --mkdir -o $OPTS,subvol=@pkg       /dev/mapper/cryptroot /mnt/var/cache/pacman/pkg
mount --mkdir -o $OPTS,subvol=@home      /dev/mapper/cryptdata /mnt/home
mount --mkdir -o $OPTS,subvol=@ollama    /dev/mapper/cryptdata /mnt/var/lib/ollama
mount --mkdir -o umask=0077 "$ESP" /mnt/boot
findmnt -R /mnt
```

`findmnt` must list seven mounts: root, snapshots, log and pkg from `cryptroot`, home and ollama from `cryptdata`, and boot.

## Phase 2: Base system

This phase installs a minimal bootable Arch with two kernels and a hand-written Limine entry. The snapshot-aware boot tooling comes in Phase 3, because it is built from the AUR and needs a running system.

**Mirrors and packages**

```bash
reflector --country Sweden,Germany --protocol https --latest 15 --sort rate --save /etc/pacman.d/mirrorlist
pacstrap -K /mnt base base-devel linux linux-lts linux-firmware amd-ucode \
  btrfs-progs cryptsetup limine efibootmgr networkmanager openssh sudo \
  neovim git man-db reflector
```

**fstab**

```bash
genfstab -U /mnt >> /mnt/etc/fstab
sed -i 's/subvolid=[0-9]*,//' /mnt/etc/fstab
grep -c subvolid /mnt/etc/fstab     # must print 0
```

The `subvolid` options have to go. A rollback replaces `@` with a new subvolume that has a new ID but the same path, and mounting by ID would then fail.

**Key file for the data drive**

```bash
install -d -m 700 /mnt/etc/cryptsetup-keys.d
dd if=/dev/urandom of=/mnt/etc/cryptsetup-keys.d/cryptdata.key bs=4096 count=1 iflag=fullblock
chmod 400 /mnt/etc/cryptsetup-keys.d/cryptdata.key
cryptsetup luksAddKey "$DATA" /mnt/etc/cryptsetup-keys.d/cryptdata.key     # asks for the passphrase
echo "cryptdata  UUID=$(cryptsetup luksUUID "$DATA")  /etc/cryptsetup-keys.d/cryptdata.key  luks" >> /mnt/etc/crypttab
tail -n 1 /mnt/etc/crypttab
```

The key file lives on the encrypted system drive, so it can only be read once your passphrase has opened that drive. systemd then opens the data drive from `/etc/crypttab` before it mounts `/home`. The key file is not copied into the initramfs, which sits on the unencrypted EFI partition.

**Enter the new system**

```bash
arch-chroot /mnt
```

Everything until `exit` runs inside the chroot. Set your own values on the first two lines.

```bash
NEW_HOST=arch-desktop
NEW_USER=changeme

ln -sf /usr/share/zoneinfo/Europe/Stockholm /etc/localtime
hwclock --systohc
sed -i 's/^#\(en_US.UTF-8\|sv_SE.UTF-8\)/\1/' /etc/locale.gen
locale-gen
cat > /etc/locale.conf <<'EOF'
LANG=en_US.UTF-8
LC_NUMERIC=sv_SE.UTF-8
LC_TIME=sv_SE.UTF-8
LC_MONETARY=sv_SE.UTF-8
LC_PAPER=sv_SE.UTF-8
LC_MEASUREMENT=sv_SE.UTF-8
EOF
echo 'KEYMAP=sv-latin1' > /etc/vconsole.conf
echo "$NEW_HOST" > /etc/hostname
```

Timezone, locale and keymap are Swedish defaults. Change them here, and the `loadkeys` line earlier, if the desktop should differ.

**Users and sudo**

```bash
passwd
useradd -m -G wheel "$NEW_USER"
passwd "$NEW_USER"
echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/10-wheel
chmod 440 /etc/sudoers.d/10-wheel
```

**pacman: multilib for Steam, colour output**

```bash
sed -i '/^#\[multilib\]/,/^#Include/ s/^#//' /etc/pacman.conf
sed -i 's/^#Color/Color/; s/^#VerbosePkgLists/VerbosePkgLists/' /etc/pacman.conf
grep -A1 '^\[multilib\]' /etc/pacman.conf     # must show the Include line
```

**Initramfs with LUKS unlock**

```bash
sed -i 's/^HOOKS=.*/HOOKS=(base systemd keyboard autodetect microcode modconf kms sd-vconsole block sd-encrypt filesystems fsck)/' /etc/mkinitcpio.conf

LUKS_UUID=$(blkid -s UUID -o value /dev/disk/by-partlabel/cryptroot)
mkdir -p /etc/kernel
echo "rd.luks.name=${LUKS_UUID}=cryptroot root=/dev/mapper/cryptroot rootflags=subvol=/@ rw quiet amdgpu.ppfeaturemask=0xffffffff" > /etc/kernel/cmdline
cat /etc/kernel/cmdline
mkinitcpio -P
```

- `keyboard` sits before `autodetect`, so any USB keyboard can type the passphrase.
- `sd-vconsole` applies the Swedish keymap to the passphrase prompt.
- `amdgpu.ppfeaturemask` unlocks the clock and voltage controls LACT uses.
- `/etc/kernel/cmdline` is the single source for kernel parameters from here on.

**Bootloader**

```bash
mkdir -p /boot/EFI/BOOT
cp /usr/share/limine/BOOTX64.EFI /boot/EFI/BOOT/
cat > /boot/limine.conf <<EOF
timeout: 5

/Arch bootstrap
    protocol: linux
    path: boot():/vmlinuz-linux
    cmdline: $(cat /etc/kernel/cmdline)
    module_path: boot():/initramfs-linux.img

/Arch bootstrap (LTS)
    protocol: linux
    path: boot():/vmlinuz-linux-lts
    cmdline: $(cat /etc/kernel/cmdline)
    module_path: boot():/initramfs-linux-lts.img
EOF
cat /boot/limine.conf
```

Limine sits at the UEFI fallback path, which every firmware boots without an NVRAM entry. The two entries are named "bootstrap" on purpose: Phase 3 generates the permanent "Arch Linux" entry and these stay as a safety net until you remove them.

**Services, then leave the chroot**

```bash
systemctl enable NetworkManager sshd systemd-timesyncd fstrim.timer
exit
```

**Back up the LUKS headers and reboot**

```bash
cryptsetup luksHeaderBackup "$ROOT" --header-backup-file /root/luks-header-root.img
cryptsetup luksHeaderBackup "$DATA" --header-backup-file /root/luks-header-data.img
```

Copy both off from the laptop before rebooting, and keep them somewhere that is not the desktop. A damaged header without a backup means the data on that drive is gone, passphrase or not.

```bash
scp -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no 'root@<desktop-ip>:/root/luks-header-*.img' ~/
```

```bash
umount -R /mnt
cryptsetup close cryptdata
cryptsetup close cryptroot
reboot
```

Pull the USB stick. You should get the Limine menu, then one passphrase prompt, then a console login. If the firmware does not find the system, pick the 250 GB NVMe from the firmware boot menu once.

## Phase 3: Post-install script

One script takes the bare system to the finished desktop. Log in on the desktop console once, run `ip -brief addr`, then SSH in from the laptop as your new user and run it there.

```bash
git clone https://github.com/kividiot/archsetup.git
cd archsetup
bash post-install.sh
```

It asks for your sudo password once. Every stage can be run again, and single stages run by name, for example `bash post-install.sh gaming apps`.

| Stage | What it does |
| --- | --- |
| `system` | Full upgrade, zram swap, NTSync kernel module, Bluetooth |
| `snapper` | Root config with a snapshot pair around every pacman transaction, home config with an hourly timeline, and excluded subvolumes for `~/.cache`, Steam, `~/.local/share/dev.goats.xivlauncher` and `~/Games` |
| `paru` | Builds the AUR helper |
| `limine` | Installs limine-mkinitcpio-hook and limine-snapper-sync, adds the overlay hook, registers the UEFI entry, generates the permanent "Arch Linux" boot entries |
| `graphics` | Mesa and RADV in 64 and 32 bit, LACT |
| `desktop` | Hyprland, portals, SDDM, kitty, fonts |
| `audio` | PipeWire stack, LDAC, HeadsetControl |
| `gaming` | Steam, Lutris, gamescope, MangoHud, gamemode, umu-launcher, Wine, protontricks, ProtonPlus, XIVLauncher-RB |
| `apps` | Discord, Neovim and its helpers, Helium, Snapmaker Orca, OrcaSlicer |
| `ollama` | Ollama with the ROCm backend, the ROCm HIP runtime and `rocminfo`, service started. Creates and mounts `@ollama` if Phase 1 did not |
| `undervolt` | ryzen_smu kernel module through DKMS, the `ryzen-undervolt` tool and a service that applies the Curve Optimizer offset at boot |
| `maintenance` | Mirror refresh, package cache cleanup, monthly btrfs scrub, fwupd, arch-update |
| `userconfig` | Hyprland display and gaming snippet, MangoHud config |
| `shell` | zsh, oh-my-zsh with the plugins ML4W loads, powerlevel10k. The prompt and the login shell follow when it runs again in Phase 5 |
| `summary` | Health checks and a list of any AUR package that failed |

**What to expect while it runs**

- Eleven packages come from the AUR: paru-bin, limine-mkinitcpio-hook, limine-snapper-sync, protonplus, xivlauncher-rb, game-devices-udev, helium-browser-bin, snapmaker-orca-appimage, orca-slicer-bin, ryzen_smu-dkms-git and arch-update.
- paru shows each AUR build file for review. Press `q` to leave the pager, then confirm. Set `AUR_NOREVIEW=1` in front of the command to skip all of that.
- The two Limine packages compile a native binary with GraalVM, and xivlauncher-rb builds with the .NET SDK. Each takes a few minutes.
- A failed AUR package does not stop the run, except the two Limine ones. The summary lists what to retry.

When it finishes, reboot and pick the new "Arch Linux" entry in the Limine menu.

## Phase 4: Snapshots and rollback

After the reboot the "Arch Linux" entry holds both kernels and a Snapshots submenu. Check it, then drop the bootstrap entries.

**Remove the bootstrap entries**

Only do this after the "Arch Linux" entry has booted successfully.

```bash
sudo limine-remove-entry "Arch bootstrap"
sudo limine-remove-entry "Arch bootstrap (LTS)"
sudo grep -n 'boot():/vmlinuz\|boot():/initramfs' /boot/limine.conf     # must print nothing
sudo rm /boot/vmlinuz-linux /boot/vmlinuz-linux-lts /boot/initramfs-linux.img /boot/initramfs-linux-lts.img
sudo limine-list
```

The permanent entries boot from `/boot/<machine-id>/<kernel>/`, so the four files in the root of the EFI partition are leftovers. If the `grep` prints a line, something still points at them: stop and do not delete. If `limine-remove-entry` does not find the entries, delete the two `Arch bootstrap` blocks from `/boot/limine.conf` in an editor instead.

**Verify**

```bash
snapper -c root list
sudo limine-snapper-list
sudo limine-snapper-info
```

Snapshots taken before the Limine tooling was installed never become boot entries, because their kernel files were not saved. That is expected.

**How snapshots are set up**

| Config | Covers | Created | Kept |
| --- | --- | --- | --- |
| `root` | `/` without home, logs, package cache and Ollama models | Before and after every pacman or paru transaction | 20, plus up to 6 marked important |
| `home` | `/home` without `~/.cache`, Steam, `~/.local/share/dev.goats.xivlauncher`, `~/Games` | Hourly | 6 hourly, 7 daily, 2 weekly |

The newest 12 root snapshots are bootable from the Limine menu. Every snapshot sits on the same drive as the data it covers: root snapshots on the 250 GB drive, home snapshots on the 2 TB drive. They undo bad updates and deleted files, and they do not survive a dead drive, so anything irreplaceable still needs a copy elsewhere.

**Roll back a bad update**

1. In the Limine menu open Arch Linux, then Snapshots, and boot the snapshot from before the update. It runs read-only with a temporary writable layer, and your home is untouched.
2. If that system works, make it permanent with `sudo limine-snapper-restore`, pick the same snapshot and reboot.
3. The tool adds a "backup" boot entry of the state you left, in case you want to go back.

If the login screen does not come up in a snapshot, press `E` on the snapshot entry, append ` 1` to the kernel command line to boot into rescue mode, and run `limine-snapper-restore` there.

**Get one file back in home**

```bash
snapper -c home list
ls /home/.snapshots/<number>/snapshot/$USER/
```

Copy what you need out of that path. btrfs-assistant gives you the same thing with a file browser.

**Last resort from the Arch ISO**

Unlock and mount the top-level subvolume, move `@` aside, and snapshot the wanted number back into place. The Arch wiki describes it step by step under [Restoring / to its previous snapshot](https://wiki.archlinux.org/title/Snapper#Restoring_/_to_its_previous_snapshot).

## Phase 5: Desktop and rice

The rice is a stock install of the ML4W dotfiles. Nothing is copied from another machine. The post-install script adds two things on top: the display and gaming snippet, and powerlevel10k as the zsh prompt.

**Install the dotfiles**

Run ML4W's documented one-liner as your user, on the desktop console or over SSH. The installer is interactive.

```bash
bash <(curl -s https://ml4w.com/os/stable)
```

It installs git, make, curl and jq, places the ML4W Dotfiles Installer in `~/.local/bin`, and launches it with the stable Hyprland profile ([ML4W README](https://github.com/mylinuxforwork/dotfiles)).

**Hook in the display and gaming settings**

The post-install script wrote them to `~/.config/gaming/hyprland.lua`, outside the directory ML4W manages. Load that file from ML4W's custom hook, and protect the hook from installer updates.

```bash
echo 'dofile(os.getenv("HOME") .. "/.config/gaming/hyprland.lua")' >> ~/.config/hypr/custom.lua
mkdir -p ~/.config/ml4w-dotfiles-installer/com.ml4w.dotfiles.stable
echo '.config/hypr/custom.lua' >> ~/.config/ml4w-dotfiles-installer/com.ml4w.dotfiles.stable/blacklist
```

**Switch to zsh with powerlevel10k**

ML4W installs zsh and ships a zsh config built on oh-my-zsh, with oh-my-posh as the prompt. It leaves the login shell alone until you choose "Change Shell" in its Welcome app. Skip that entry and run the `shell` stage again instead, now that the ML4W files exist:

```bash
bash ~/archsetup/post-install.sh shell
```

The stage does three things:

- It writes `~/.config/zshrc/custom/20-customization`, a copy of ML4W's file of the same name with the oh-my-posh lines removed and powerlevel10k set as the oh-my-zsh theme. ML4W loads a file in `custom/` in place of its own.
- It adds that path to the installer blacklist.
- It makes zsh your login shell, from the next login.

oh-my-zsh, the three plugins ML4W's config loads and powerlevel10k were already cloned into `~/.oh-my-zsh` when the script first ran.

The override is a copy, so later changes ML4W makes to its own `20-customization` do not reach it. To pick them up, delete the override and run the stage again.

**Start the desktop**

```bash
sudo reboot
```

SDDM comes up after the passphrase prompt. Set the keyboard layout to `se` in the ML4W settings app if the installer did not ask.

**Set up the prompt**

powerlevel10k starts with its default look. Its wizard is switched off from starting by itself, so that it runs in kitty with the desktop's fonts and not in an SSH session. Open kitty and run it once:

```bash
p10k configure
```

- Instant prompt: choose `Off`. ML4W prints fastfetch when a terminal opens, and instant prompt warns about output during startup.
- "Apply changes to ~/.zshrc?": answer `n`. That file is ML4W's loader, and the override already reads `~/.p10k.zsh`.

The wizard saves your choices in `~/.p10k.zsh`. Run it again whenever you want a different look.

**OLED care**

- Let hypridle turn the panel off after a few minutes. ML4W ships a hypridle config that does this.
- Let the monitor go to standby instead of cutting its power, so it can run its pixel refresh.
- Prefer a dark wallpaper and consider hiding the status bar in fullscreen-heavy use.

## Display and GPU

The 9070 XT needs no vendor driver: Mesa 26.2 with RADV is the whole stack. What is left is telling Hyprland about the panel and setting a fan curve.

**Check the driver**

```bash
vulkaninfo --summary | grep -i devicename
vainfo | head -5
hyprctl monitors
```

**Adjust the monitor rule**

Edit `~/.config/gaming/hyprland.lua`, set `output` to the name `hyprctl monitors` printed, pick your scale, then run `hyprctl reload`.

| Setting | Value | Reason |
| --- | --- | --- |
| `mode` | `3840x2160@165` | Native resolution and refresh rate |
| `scale` | `1.5` | Gives a 2560x1440 logical desktop. Use `1.25` or `1.333333` for more space |
| `bitdepth` | `10` | Needed for wide gamut and HDR output |
| `cm` | `auto` | Wide gamut on the desktop when the panel supports it |
| `misc.vrr` | `2` | VRR in fullscreen only. Desktop VRR makes OLED panels flicker when the frame rate jumps around |
| `render.direct_scanout` | `2` | Fullscreen games that declare themselves as games skip the compositor |
| `xwayland.force_zero_scaling` | `true` | XWayland games render at native 4K instead of being upscaled from 1440p |
| `general.allow_tearing` | `true` | Master switch only. Nothing tears until a game gets an `immediate` window rule |

Steam itself runs through XWayland and looks tiny with zero scaling. Start it with `steam -forcedesktopscaling 1.5`, or turn on interface scaling in its settings.

**HDR**

Hyprland 0.57 switches the monitor to HDR by itself when a fullscreen window presents HDR content. That is `render.cm_auto_hdr`, on by default ([Hyprland wiki](https://wiki.hypr.land/0.57.0/configuring/core/config-options/)). The desktop stays in SDR.

Because the desktop is SDR, a game does not see an HDR monitor and never asks for it. GE-Proton documents the fix for exactly this Hyprland case: force HDR per game in the Steam launch options ([GE-Proton README](https://github.com/GloriousEggroll/proton-ge-custom#enable-hdr)).

```bash
PROTON_ENABLE_WAYLAND=1 PROTON_FORCE_HDR=1 %command%
```

For a game that misbehaves on the native Wayland path, wrap it in gamescope instead and drop the two variables:

```bash
gamescope -W 3840 -H 2160 -r 165 -f --hdr-enabled --adaptive-sync --mangoapp -- %command%
```

**LACT**

The daemon is already running and the kernel parameter that unlocks tuning is set. Open LACT and:

1. Set a fan curve. The stock curve keeps the fans off until the card is warm.
2. Optionally lower the power limit or add a small negative voltage offset, then test stability in a demanding game before going further.
3. Click Apply. The daemon saves the settings and restores them at every boot.

## CPU undervolt

The `undervolt` stage sets a Curve Optimizer offset of -5 on all eight cores. A negative offset makes the CPU ask for less voltage at every frequency, which lowers heat and power. Too large an offset shows up as crashes or sudden reboots, often at idle or light load and not under full load.

**What is installed**

| Piece | Job |
| --- | --- |
| `ryzen_smu-dkms-git` (AUR) | Kernel module that gives root access to the CPU's SMU. DKMS rebuilds it for `linux` and `linux-lts` on every kernel update |
| `/usr/local/bin/ryzen-undervolt` | Small tool from this repository that sets and reads the offset. It refuses any CPU that is not a Ryzen 5000 desktop chip |
| `/etc/ryzen-undervolt.conf` | The setting: `OFFSET=-5` |
| `ryzen-undervolt.service` | Applies the setting at boot and again after resume from sleep |

The SMU keeps the offset only until the next reboot. Nothing is written to the firmware, and the BIOS settings stay as they are.

**Change the value**

```bash
sudo ryzen-undervolt show             # offset of every core
sudo ryzen-undervolt set -10          # try a value, gone after a reboot
sudoedit /etc/ryzen-undervolt.conf    # keep it: OFFSET=-10
sudo systemctl restart ryzen-undervolt.service
```

The range is -30 to 0, and one count is roughly 3 to 5 mV. Go down in steps of 5 with `set`, live with each step for a while including idle time, and write a value to the config file only once it has proven stable. `OFFSET=0` runs stock voltage.

**If a saved value makes the system unstable**

The service applies the saved value at every boot, so a reboot alone does not help. In the Limine menu press `E` on the Arch Linux entry, append `systemd.mask=ryzen-undervolt.service` to the kernel command line and boot. The system comes up at stock voltage, and you can put a milder value in the config file.

## Gaming stack

Steam with GE-Proton covers most of the library, Lutris and umu cover everything outside Steam, and XIVLauncher-RB handles FFXIV on its own.

| Tool | Package | Use it for |
| --- | --- | --- |
| Steam | `steam` | The library. Turn on Steam Play for all titles under Settings, Compatibility |
| ProtonPlus | `protonplus` (AUR) | Installing and updating GE-Proton for Steam and Lutris |
| Lutris | `lutris` | Non-Steam games and launchers, installed under `~/Games` |
| umu-launcher | `umu-launcher` | Running any Windows installer or game with Proton from the terminal |
| protontricks, winetricks | `protontricks`, `winetricks` | Adding DLLs, fonts and runtimes to a game prefix |
| gamescope | `gamescope` | A per-game micro-compositor for stubborn HDR, scaling or focus problems |
| MangoHud, GOverlay | `mangohud`, `goverlay` | The overlay and a GUI to edit it. Toggle with Right Shift + F12 |
| gamemode | `gamemode` | Performance governor and process priority while a game runs |
| XIVLauncher-RB | `xivlauncher-rb` (AUR) | FFXIV with Dalamud. Game data lands in `~/.local/share/dev.goats.xivlauncher`, and the launcher adds a `~/.xlcore` symlink to it |
| LACT | `lact` | GPU fan curve, power limit, voltage offset |

**First run**

1. Start Steam, log in, enable Steam Play for all titles.
2. Open ProtonPlus, install the latest GE-Proton, restart Steam.
3. Select GE-Proton per game under Properties, Compatibility, when a game needs HDR, FSR 4 or a fix that Valve's Proton lacks.

**Steam launch options**

| Goal | Launch options |
| --- | --- |
| Baseline | `gamemoderun mangohud %command%` |
| HDR on Hyprland, GE-Proton | `PROTON_ENABLE_WAYLAND=1 PROTON_FORCE_HDR=1 gamemoderun %command%` |
| FSR 4 in an FSR 3.1 game, GE-Proton | `PROTON_FSR4_UPGRADE=1 gamemoderun %command%` |
| gamescope wrapper with HDR and VRR | `gamescope -W 3840 -H 2160 -r 165 -f --hdr-enabled --adaptive-sync --mangoapp -- %command%` |

NTSync needs no option. GE-Proton uses it whenever `/dev/ntsync` exists, and the post-install script loads the module at boot.

**Outside Steam**

```bash
PROTONPATH=GE-Proton umu-run ~/Downloads/setup.exe
```

umu downloads the current GE-Proton on first use and keeps its prefixes under `~/Games/umu`.

**What will not run**

Games with kernel-level anti-cheat that the publisher has not enabled for Linux do not start under Proton, whatever the setup. Check a title on [areweanticheatyet.com](https://areweanticheatyet.com/) before buying it.

## Apps

Every app on the list has a package, and the post-install script installs all of them. Versions are as of the date at the top.

| App | Package | Source | Version | Note |
| --- | --- | --- | --- | --- |
| Helium | `helium-browser-bin` | AUR | 0.22.1.1 | Prebuilt upstream binary |
| Steam | `steam` | multilib | 1.0.0.87 | |
| Lutris | `lutris` | extra | 0.5.22 | |
| Discord | `discord` | extra | 1.0.170 | If screen sharing misbehaves on Hyprland, `vesktop-bin` from the AUR is the usual alternative |
| Snapmaker Orca | `snapmaker-orca-appimage` | AUR | 2.4.1 | Snapmaker's AppImage, repackaged |
| OrcaSlicer | `orca-slicer-bin` | AUR | 2.5.1 | Prebuilt upstream binary |
| Neovim | `neovim` | extra | 0.12.6 | Installed with ripgrep, fd, node, npm, tree-sitter-cli, unzip and lazygit for plugins and LSP servers |
| XIVLauncher-RB | `xivlauncher-rb` | AUR | 1.4.0.12 | Built from source |
| LACT | `lact` | extra | 0.10.1 | |
| Wine | `wine-staging` | extra | 11.22 | |
| kitty | `kitty` | extra | 0.50.0 | The terminal. Installed by the `desktop` stage and set as ML4W's default |
| Ollama | `ollama-rocm` | extra | 0.40.16 | Installed with `rocm-hip-runtime` and `rocminfo`, ROCm 10.1 |

The two slicers are separate packages from different upstreams and should install side by side. If pacman reports a file conflict between them, keep Snapmaker Orca from the AUR and take OrcaSlicer from Flathub instead.

**Local models with Ollama**

`ollama-rocm` runs models on the 9070 XT through ROCm. Arch's ROCm 10.1 ships kernels for the card's `gfx1201` target, so the `HSA_OVERRIDE_GFX_VERSION` workaround for unsupported cards should not be needed. The `ollama` stage starts `ollama.service`; check the GPU path once:

```bash
/opt/rocm/bin/rocminfo | grep amdhsa     # must name gfx1201
ollama run gemma3:270m                   # small test model, /bye to leave
ollama ps                                # PROCESSOR must say 100% GPU
```

- Models are stored in `/var/lib/ollama` on the `@ollama` subvolume, outside the root snapshots.
- A model stays in VRAM for five minutes after its last request. Run `ollama stop <model>` before starting a game that wants all 16 GB.
- The [Arch wiki](https://wiki.archlinux.org/title/Ollama) says `ollama-vulkan` is usually faster than `ollama-rocm` on RDNA 3 and newer cards and uses less power. To compare, install `ollama-vulkan`, remove `ollama-rocm` and restart the service.
- ROCm's OpenCL for other compute apps is a separate package, `rocm-opencl-runtime`. It is not installed.

## Audio: Audeze Maxwell

Use the USB-C dongle on the desktop. It is a standard USB audio device, needs no driver, and keeps the microphone at full quality. Keep Bluetooth for the phone.

**Dongle**

1. Plug it in and run `wpctl status`. The headset shows up as one output and one input.
2. Open pavucontrol, go to Configuration, and pick the profile with stereo output and mono input.
3. Make it the default output and input there, or in the ML4W audio menu.

Other Maxwell owners report rattling on the surround profile and volume jumps when the profile switches by itself. Staying on the plain stereo profile avoids both, and WirePlumber remembers the choice.

**Headset controls from Linux**

HeadsetControl 4.2.0 lists both the Maxwell and the Maxwell 2 with battery, sidetone, auto-off timer, chat mix, voice prompts and EQ preset support ([HeadsetControl README](https://github.com/Sapd/HeadsetControl#supported-headsets)). The post-install script installs it with its udev rules, so it works without sudo.

```bash
headsetcontrol --capabilities     # what your dongle supports
headsetcontrol -b                 # battery level
headsetcontrol -s 64              # sidetone, 0 to 128
headsetcontrol -i 30              # power off after 30 idle minutes
```

Firmware updates and custom EQ curves still need Audeze HQ. Use the phone app over Bluetooth for those.

**Bluetooth**

Pair in blueman. LDAC is installed, and the codec is selected as a profile in pavucontrol's Configuration tab. Using the headset microphone over classic Bluetooth drops the audio to call quality, which is why the dongle is the better link for games and voice chat.

## Updates and maintenance

Updating is one click on the arch-update tray icon, and every update is wrapped in a bootable snapshot.

**Turn on the tray icon**

Run this once inside the Hyprland session:

```bash
arch-update --tray --enable
```

The icon changes when updates are pending. Clicking it shows new Arch news first, then upgrades repo and AUR packages through paru, offers to merge `.pacnew` files, removes orphans and says whether a reboot is needed ([arch-update README](https://github.com/Antiz96/arch-update)).

**By hand**

```bash
paru                                    # repos and AUR
fwupdmgr refresh && fwupdmgr update     # device firmware
```

GE-Proton updates through ProtonPlus. The ML4W dotfiles update through their own installer, which respects the blacklist file.

oh-my-zsh offers to update itself in the terminal every two weeks, and `omz update` does it on demand. Its three plugins and powerlevel10k are plain git clones that nothing else updates:

```bash
for repo in ~/.oh-my-zsh/custom/{plugins,themes}/*/.git; do git -C "${repo%/.git}" pull --ff-only; done
```

**What runs by itself**

| Timer | Interval | Job |
| --- | --- | --- |
| `arch-update.timer` | At boot, then every 6 hours | Checks for updates, never installs |
| `ryzen-undervolt.service` | At boot and after resume | Applies the Curve Optimizer offset |
| snap-pac | Every pacman transaction | Root snapshot before and after |
| `limine-snapper-sync.service` | On every new snapshot | Makes it bootable |
| `snapper-timeline.timer` | Hourly | Home snapshot |
| `snapper-cleanup.timer` | Daily | Prunes snapshots to the limits in Phase 4 |
| `reflector.timer` | Weekly | Refreshes the mirror list |
| `paccache.timer` | Weekly | Trims the package cache to three versions |
| `fstrim.timer` | Weekly | TRIM through the encryption layer |
| `btrfs-scrub@-.timer`, `btrfs-scrub@home.timer` | Monthly | Verify checksums on the system drive and on the data drive |

**Two rules for this boot setup**

- Change kernel parameters in `/etc/kernel/cmdline`, then run `sudo limine-update`.
- Rebuild the initramfs with `sudo limine-update`, not `mkinitcpio -P`. Only the first one refreshes the boot entries.

**When an update breaks something**

Boot the pre-update snapshot from the Limine menu and follow "Roll back a bad update" in Phase 4. If only the newest kernel is at fault, pick the `linux-lts` entry instead and wait for the fix.

## Checks and known gotchas

Nothing in this runbook has run on the hardware yet. These are the points to confirm along the way, followed by the issues that could come up.

**Confirm on the day**

- [ ] The size check in Phase 1 printed `OK`: `OS_DISK` is the 250 GB drive and `DATA_DISK` the 2 TB drive.
- [ ] The passphrase works at the boot prompt, typed on the desktop keyboard.
- [ ] There is one passphrase prompt at boot, and `findmnt /home` shows `/dev/mapper/cryptdata`.
- [ ] `sudo limine-snapper-info` lists snapshot entries and reports 0 missing and 0 corrupted files.
- [ ] A snapshot entry boots. Try one before you need one.
- [ ] The output name and scale in `~/.config/gaming/hyprland.lua` match the monitor.
- [ ] `headsetcontrol -b` answers without sudo.
- [ ] A new kitty window opens zsh with the powerlevel10k prompt and no error lines above it.
- [ ] `ollama ps` says `100% GPU` while a model is loaded.
- [ ] `sudo ryzen-undervolt show` prints -5 for all eight cores, also after a reboot.
- [ ] Both slicers start.

If the snapshot paths are detected wrongly, set `ROOT_SUBVOLUME_PATH` and `ROOT_SNAPSHOTS_PATH` in `/etc/default/limine` and run `sudo limine-update`.

**Known issues**

| Symptom | Cause | What to do |
| --- | --- | --- |
| Desktop stays very bright after leaving a fullscreen HDR game | Reported with `bitdepth = 10` on the [Hyprland forum](https://forum.hypr.land/t/when-i-launch-a-full-screen-hdr-app-mpv-for-example-while-i-have-bitdepth-10-hyprland-doesnt-revert-back-to-sdr-when-app-is-exited-or-full-screen-is-exited-leaving-an-insanely-bright-display/1454) | Remove the `bitdepth` line and run `hyprctl reload` |
| Brightness flicker in dark scenes while a game runs | VRR on an OLED panel with an unsteady frame rate | Cap the frame rate in MangoHud, or set `misc.vrr` to `0` for that session |
| Clicking links in kitty does nothing | kitty 0.50.0, the version Arch ships | Add an `open-actions.conf` that hands links to `xdg-open` |
| The Limine menu is gone after a firmware update | The firmware dropped its boot entry | Nothing. The fallback loader boots, and `sudo limine-install` re-registers the entry |
| `mkinitcpio -P` asks about Limine | The Limine tooling wraps it | Answer yes, or use `sudo limine-update` |
| Boot stops in emergency mode after the passphrase | The data drive did not open or mount | Log in as root and read `systemctl status systemd-cryptsetup@cryptdata.service`. `cryptsetup open /dev/disk/by-partlabel/cryptdata cryptdata` opens it with the passphrase, then `mount -a` and `systemctl default` continue the boot |
| `ryzen-undervolt.service` fails after a kernel update | DKMS could not build ryzen_smu for the new kernel | Check `dkms status`. The system runs at stock voltage until the module builds again, so boot `linux-lts` or wait for the AUR package to catch up |
| `ollama ps` says CPU and answers are slow | ROCm did not accept the GPU | Follow "ROCm is not utilizing my AMD GPU" on the [Arch wiki](https://wiki.archlinux.org/title/Ollama#ROCm_is_not_utilizing_my_AMD_GPU), or switch to `ollama-vulkan` |

**Deliberately left out**

- Secure Boot. The EFI partition is unencrypted, so the kernel and initramfs could be tampered with by someone with physical access. Closing that takes your own keys with sbctl and Limine's config enrolment.
- A real backup. Snapshots share a drive with the data they cover, and the two drives do not mirror each other.
- sched-ext schedulers. `scx-scheds` is in the repos for experiments; the stock scheduler is fine on a single-CCD X3D chip.
- A gaming kernel. The stock `linux` kernel already carries NTSync and sched-ext, so the gain from a tuned kernel is small. To try one, `sudo pacman -S linux-zen linux-zen-headers` is enough: both are in the official repos, the Limine hook adds the boot entry next to the other two, and the headers let DKMS build ryzen_smu for it.

sshd stays enabled from the install. Run `sudo systemctl disable --now sshd` if you do not want it.

## Sources

- Arch wiki: [Limine](https://wiki.archlinux.org/title/Limine), [Snapper](https://wiki.archlinux.org/title/Snapper), [Ollama](https://wiki.archlinux.org/title/Ollama)
- [XIVLauncher-RB source](https://github.com/rankynbass/XIVLauncher.Core/tree/RB-patched), for the storage path
- [ryzen_smu README](https://github.com/amkillam/ryzen_smu) for the driver interface. The Curve Optimizer command IDs match [ZenStates-Core](https://github.com/irusanov/ZenStates-Core) and [Ryzen-5800x3d-linux-undervolting](https://github.com/svenlange2/Ryzen-5800x3d-linux-undervolting)
- [limine-snapper-sync README](https://gitlab.com/Zesko/limine-snapper-sync/-/blob/master/README.md) and [limine-entry-tool README](https://gitlab.com/Zesko/limine-entry-tool/-/blob/master/README.md)
- Hyprland 0.57 wiki: [monitor colors and HDR](https://wiki.hypr.land/0.57.0/configuring/core/monitors/colors/), [tearing](https://wiki.hypr.land/0.57.0/configuring/extra/tearing/), [config options](https://wiki.hypr.land/0.57.0/configuring/core/config-options/)
- [GE-Proton README](https://github.com/GloriousEggroll/proton-ge-custom): HDR, NTSync and FSR 4 options
- [ML4W dotfiles README](https://github.com/mylinuxforwork/dotfiles)
- [powerlevel10k README](https://github.com/romkatv/powerlevel10k) and [oh-my-zsh README](https://github.com/ohmyzsh/ohmyzsh)
- [HeadsetControl README](https://github.com/Sapd/HeadsetControl)
- [arch-update README](https://github.com/Antiz96/arch-update)
- [GamingOnLinux on AMD HDMI 2.1](https://www.gamingonlinux.com/2026/05/further-expanded-amd-hdmi-2-1-support-is-coming-to-linux-now-with-frl-and-dsc/)
- Package names and versions: the [Arch package database](https://archlinux.org/packages/) and the [AUR](https://aur.archlinux.org/), checked on the date at the top
