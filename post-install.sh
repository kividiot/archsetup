#!/usr/bin/env bash
#
# post-install.sh - turns the fresh base install from the "Arch Gaming Desktop
# Runbook" (Phases 1-2) into the finished gaming desktop.
#
# Run as your normal user after the first boot, never as root:
#
#     bash post-install.sh                # every stage, in order
#     bash post-install.sh --list         # print the stage names
#     bash post-install.sh gaming apps    # only the named stages
#
# Every stage is safe to run again. Nothing here touches the partition table,
# the LUKS container or existing files in your home directory.
#
# AUR packages are shown for review before they build (paru's default).
# Set AUR_NOREVIEW=1 to skip the reviews and all confirmations.

set -euo pipefail

STAGES=(system snapper paru limine graphics desktop audio gaming apps ollama maintenance userconfig shell summary)

MIRROR_COUNTRIES="Sweden,Germany"
FAILED=()

# ----------------------------------------------------------------- helpers ---

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m!!  %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# Official repositories. Fails the script on error: a missing repo package
# means something is wrong with pacman or the network.
pac() { sudo pacman -S --needed --noconfirm "$@"; }

# AUR, one package at a time so a single broken PKGBUILD does not block the
# rest. Failures are collected and listed in the summary.
aur() {
    local pkg
    for pkg in "$@"; do
        if pacman -Qq "$pkg" &>/dev/null; then
            continue
        fi
        if [[ ${AUR_NOREVIEW:-0} == 1 ]]; then
            paru -S --needed --noconfirm --skipreview "$pkg" || FAILED+=("$pkg")
        else
            paru -S --needed "$pkg" || FAILED+=("$pkg")
        fi
    done
}

# AUR package the rest of the script depends on.
aur_required() {
    local pkg
    for pkg in "$@"; do
        aur "$pkg"
        pacman -Qq "$pkg" &>/dev/null || die "Required AUR package $pkg did not install."
    done
}

# Shallow git clone, skipped when the destination already exists.
clone() {
    local url=$1 dest=$2
    if [[ -d $dest ]]; then
        return 0
    fi
    git clone --quiet --depth=1 "$url" "$dest"
    info "cloned $dest"
}

# Create a btrfs subvolume at a path in $HOME so that home snapshots skip it.
mksubvol() {
    local path=$1
    if [[ -d $path ]]; then
        # Inode 256 is the root of a btrfs subvolume.
        if [[ $(stat -c %i "$path") -eq 256 ]]; then
            return 0
        fi
        if [[ -n $(ls -A "$path") ]]; then
            warn "$path already has content, left as a normal directory (home snapshots will include it)."
            return 0
        fi
        rmdir "$path"
    fi
    mkdir -p "$(dirname "$path")"
    btrfs subvolume create "$path" >/dev/null
    info "subvolume $path"
}

preflight() {
    [[ $EUID -ne 0 ]] || die "Run this as your normal user, not as root."
    command -v sudo >/dev/null || die "sudo is not installed."
    [[ -d /sys/firmware/efi ]] || die "Not booted in UEFI mode."
    [[ $(findmnt -no FSTYPE /) == btrfs ]] || die "/ is not btrfs."
    grep -q '^\[multilib\]' /etc/pacman.conf || die "multilib is not enabled in /etc/pacman.conf (runbook Phase 2)."
    if grep -q subvolid /etc/fstab; then
        die "/etc/fstab still contains subvolid= options. Remove them first (runbook Phase 2)."
    fi
    curl -fsS -m 10 -o /dev/null https://archlinux.org || die "No network connection."
}

# ------------------------------------------------------------------ stages ---

stage_system() {
    sudo pacman -Syu --noconfirm
    pac base-devel git zram-generator bluez bluez-utils

    # Compressed swap in RAM. No swap partition, no hibernate.
    sudo tee /etc/systemd/zram-generator.conf >/dev/null <<'EOF'
[zram0]
zram-size = min(ram / 2, 8192)
compression-algorithm = zstd
EOF
    # Values recommended by the Arch wiki for swap on zram.
    sudo tee /etc/sysctl.d/99-zram.conf >/dev/null <<'EOF'
vm.swappiness = 180
vm.watermark_boost_factor = 0
vm.watermark_scale_factor = 125
vm.page-cluster = 0
EOF
    sudo systemctl daemon-reload
    sudo systemctl start systemd-zram-setup@zram0.service || warn "zram did not start now; it will after a reboot."
    sudo sysctl --system >/dev/null

    # NTSync: kernel-side Windows synchronisation primitives, used by Proton
    # automatically once /dev/ntsync exists.
    echo ntsync | sudo tee /etc/modules-load.d/ntsync.conf >/dev/null
    sudo modprobe ntsync || warn "ntsync module did not load; check after a reboot."

    sudo systemctl enable --now bluetooth.service
}

stage_snapper() {
    pac snapper snap-pac btrfs-assistant

    # Root config. snapper insists on creating /.snapshots itself, so move the
    # @snapshots mount aside, let it, then put the mount back
    # (Arch wiki: Snapper, "Suggested filesystem layout").
    if [[ ! -f /etc/snapper/configs/root ]]; then
        if findmnt -n /.snapshots >/dev/null; then
            sudo umount /.snapshots
        fi
        if [[ -d /.snapshots ]]; then
            sudo rmdir /.snapshots
        fi
        sudo snapper -c root create-config /
        sudo btrfs subvolume delete /.snapshots
        sudo mkdir /.snapshots
        sudo mount /.snapshots
        sudo chmod 750 /.snapshots
    fi
    findmnt -n /.snapshots >/dev/null || die "/.snapshots is not mounted. Check the @snapshots line in /etc/fstab."

    # Root: snapshots around every pacman transaction (snap-pac), no timeline.
    sudo snapper -c root set-config \
        ALLOW_GROUPS=wheel SYNC_ACL=yes \
        TIMELINE_CREATE=no \
        NUMBER_CLEANUP=yes NUMBER_MIN_AGE=1800 \
        NUMBER_LIMIT=20 NUMBER_LIMIT_IMPORTANT=6

    # Keep big, replaceable data out of the home snapshots. This must happen
    # before Steam and friends create these directories.
    local dir
    for dir in .cache .local/share/Steam .local/share/dev.goats.xivlauncher Games; do
        mksubvol "$HOME/$dir"
    done

    # Home: hourly timeline, for recovering deleted or overwritten files.
    if [[ ! -f /etc/snapper/configs/home ]]; then
        sudo snapper -c home create-config /home
    fi
    sudo snapper -c home set-config \
        ALLOW_USERS="$USER" SYNC_ACL=yes \
        TIMELINE_CREATE=yes TIMELINE_CLEANUP=yes TIMELINE_MIN_AGE=1800 \
        TIMELINE_LIMIT_HOURLY=6 TIMELINE_LIMIT_DAILY=7 TIMELINE_LIMIT_WEEKLY=2 \
        TIMELINE_LIMIT_MONTHLY=0 TIMELINE_LIMIT_YEARLY=0

    sudo systemctl enable --now snapper-timeline.timer snapper-cleanup.timer
}

stage_paru() {
    if command -v paru >/dev/null; then
        return 0
    fi
    pac base-devel git less
    local tmp
    tmp=$(mktemp -d)
    git clone --depth 1 https://aur.archlinux.org/paru-bin.git "$tmp/paru-bin"
    (cd "$tmp/paru-bin" && makepkg -si --noconfirm)
    rm -rf "$tmp"
}

stage_limine() {
    command -v paru >/dev/null || die "paru is missing. Run the paru stage first."
    [[ -s /etc/kernel/cmdline ]] || die "/etc/kernel/cmdline is missing or empty (runbook Phase 2)."
    grep -q 'rootflags=subvol=/@' /etc/kernel/cmdline || die "/etc/kernel/cmdline lacks rootflags=subvol=/@."
    pac limine efibootmgr kernel-modules-hook

    # Written before the packages install, so their own hooks already see it.
    if [[ ! -f /etc/default/limine ]]; then
        sudo tee /etc/default/limine >/dev/null <<'EOF'
# Settings for limine-entry-tool and limine-snapper-sync.
# Kernel parameters live in /etc/kernel/cmdline. After editing either file run:
#     sudo limine-update
ESP_PATH="/boot"

# Keep the UEFI fallback loader (EFI/BOOT/BOOTX64.EFI) current as well, so the
# machine still boots if the firmware forgets its boot entries.
ENABLE_LIMINE_FALLBACK=yes

# Bootable snapshots come from the root snapper config only.
SNAPPER_CONFIG_NAME="root"
RESTORE_METHOD=replace
MAX_SNAPSHOT_ENTRIES=12
EOF
    fi

    # Both packages compile a native binary with GraalVM. Expect a download of
    # a few hundred MB and several minutes of build time each.
    aur_required limine-mkinitcpio-hook

    # Lets a read-only snapshot boot with a temporary writable layer on top.
    if ! grep -q 'sd-btrfs-overlayfs' /etc/mkinitcpio.conf; then
        sudo sed -i '/^HOOKS=/ s/\<filesystems\>/filesystems sd-btrfs-overlayfs/' /etc/mkinitcpio.conf
    fi
    grep -q 'sd-btrfs-overlayfs' /etc/mkinitcpio.conf || die "Could not add sd-btrfs-overlayfs to HOOKS in /etc/mkinitcpio.conf."

    aur_required limine-snapper-sync

    sudo limine-install      # copies the EFI binary and registers the UEFI boot entry
    sudo limine-update       # rebuilds the initramfs images and writes the "Arch Linux" entries
    sudo systemctl enable --now limine-snapper-sync.service
    sudo systemctl enable linux-modules-cleanup.service

    # One snapshot to prove the whole chain works.
    sudo snapper -c root create --description "post-install: boot tooling ready"
    sudo limine-snapper-sync || warn "limine-snapper-sync reported a problem. Run it again by hand and read the output."
}

stage_graphics() {
    pac mesa lib32-mesa vulkan-radeon lib32-vulkan-radeon \
        vulkan-icd-loader lib32-vulkan-icd-loader \
        vulkan-tools mesa-utils libva-utils lact nvtop
    sudo systemctl enable --now lactd.service
}

stage_desktop() {
    # The minimum for a working Hyprland login. The ML4W installer (runbook,
    # "Rice") adds its own dependencies on top.
    pac hyprland xdg-desktop-portal-hyprland xdg-desktop-portal-gtk \
        hyprpolkitagent hyprlock hypridle xorg-xwayland \
        qt5-wayland qt6-wayland sddm kitty wl-clipboard xdg-user-dirs \
        noto-fonts noto-fonts-emoji ttf-jetbrains-mono-nerd ttf-liberation
    xdg-user-dirs-update
    # Enabled, not started: starting a display manager mid-script helps nobody.
    sudo systemctl enable sddm.service
}

stage_audio() {
    pac pipewire pipewire-audio pipewire-pulse pipewire-alsa pipewire-jack \
        lib32-pipewire wireplumber gst-plugin-pipewire libldac \
        pavucontrol blueman headsetcontrol
    # headsetcontrol ships udev rules for the Maxwell dongle; apply them now.
    sudo udevadm control --reload-rules
    sudo udevadm trigger
}

stage_gaming() {
    command -v paru >/dev/null || die "paru is missing. Run the paru stage first."
    pac steam lutris gamescope mangohud lib32-mangohud gamemode lib32-gamemode \
        umu-launcher wine-staging winetricks protontricks goverlay gpu-screen-recorder
    aur protonplus xivlauncher-rb game-devices-udev

    # gamemode only renices and re-prioritises for members of its group.
    if getent group gamemode >/dev/null; then
        sudo usermod -aG gamemode "$USER"
    fi
}

stage_apps() {
    command -v paru >/dev/null || die "paru is missing. Run the paru stage first."
    pac discord neovim ripgrep fd nodejs npm unzip tree-sitter-cli lazygit \
        fastfetch btop wget jq rsync fuse2
    aur helium-browser-bin snapmaker-orca-appimage orca-slicer-bin
}

stage_ollama() {
    # Models run to tens of GB. They belong in a top-level subvolume of their
    # own, so root snapshots do not pin them and a rollback of @ leaves them
    # in place. The runbook creates @ollama in Phase 1; this part covers an
    # install that was partitioned before that step existed.
    local models=/var/lib/ollama
    if ! findmnt -n "$models" >/dev/null; then
        if [[ -d $models && -n $(ls -A "$models" 2>/dev/null) ]]; then
            warn "$models already has content and is not its own subvolume: the models stay in the root snapshots."
        else
            local dev top line
            dev=$(findmnt -no SOURCE / | sed 's/\[.*//')
            top=$(mktemp -d)
            sudo mount -o subvolid=5 "$dev" "$top"
            if [[ ! -d $top/@ollama ]]; then
                sudo btrfs subvolume create "$top/@ollama" >/dev/null
            fi
            sudo umount "$top"
            rmdir "$top"

            # Same device and mount options as the package cache, other subvolume.
            if ! awk -v m="$models" '$2 == m { found = 1 } END { exit !found }' /etc/fstab; then
                line=$(awk '$2 == "/var/cache/pacman/pkg"' /etc/fstab \
                    | sed -E -e "s|/var/cache/pacman/pkg|$models|" -e 's|subvol=/?@pkg|subvol=/@ollama|')
                [[ $line == *"subvol=/@ollama"* ]] || die "Could not derive an fstab line for $models from the @pkg line."
                echo "$line" | sudo tee -a /etc/fstab >/dev/null
            fi
            sudo mkdir -p "$models"
            sudo systemctl daemon-reload
            sudo mount "$models"
            info "subvolume @ollama mounted at $models"
        fi
    fi

    # ollama-rocm pulls in the ROCm libraries it links against. The HIP runtime
    # group and rocminfo are named so they count as installed on purpose.
    pac ollama-rocm rocm-hip-runtime rocminfo

    # A fresh subvolume belongs to root; the service runs as the ollama user.
    if [[ $(stat -c %U "$models") != ollama ]]; then
        sudo chown ollama:ollama "$models"
    fi
    sudo systemctl enable --now ollama.service
}

stage_maintenance() {
    command -v paru >/dev/null || die "paru is missing. Run the paru stage first."
    pac pacman-contrib reflector fwupd
    aur arch-update

    sudo tee /etc/xdg/reflector/reflector.conf >/dev/null <<EOF
--save /etc/pacman.d/mirrorlist
--protocol https
--country $MIRROR_COUNTRIES
--latest 15
--sort rate
EOF
    sudo systemctl enable --now reflector.timer      # fresh mirror list weekly
    sudo systemctl enable --now paccache.timer       # keep the 3 newest versions of each cached package
    sudo systemctl enable --now btrfs-scrub@-.timer  # monthly checksum scrub of the root filesystem

    if pacman -Qq arch-update &>/dev/null; then
        systemctl --user enable --now arch-update.timer || warn "Could not enable arch-update.timer; run 'systemctl --user enable --now arch-update.timer' after logging in."
    fi
}

stage_userconfig() {
    # Kept outside ~/.config/hypr on purpose: the ML4W installer manages that
    # directory. Hooked in with one line in ~/.config/hypr/custom.lua (runbook).
    local hypr_gaming=$HOME/.config/gaming/hyprland.lua
    if [[ ! -f $hypr_gaming ]]; then
        mkdir -p "$(dirname "$hypr_gaming")"
        cat >"$hypr_gaming" <<'EOF'
-- Display and gaming settings for the desktop (4K 165 Hz OLED, Radeon 9070 XT).
-- Lives outside ~/.config/hypr so ML4W updates never touch it.
-- Loaded from ~/.config/hypr/custom.lua with:
--   dofile(os.getenv("HOME") .. "/.config/gaming/hyprland.lua")

-- Check the output name with `hyprctl monitors`. A "desc:<prefix>" match works
-- too. The last matching rule wins, so this overrides ML4W's monitors.lua.
hl.monitor({
    output = "DP-1",
    mode = "3840x2160@165",
    position = "0x0",
    scale = 1.5,
    bitdepth = 10,
    cm = "auto",   -- wide gamut on the desktop; HDR switches on by itself for
                   -- fullscreen HDR content (render.cm_auto_hdr, default on)
})

hl.config({
    general = {
        allow_tearing = true,   -- master switch only; nothing tears without a window rule
    },
    misc = {
        vrr = 2,                -- 0 off, 1 always, 2 fullscreen only, 3 fullscreen game/video content
    },
    render = {
        direct_scanout = 2,     -- auto: only for windows that declare the "game" content type
    },
    xwayland = {
        force_zero_scaling = true,   -- XWayland games render at native 4K instead of being upscaled
    },
})

-- Tearing for one game that wants the lowest latency above 165 fps.
-- Find the class with `hyprctl clients`.
-- hl.window_rule({ match = { class = "cs2" }, immediate = true })
EOF
        info "wrote $hypr_gaming"
    fi

    local mangohud=$HOME/.config/MangoHud/MangoHud.conf
    if [[ ! -f $mangohud ]]; then
        mkdir -p "$(dirname "$mangohud")"
        cat >"$mangohud" <<'EOF'
# Hidden until toggled with Right Shift + F12.
no_display
toggle_hud=Shift_R+F12
position=top-left
fps
frametime
frame_timing
refresh_rate
gpu_stats
gpu_temp
gpu_power
vram
cpu_stats
cpu_temp
ram
wine
gamemode
hdr
present_mode
EOF
        info "wrote $mangohud"
    fi
}

stage_shell() {
    # zsh, oh-my-zsh and powerlevel10k, laid out the way the ML4W zsh config
    # expects: oh-my-zsh in ~/.oh-my-zsh with the three plugins ML4W loads
    # cloned into its custom folder. fzf is sourced by that config as well.
    pac zsh fzf

    local omz=$HOME/.oh-my-zsh
    clone https://github.com/ohmyzsh/ohmyzsh.git "$omz"
    clone https://github.com/zsh-users/zsh-autosuggestions.git "$omz/custom/plugins/zsh-autosuggestions"
    clone https://github.com/zsh-users/zsh-syntax-highlighting.git "$omz/custom/plugins/zsh-syntax-highlighting"
    clone https://github.com/zdharma-continuum/fast-syntax-highlighting.git "$omz/custom/plugins/fast-syntax-highlighting"
    clone https://github.com/romkatv/powerlevel10k.git "$omz/custom/themes/powerlevel10k"

    # The prompt override and the login shell need ML4W's zsh config, which
    # only exists after the ML4W install (runbook Phase 5).
    local stock=$HOME/.config/zshrc/20-customization
    if [[ ! -f $stock ]]; then
        info "ML4W dotfiles are not installed yet: the login shell stays as it is."
        info "Run 'bash post-install.sh shell' again after the ML4W install."
        return 0
    fi

    # ML4W loads ~/.config/zshrc/custom/<name> in place of its own file of the
    # same name. The override is the stock file with the oh-my-posh prompt
    # taken out and powerlevel10k put in.
    local override=$HOME/.config/zshrc/custom/20-customization
    if [[ ! -f $override ]]; then
        mkdir -p "$(dirname "$override")"
        {
            cat <<'EOF'
# Written by post-install.sh (stage "shell") from ML4W's stock
# ~/.config/zshrc/20-customization, with oh-my-posh replaced by powerlevel10k.
# To rebuild it after an ML4W update, delete this file and run the stage again.

ZSH_THEME="powerlevel10k/powerlevel10k"
# The wizard does not start by itself; run `p10k configure` when you want it.
typeset -g POWERLEVEL9K_DISABLE_CONFIGURATION_WIZARD=true

EOF
            grep -v -e 'oh-my-posh init' -e '^# Shipped Theme' -e '^[[:space:]]*ZSH_THEME=' "$stock" || true
            cat <<'EOF'

# Prompt settings written by `p10k configure`.
[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh
EOF
        } >"$override"
        zsh -n "$override" || warn "$override does not parse; check it before opening a new terminal."
        info "wrote $override"
    fi

    # ML4W does not ship this path today, so its updates leave it alone. The
    # blacklist entry keeps it that way if that ever changes.
    local blacklist=$HOME/.config/ml4w-dotfiles-installer/com.ml4w.dotfiles.stable/blacklist
    local entry=.config/zshrc/custom/20-customization
    mkdir -p "$(dirname "$blacklist")"
    if ! grep -qxF "$entry" "$blacklist" 2>/dev/null; then
        echo "$entry" >>"$blacklist"
    fi

    local zsh_path=/usr/bin/zsh
    if [[ $(getent passwd "$USER" | cut -d: -f7) != "$zsh_path" ]]; then
        sudo chsh -s "$zsh_path" "$USER" >/dev/null
        info "login shell is now zsh, from the next login"
    fi
}

stage_summary() {
    log "Checks"
    info "kernel:      $(uname -r)"
    info "zram:        $(swapon --noheadings --show=NAME,SIZE 2>/dev/null | tr -s ' ' | tr '\n' ' ')"
    info "ntsync:      $([[ -e /dev/ntsync ]] && echo present || echo 'missing (reboot first)')"
    info "snapper:     $(sudo snapper list-configs --columns config 2>/dev/null | tail -n +3 | tr '\n' ' ')"
    info "lactd:       $(systemctl is-active lactd.service 2>/dev/null || true)"
    info "sddm:        $(systemctl is-enabled sddm.service 2>/dev/null || true)"
    info "ollama:      $(systemctl is-active ollama.service 2>/dev/null || true), models on $(findmnt -no SOURCE /var/lib/ollama 2>/dev/null || echo 'the root subvolume')"
    info "login shell: $(getent passwd "$USER" | cut -d: -f7)"
    if command -v limine-snapper-info >/dev/null; then
        sudo limine-snapper-info || true
    fi

    if ((${#FAILED[@]})); then
        warn "These AUR packages did not install: ${FAILED[*]}"
        warn "Retry each with: paru -S <name>"
    fi

    log "Next"
    info "1. Reboot and pick the new \"Arch Linux\" entry in the Limine menu."
    info "2. Continue with the runbook: remove the bootstrap entries, then install the ML4W dotfiles."
    if [[ $(getent passwd "$USER" | cut -d: -f7) != /usr/bin/zsh ]]; then
        info "3. After the ML4W install, run 'bash post-install.sh shell' once more to switch to zsh."
    fi
}

# -------------------------------------------------------------------- main ---

main() {
    if [[ ${1:-} == --list ]]; then
        printf '%s\n' "${STAGES[@]}"
        exit 0
    fi

    local selected=("$@")
    if ((${#selected[@]} == 0)); then
        selected=("${STAGES[@]}")
    fi
    local stage
    for stage in "${selected[@]}"; do
        declare -F "stage_$stage" >/dev/null || die "Unknown stage: $stage (see --list)"
    done

    preflight

    # Ask for the sudo password once and keep the ticket alive during long builds.
    sudo -v
    ( while sleep 55; do sudo -n true 2>/dev/null || exit; done ) &
    local keepalive=$!
    # shellcheck disable=SC2064
    trap "kill $keepalive 2>/dev/null || true" EXIT

    for stage in "${selected[@]}"; do
        log "Stage: $stage"
        "stage_$stage"
    done
}

main "$@"
