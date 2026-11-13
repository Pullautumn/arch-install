#!/usr/bin/env bash
# ==============================================================================
# arch-install.sh — Arch Linux Live ISO 安装自动化
#
# 独立脚本，无外部依赖：只用到 archiso 自带的命令，不读任何仓库里的文件。
#
# 依据：SHORiN-KiWATA/Shorin-ArchLinux-Guide 的「手动安装」章节
#   分区 → 格式化 → Btrfs 子卷(@ / @home, 可选 @swap) → 挂载 → pacstrap
#   → swapfile(可选) → fstab → arch-chroot 基础配置 → GRUB → ZRAM → 退出重启
#
# 不覆盖：桌面环境 / dotfiles（重启后自行部署）、LUKS、Secure Boot。
#
# 用法：
#   curl -fsSL https://raw.githubusercontent.com/Pullautumn/arch-install/main/arch-install.sh -o /tmp/ai.sh
#   bash /tmp/ai.sh
#
# 为什么输出全英文：archiso 的 console font 没有 CJK 字形，中文会变成豆腐块。
# 每个可选步骤都会停下来问，默认值取 wiki 的推荐值，回车即为默认。
# ==============================================================================

set -Eeuo pipefail

LOG=/tmp/arch-install.log
MNT=/mnt
: >"$LOG"

if [[ -t 1 ]]; then
    C_RST=$'\e[0m'; C_B=$'\e[1m'; C_R=$'\e[31m'
    C_G=$'\e[32m'; C_Y=$'\e[33m'; C_C=$'\e[36m'
else
    C_RST=""; C_B=""; C_R=""; C_G=""; C_Y=""; C_C=""
fi

say()  { printf '%s\n' "$*"; printf '%s\n' "$*" >>"$LOG"; }
step() { printf '\n%s==> %s%s\n' "$C_B$C_C" "$*" "$C_RST"; printf '\n==> %s\n' "$*" >>"$LOG"; }
ok()   { printf '%s  ok%s  %s\n' "$C_G" "$C_RST" "$*"; printf '  ok  %s\n' "$*" >>"$LOG"; }
warn() { printf '%s warn%s %s\n' "$C_Y" "$C_RST" "$*"; printf ' warn %s\n' "$*" >>"$LOG"; }
die()  { printf '%s fail%s %s\n' "$C_R" "$C_RST" "$*" >&2; printf ' fail %s\n' "$*" >>"$LOG"; exit 1; }

on_error() {
    printf '\n%s!! aborted at line %s: %s%s\n' "$C_R" "$1" "$2" "$C_RST" >&2
    printf '\nNothing was cleaned up automatically. Inspect with: lsblk -f\n' >&2
    printf 'Full log: %s\n' "$LOG" >&2
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

# 命令执行：回显 + 落日志；配合 pipefail，失败会触发 ERR trap
run() {
    printf '%s+ %s%s\n' "$C_C" "$*" "$C_RST"
    printf '+ %s\n' "$*" >>"$LOG"
    "$@" 2>&1 | tee -a "$LOG"
}

# ------------------------------------------------------------------------------
# 交互函数
# ------------------------------------------------------------------------------
# 归一化输入：去掉所有空白字符（含 CR）。
# 粘贴进 VM console / 串口时行尾常带 \r，而 read -r 只按 IFS（空格/tab/换行）切分，
# \r 会被保留成 "INSTALL\r" -> 后面的字符串比较全部失败。除密码外本脚本的输入都不含
# 空格，所以统一删除是安全的；密码走 ask_password，不经过这里。
_norm() { printf '%s' "${1//[[:space:]]/}"; }

ask() {   # ask VAR "prompt" default
    local __var="$1" __prompt="$2" __def="${3-}" __ans
    while :; do
        if [[ -n $__def ]]; then
            printf '%s [%s]: ' "$__prompt" "$__def"
        else
            printf '%s: ' "$__prompt"
        fi
        IFS= read -r __ans || die "stdin closed"
        __ans=$(_norm "$__ans")
        __ans="${__ans:-$__def}"
        [[ -n $__ans ]] && break
        warn "value required"
    done
    printf '%s=%s\n' "$__prompt" "$__ans" >>"$LOG"
    printf -v "$__var" '%s' "$__ans"
}

ask_yn() {  # ask_yn "prompt" default(y|n)  -> 0 yes, 1 no
    local __p="$1" __d="${2:-n}" __a
    while :; do
        printf '%s [%s]: ' "$__p" "$__d"
        IFS= read -r __a || die "stdin closed"
        __a=$(_norm "$__a")
        __a="${__a:-$__d}"
        case "${__a,,}" in
            y|yes) printf '%s=y\n' "$__p" >>"$LOG"; return 0 ;;
            n|no)  printf '%s=n\n' "$__p" >>"$LOG"; return 1 ;;
            *) warn "answer y or n" ;;
        esac
    done
}

ask_password() {  # ask_password VAR "label"
    local __var="$1" __p="$2" __a __b
    while :; do
        printf '%s: ' "$__p"
        IFS= read -rs __a || die "stdin closed"
        printf '\n'
        if [[ -z $__a ]]; then warn "empty password, try again"; continue; fi
        printf 'repeat: '
        IFS= read -rs __b || die "stdin closed"
        printf '\n'
        [[ $__a == "$__b" ]] && break
        warn "passwords do not match, try again"
    done
    printf -v "$__var" '%s' "$__a"
}

# ------------------------------------------------------------------------------
# pacman 下载调优
# ------------------------------------------------------------------------------
# archiso 的 pacman 默认「10 秒收不到数据就判该镜像超时」。碰上慢镜像（非教育网连
# USTC 很常见）会让整笔事务回滚，前面已经下完的包全部白费 —— 看起来像「下载失败」，
# 实际只是等得不够久。DisableDownloadTimeout 让慢镜像有机会下完。
_pacman_relax() {
    local conf=/etc/pacman.conf
    [[ -f $conf ]] || return 0
    grep -qx 'DisableDownloadTimeout' "$conf" ||
        sed -i '/^\[options\]/a DisableDownloadTimeout' "$conf"
    grep -qE '^#?ParallelDownloads' "$conf" &&
        sed -i -E 's/^#?ParallelDownloads.*/ParallelDownloads = 2/' "$conf"
    return 0
}

# 只留一个镜像：多镜像时 pacman 会逐个试错，慢的那几个各耗 10 秒，反而更慢。
_mirror_pin() {  # _mirror_pin <host>
    printf 'Server = https://%s/archlinux/$repo/os/$arch\n' "$1" >/etc/pacman.d/mirrorlist
}

part_path() {  # part_path <disk> <n>  -> /dev/nvme0n1p1 or /dev/sda1
    if [[ $1 =~ [0-9]$ ]]; then
        printf '%sp%s\n' "$1" "$2"
    else
        printf '%s%s\n' "$1" "$2"
    fi
}

# ------------------------------------------------------------------------------
# 0. 前置检查
# ------------------------------------------------------------------------------
step "Preflight"

[[ $EUID -eq 0 ]] || die "run as root (you should be root in the live ISO)"
[[ -d /run/archiso ]] || warn "not an archiso environment? continuing anyway"

if [[ ! -d /sys/firmware/efi ]]; then
    die "booted in BIOS/legacy mode. This script only supports UEFI (reboot the ISO in UEFI mode)."
fi
if [[ -r /sys/firmware/efi/fw_platform_size ]]; then
    [[ "$(cat /sys/firmware/efi/fw_platform_size)" == 64 ]] || die "32-bit UEFI is not supported"
fi
ok "UEFI x64"

for c in sgdisk mkfs.fat mkfs.btrfs pacstrap genfstab arch-chroot; do
    command -v "$c" >/dev/null || die "missing command: $c"
done

# 上次跑到一半留下的挂载（pacstrap 失败最常见）。不先卸掉的话：sgdisk 会在
# 挂载中的设备上重建分区表，格式化阶段又会因为 /mnt 仍是挂载点而中止。
if mountpoint -q "$MNT"; then
    warn "$MNT is still mounted -- leftover from a previous run"
    ask_yn "Unmount it now (umount -R $MNT) and continue?" y || die "unmount $MNT first, then rerun"
    run umount -R "$MNT" || die "could not unmount $MNT"
    ok "$MNT unmounted"
fi

# 扩大 cowspace：pacstrap 的包缓存写在 live 的 overlay 里，默认大小容易写满
if findmnt -n /run/archiso/cowspace >/dev/null 2>&1; then
    run mount -o remount,size=4G /run/archiso/cowspace || warn "could not enlarge cowspace"
    ok "cowspace enlarged to 4G"
fi

# 网络
if ! curl -fsS -m 8 -o /dev/null https://archlinux.org/; then
    die "no internet. Connect first (wired: automatic; wifi: iwctl then 'station wlan0 connect <SSID>')"
fi
ok "internet reachable"

run timedatectl set-ntp true || warn "could not enable NTP"

# 镜像源：失败就保留 ISO 自带的。先写临时文件，避免 timeout 把 mirrorlist 截成空文件
if command -v reflector >/dev/null; then
    say "Ranking mirrors (up to ~3 min)..."
    if timeout 180 reflector -p https -a 12 -c cn --sort rate --save /tmp/mirrorlist.new >>"$LOG" 2>&1 \
        && [[ -s /tmp/mirrorlist.new ]]; then
        cp /tmp/mirrorlist.new /etc/pacman.d/mirrorlist
        ok "mirrorlist updated"
    else
        warn "reflector failed, keeping the ISO mirrorlist"
    fi
    rm -f /tmp/mirrorlist.new
fi

# 让慢镜像能下完，而不是 10 秒没数据就整笔回滚
_pacman_relax
run pacman -Sy --noconfirm

# ------------------------------------------------------------------------------
# 1. 收集配置
# ------------------------------------------------------------------------------
step "Target disk"

ISO_DISK=""
_iso_src="$(findmnt -n -o SOURCE /run/archiso/bootmnt 2>/dev/null || true)"
if [[ -n $_iso_src ]]; then
    _pk="$(lsblk -no PKNAME "$_iso_src" 2>/dev/null | head -n1 || true)"
    ISO_DISK="${_pk:+/dev/$_pk}"
    [[ -n $ISO_DISK ]] || ISO_DISK="$_iso_src"
    if [[ -n $ISO_DISK && $ISO_DISK != "$_iso_src" ]]; then
        say "Live medium: $_iso_src (disk $ISO_DISK) — excluded from the list"
    else
        say "Live medium: $_iso_src — excluded from the list"
    fi
fi

_cand=(); _desc=()
while read -r _name _size _model; do
    [[ -n $_name ]] || continue
    [[ $_name == "$ISO_DISK" ]] && continue
    _cand+=("$_name")
    _desc+=("$(printf '%-14s %8s  %s' "$_name" "$_size" "$_model")")
done < <(lsblk -dpno NAME,SIZE,MODEL | grep -vE '^/dev/(loop|zram|sr|ram)' || true)

((${#_cand[@]})) || die "no usable disk found"

say ""
for i in "${!_cand[@]}"; do
    printf '  %d) %s\n' "$((i + 1))" "${_desc[i]}"
done
while :; do
    printf 'Select disk 1-%d: ' "${#_cand[@]}"
    IFS= read -r _a || die "stdin closed"
    _a=$(_norm "$_a")
    if [[ $_a =~ ^[0-9]+$ ]] && ((_a >= 1 && _a <= ${#_cand[@]})); then
        DISK="${_cand[_a - 1]}"
        break
    fi
    warn "invalid choice"
done
# -d (--nodeps) 必须加：lsblk <disk> 默认连子设备（分区）一起列出来，
# 盘上已有分区时会输出 "disk\npart\npart"，$(...) 得到多行，永远不等于 "disk"。
# 第一次跑是全新空盘所以只有一行，第二次跑（盘上留着上次的 sda1/sda2）就误判。
_dtype=$(lsblk -dno TYPE "$DISK" 2>/dev/null | head -n1 || true)
[[ $_dtype == disk ]] || die "$DISK is not a whole disk (type: ${_dtype:-unknown})"
printf 'DISK=%s\n' "$DISK" >>"$LOG"
ok "target: $DISK"

step "Partitioning"

say ""
say "  1) Wipe $DISK and auto-partition (512M ESP + rest btrfs)"
say "     All data on this disk is destroyed. Windows on it would be gone."
say "  2) Use existing partitions (pick ESP and root yourself; nothing is wiped)"
say ""
PART_MODE=""
while [[ -z $PART_MODE ]]; do
    printf 'Choose 1-2 [1]: '
    IFS= read -r _a || die "stdin closed"
    _a=$(_norm "$_a")
    case "${_a:-1}" in
        1) PART_MODE=wipe ;;
        2) PART_MODE=existing ;;
        *) warn "invalid choice" ;;
    esac
done
printf 'PART_MODE=%s\n' "$PART_MODE" >>"$LOG"

if [[ $PART_MODE == wipe ]]; then
    say ""
    say "Everything on $DISK will be erased:"
    lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "$DISK" | sed 's/^/    /'
    say ""
    printf 'Type the device name (%s) to confirm: ' "$DISK"
    IFS= read -r _a || die "stdin closed"
    _a=$(_norm "$_a")
    printf 'wipe-confirm: %q\n' "$_a" >>"$LOG"
    [[ $_a == "$DISK" ]] || die "confirmation failed, nothing was changed"

    run sgdisk --zap-all "$DISK"
    run sgdisk --new=1:0:+512M --typecode=1:EF00 --change-name=1:EFI "$DISK"
    run sgdisk --new=2:0:0 --typecode=2:8300 --change-name=2:arch "$DISK"
    run partprobe "$DISK"
    udevadm settle

    ESP="$(part_path "$DISK" 1)"
    ROOT="$(part_path "$DISK" 2)"
    for _try in {1..20}; do
        [[ -b $ESP && -b $ROOT ]] && break
        sleep 0.5
        udevadm settle
    done
    [[ -b $ESP && -b $ROOT ]] || die "partitions did not appear ($ESP / $ROOT)"

    FORMAT_ESP=1
    FORMAT_ROOT=1
    CREATE_SUBVOLS=1
else
    say ""
    lsblk -pno NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "$DISK" | sed 's/^/  /'
    say ""
    while :; do
        ask ESP "ESP partition device (e.g. $(part_path "$DISK" 1))" ""
        [[ -b $ESP ]] && break
        warn "not a block device: $ESP"
    done
    while :; do
        ask ROOT "Root partition device (btrfs)" ""
        [[ -b $ROOT ]] && break
        warn "not a block device: $ROOT"
    done
    _rootfs=$(lsblk -dno FSTYPE "$ROOT" 2>/dev/null | head -n1 || true)
    [[ $_rootfs == btrfs ]] || die "$ROOT is not btrfs (fstype: ${_rootfs:-unknown})"
    [[ $ESP != "$ROOT" ]] || die "ESP and root must differ"

    FORMAT_ESP=0; FORMAT_ROOT=0; CREATE_SUBVOLS=0
    ask_yn "Format the ESP ($ESP) as FAT32? (wipes everything on it)" n && FORMAT_ESP=1
    ask_yn "Format the root partition ($ROOT) as btrfs? (wipes everything on it)" n && FORMAT_ROOT=1
    if [[ $FORMAT_ROOT == 0 ]]; then
        _subvols="$(btrfs subvolume list "$ROOT" 2>/dev/null || true)"
        say ""
        say "Existing subvolumes on $ROOT:"
        printf '%s\n' "$_subvols" | sed 's/^/    /'
        for sv in @ @home; do
            grep -qE "path ${sv}\$" <<<"$_subvols" \
                || die "subvolume $sv not found on $ROOT (format it or create it first)"
        done
        ask_yn "Reuse these subvolumes as-is?" y || die "aborted"
    else
        CREATE_SUBVOLS=1
    fi
fi

step "Swap"

say "The guide recommends: RAM >= 16G and no hibernation -> skip disk swap, use ZRAM only."
say "RAM on this machine: $(awk '/MemTotal/{printf "%.1f GB", $2/1024/1024}' /proc/meminfo)"
say ""

WANT_SWAPFILE=0
if ask_yn "Create a disk swapfile (requires an extra @swap subvolume)?" n; then
    WANT_SWAPFILE=1
fi

SWAP_SIZE=""
HIBERNATE=0
if [[ $WANT_SWAPFILE == 1 ]]; then
    if ask_yn "Will you use hibernation (suspend-to-disk)?" n; then HIBERNATE=1; fi
    if [[ $HIBERNATE == 1 ]]; then
        say "Hibernate needs swapfile >= RAM (e.g. 16G RAM -> 20G)."
        ask SWAP_SIZE "Swapfile size in GB" "20"
    else
        ask SWAP_SIZE "Swapfile size in GB" "4"
    fi
    [[ $SWAP_SIZE =~ ^[0-9]+$ ]] || die "swap size must be an integer (GB)"
fi

step "Packages"

if grep -q GenuineIntel /proc/cpuinfo; then _ucode_default=intel-ucode; else _ucode_default=amd-ucode; fi
say "CPU microcode: $_ucode_default detected"
UCODE=""
while :; do
    ask UCODE "Microcode package (intel-ucode / amd-ucode / none)" "$_ucode_default"
    case "$UCODE" in
        intel-ucode|amd-ucode) break ;;
        none|"") UCODE=""; break ;;
        *) warn "pick intel-ucode, amd-ucode or none" ;;
    esac
done

KERNEL=""
while :; do
    ask KERNEL "Kernel (linux / linux-lts)" "linux"
    [[ $KERNEL == linux || $KERNEL == linux-lts ]] && break
    warn "pick linux or linux-lts"
done

EDITOR_PKG=""
while :; do
    ask EDITOR_PKG "Editor (vim / nano / neovim)" "vim"
    [[ $EDITOR_PKG == vim || $EDITOR_PKG == nano || $EDITOR_PKG == neovim ]] && break
    warn "pick vim, nano or neovim"
done

DUALBOOT=0
say ""
say "os-prober + fuse3 are only needed to put Windows in the GRUB menu."
ask_yn "Install os-prober (dual boot with Windows)?" n && DUALBOOT=1

REMOVABLE=0
say ""
say "A removable fallback boot entry (EFI/BOOT/BOOTX64.EFI) helps when the NVRAM entry"
say "gets cleared (MSI boards, firmware updates) or when the disk is a portable drive."
ask_yn "Install the removable fallback boot entry?" n && REMOVABLE=1

step "System identity"

ask TZ "Timezone" "Asia/Shanghai"
[[ -f /usr/share/zoneinfo/$TZ ]] || die "unknown timezone: $TZ"

ask HOSTNAME "Hostname" "archlinux"
[[ $HOSTNAME =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*$ ]] || die "invalid hostname"

while :; do
    ask_password ROOT_PW "Root password"
    break
done

USERNAME=""
USER_PW=""
if ask_yn "Create a normal user (with wheel/sudo)?" y; then
    while :; do
        ask USERNAME "Username" ""
        [[ $USERNAME =~ ^[a-z_][a-z0-9_-]*$ ]] || { warn "lowercase letters, digits, _ and - only"; continue; }
        break
    done
    ask_password USER_PW "Password for $USERNAME"
fi

IWD=0
say ""
say "NetworkManager's wifi backend defaults to wpa_supplicant; iwd is more modern but"
say "breaks on some cards."
ask_yn "Switch the wifi backend to iwd?" n && IWD=1

# SSH 放在安装阶段而不是 prep-desktop 阶段：装完重启后手里只有 TTY，没有 scp/sftp
# 就没法把 prep-desktop.sh 之类的东西传进来（VMware 里还得靠共享文件夹或再挂一次 ISO）。
# sshd 装进 chroot、enable 掉，重启后随 NetworkManager 一起起来，第一次启动就能连。
# 需要普通用户：root 登录默认关掉，没有普通用户的话 sshd 谁都不让进。
ENABLE_SSH=0
SSH_PORT=22
SSH_ROOT_LOGIN=no
SSH_PASS_AUTH=yes
if [[ -n $USERNAME ]]; then
    say ""
    say "SSH lets you finish the setup from another machine instead of sitting at the TTY --"
    say "e.g. scp the next script in, or just keep a shell open while you install the DE."
    ask_yn "Enable the SSH server (starts on boot)?" y && ENABLE_SSH=1
    if [[ $ENABLE_SSH == 1 ]]; then
        while :; do
            ask SSH_PORT "  SSH port" "22"
            if [[ $SSH_PORT =~ ^[0-9]+$ ]] && ((SSH_PORT >= 1 && SSH_PORT <= 65535)); then
                break
            fi
            warn "port must be 1-65535"
        done
        if ask_yn "  allow root to log in over SSH?" n; then SSH_ROOT_LOGIN=yes; fi
        if ! ask_yn "  allow password authentication?" y; then SSH_PASS_AUTH=no; fi
        if [[ $SSH_PASS_AUTH == no ]]; then
            # 全新系统上还没有任何公钥，关掉密码 = 谁都进不来（包括你自己）
            warn "password auth off: nobody can log in until a key is in ~/.ssh/authorized_keys"
        fi
    fi
else
    warn "no normal user created -- skipping the SSH server (root login stays disabled)"
fi

# ZRAM 大小按物理内存分档（zram-fraction = 占物理内存比例）：
#   < 16G  -> 1.0   小内存机器给满，避免真的被 OOM 打死
#   16-32G -> 0.75  中间档按比例插值
#   >= 32G -> 0.5   大内存给一半已绰绰有余，留足物理内存安全红线
# GB 数四舍五入，否则标称 16G 的机器 MemTotal ~15.7G 会误落到 1.0 档。
_ZRAM_MEM_MB=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo || true)
_ZRAM_MEM_MB=${_ZRAM_MEM_MB:-16384}
_ZRAM_MEM_GB=$(((_ZRAM_MEM_MB + 512) / 1024))
if ((_ZRAM_MEM_GB < 16)); then
    ZRAM_FRACTION=1.0
elif ((_ZRAM_MEM_GB < 32)); then
    ZRAM_FRACTION=0.75
else
    ZRAM_FRACTION=0.5
fi

# ------------------------------------------------------------------------------
# 2. 汇总确认
# ------------------------------------------------------------------------------
step "Summary"

say "  disk            : $DISK ($PART_MODE)"
say "  esp             : $ESP$([[ $FORMAT_ESP == 1 ]] && echo ' (will be formatted)')"
say "  root            : $ROOT$([[ $FORMAT_ROOT == 1 ]] && echo ' (will be formatted)')"
say "  subvolumes      : @ @home$([[ $WANT_SWAPFILE == 1 ]] && echo ' @swap')"
say "  swapfile        : $([[ $WANT_SWAPFILE == 1 ]] && echo "${SWAP_SIZE}G$( [[ $HIBERNATE == 1 ]] && echo ', hibernation')" || echo 'none, ZRAM only')"
say "  kernel / ucode  : $KERNEL / ${UCODE:-none}"
say "  editor          : $EDITOR_PKG"
say "  bootloader      : GRUB (efi dir /efi, bootloader-id ARCH$([[ $REMOVABLE == 1 ]] && echo ', removable entry'))"
say "  os-prober       : $([[ $DUALBOOT == 1 ]] && echo yes || echo no)"
say "  timezone        : $TZ"
say "  hostname        : $HOSTNAME"
say "  user            : ${USERNAME:-<none>}"
if [[ $ENABLE_SSH == 1 ]]; then
    say "  sshd            : port $SSH_PORT, root=$SSH_ROOT_LOGIN, password=$SSH_PASS_AUTH"
else
    say "  sshd            : skip"
fi
_ZRAM_SHOW=$(awk -v g="$_ZRAM_MEM_GB" -v f="$ZRAM_FRACTION" 'BEGIN{printf "%.1f", g*f}')
say "  zram            : ${ZRAM_FRACTION} x ${_ZRAM_MEM_GB}G RAM = ${_ZRAM_SHOW}G (zstd, zswap disabled)"
say "  oom guard       : earlyoom -m 10 (protect session, prefer browsers)"
say ""
while :; do
    printf 'Type INSTALL to start (anything else aborts): '
    IFS= read -r _a || die "stdin closed"
    _a=$(_norm "$_a")
    printf 'install-confirm: %q\n' "$_a" >>"$LOG"
    if [[ -z $_a ]]; then
        # 空回车不算「别的答案」，只是没敲进去 —— 给一次重来的机会，否则一路回车
        # 过来的人会莫名其妙被中止，且屏幕上没有任何提示说明原因。
        warn "empty input -- type INSTALL to start, or Ctrl-C to quit"
        continue
    fi
    if [[ ${_a^^} == INSTALL ]]; then
        break
    fi
    die "aborted by user"
done

# ------------------------------------------------------------------------------
# 3. 格式化 / 子卷 / 挂载
# ------------------------------------------------------------------------------
step "Formatting"

# 这一步必须放在 mkfs 之前：对已挂载的设备跑 mkfs.btrfs 会被拒绝，
# mkfs.fat 则可能把正在用的 ESP 直接覆盖。重跑安装器时最容易踩到。
if mountpoint -q "$MNT"; then
    die "$MNT is already a mountpoint. Unmount it first (umount -R $MNT)."
fi

if [[ $FORMAT_ESP == 1 ]]; then
    umount "$ESP" 2>/dev/null || true
    run mkfs.fat -F 32 -n EFI "$ESP"
fi
if [[ $FORMAT_ROOT == 1 ]]; then
    umount "$ROOT" 2>/dev/null || true
    run mkfs.btrfs -f -L arch "$ROOT"
fi

step "Subvolumes"

if [[ $CREATE_SUBVOLS == 1 ]]; then
    run mount -t btrfs "$ROOT" "$MNT"
    for sv in @ @home; do
        if [[ -d $MNT/$sv ]]; then
            ok "subvolume $sv already exists"
        else
            run btrfs subvolume create "$MNT/$sv"
        fi
    done
    if [[ $WANT_SWAPFILE == 1 && ! -d $MNT/@swap ]]; then
        run btrfs subvolume create "$MNT/@swap"
    fi
    run umount "$MNT"
fi

step "Mounting"

run mount -t btrfs -o subvol=/@,compress=zstd "$ROOT" "$MNT"
run mount --mkdir -t btrfs -o subvol=/@home,compress=zstd "$ROOT" "$MNT/home"
if [[ $WANT_SWAPFILE == 1 ]]; then
    run mount --mkdir -t btrfs -o subvol=/@swap,compress=zstd "$ROOT" "$MNT/swap"
fi
run mount --mkdir "$ESP" "$MNT/efi"

step "Installing base system"

PKGS=(base "$KERNEL" linux-firmware btrfs-progs networkmanager "$EDITOR_PKG" sudo)
[[ -n $UCODE ]] && PKGS+=("$UCODE")

# 失败重试，三级递进：原样 → 关超时+降并行 → 换单镜像。
# 网络抖动不该让人从抹盘重来，而抹盘之后重跑也不过是再下一次 700MB。
_installed=0
for _attempt in 1 2 3; do
    if [[ $_attempt == 1 ]]; then
        run pacstrap -K "$MNT" "${PKGS[@]}" && { _installed=1; break; }
    else
        # 重试不再带 -K：keyring 第一次已经初始化过，重建纯属浪费
        run pacstrap "$MNT" "${PKGS[@]}" && { _installed=1; break; }
    fi
    warn "pacstrap attempt $_attempt failed"
    rm -f "$MNT/var/lib/pacman/db.lck"
    case $_attempt in
        1) _pacman_relax
           warn "retrying: no download timeout, ParallelDownloads=2" ;;
        2) _mirror_pin mirrors.tuna.tsinghua.edu.cn
           warn "retrying: single mirror (TUNA)" ;;
    esac
done
((_installed)) || die "pacstrap failed 3 times -- network or mirror problem. Try: reflector --latest 20 --protocol https --sort rate --save /etc/pacman.d/mirrorlist"

if [[ $WANT_SWAPFILE == 1 ]]; then
    step "Creating swapfile"
    if [[ -e $MNT/swap/swapfile ]]; then
        warn "$MNT/swap/swapfile already exists, reusing it"
    else
        run btrfs filesystem mkswapfile --size "${SWAP_SIZE}g" --uuid clear "$MNT/swap/swapfile"
    fi
    run swapon "$MNT/swap/swapfile" || warn "could not swapon the swapfile (fstab entry will still be written)"
fi

step "fstab"
genfstab -U "$MNT" >"$MNT/etc/fstab"
grep -v '^#' "$MNT/etc/fstab" | sed '/^$/d' | sed 's/^/  /' | tee -a "$LOG"
ok "fstab written"

# ------------------------------------------------------------------------------
# 4. chroot 内配置
# ------------------------------------------------------------------------------
RESUME_ARGS=""
if [[ $HIBERNATE == 1 ]]; then
    _uuid="$(blkid -s UUID -o value "$ROOT")"
    _off="$(btrfs inspect-internal map-swapfile -r "$MNT/swap/swapfile")"
    [[ -n $_uuid && -n $_off ]] || die "could not compute resume= parameters"
    RESUME_ARGS="resume=UUID=$_uuid resume_offset=$_off"
    ok "resume parameters: $RESUME_ARGS"
fi

if grep -q GenuineIntel /proc/cpuinfo; then WATCHDOG=iTCO_wdt; else WATCHDOG=sp5100_tco; fi

{
    printf 'TZ=%q\n' "$TZ"
    printf 'HOSTNAME=%q\n' "$HOSTNAME"
    printf 'ROOT_PW=%q\n' "$ROOT_PW"
    printf 'USERNAME=%q\n' "$USERNAME"
    printf 'USER_PW=%q\n' "$USER_PW"
    printf 'DUALBOOT=%q\n' "$DUALBOOT"
    printf 'REMOVABLE=%q\n' "$REMOVABLE"
    printf 'IWD=%q\n' "$IWD"
    printf 'HIBERNATE=%q\n' "$HIBERNATE"
    printf 'RESUME_ARGS=%q\n' "$RESUME_ARGS"
    printf 'WATCHDOG=%q\n' "$WATCHDOG"
    printf 'ZRAM_FRACTION=%q\n' "$ZRAM_FRACTION"
    printf 'ENABLE_SSH=%q\n' "$ENABLE_SSH"
    printf 'SSH_PORT=%q\n' "$SSH_PORT"
    printf 'SSH_ROOT_LOGIN=%q\n' "$SSH_ROOT_LOGIN"
    printf 'SSH_PASS_AUTH=%q\n' "$SSH_PASS_AUTH"
} >"$MNT/root/.install-vars"
chmod 600 "$MNT/root/.install-vars"

cat >"$MNT/root/.install-chroot.sh" <<'CHROOT'
#!/usr/bin/env bash
set -Eeuo pipefail
source /root/.install-vars
trap 'rm -f /root/.install-vars /root/.install-chroot.sh' EXIT

say()  { printf '[chroot] %s\n' "$*"; }
warn() { printf '[chroot] warn: %s\n' "$*" >&2; }

say "timezone $TZ"
ln -sf "/usr/share/zoneinfo/$TZ" /etc/localtime
hwclock --systohc

say "locale"
sed -i 's/^#\s*en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
sed -i 's/^#\s*zh_CN.UTF-8 UTF-8/zh_CN.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
printf 'LANG=en_US.UTF-8\n' > /etc/locale.conf

say "hostname / hosts"
printf '%s\n' "$HOSTNAME" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
EOF

say "root password"
printf 'root:%s\n' "$ROOT_PW" | chpasswd

if [[ -n $USERNAME ]]; then
    say "user $USERNAME"
    useradd -m -G wheel -s /bin/bash "$USERNAME"
    printf '%s:%s\n' "$USERNAME" "$USER_PW" | chpasswd
    printf '%%wheel ALL=(ALL:ALL) ALL\n' > /etc/sudoers.d/10-wheel
    chmod 440 /etc/sudoers.d/10-wheel
    visudo -cf /etc/sudoers >/dev/null
fi

say "bootloader packages"
pacman -S --noconfirm --needed grub efibootmgr
if [[ $DUALBOOT == 1 ]]; then
    pacman -S --noconfirm --needed os-prober fuse3
fi

say "grub-install"
NEED_EFIBOOTMGR=0
if ! grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id=ARCH; then
    warn "grub-install failed (probably NVRAM), retrying with --no-nvram"
    grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id=ARCH --no-nvram
    NEED_EFIBOOTMGR=1
fi
if [[ $REMOVABLE == 1 ]]; then
    grub-install --target=x86_64-efi --efi-directory=/efi --removable --no-nvram
fi

set_grub() {
    local k="$1" v="$2" tmp
    tmp="$(mktemp)"
    awk -v k="$k" -v v="$v" '
        $0 ~ "^#?[ \t]*" k "=" { print k "=" v; found=1; next }
        { print }
        END { if (!found) print k "=" v }
    ' /etc/default/grub >"$tmp"
    cat "$tmp" > /etc/default/grub
    rm -f "$tmp"
}

say "grub defaults"
CMDLINE="loglevel=5 nowatchdog modprobe.blacklist=$WATCHDOG zswap.enabled=0"
if [[ -n $RESUME_ARGS ]]; then
    CMDLINE="$CMDLINE $RESUME_ARGS"
fi
set_grub GRUB_DEFAULT saved
set_grub GRUB_SAVEDEFAULT true
set_grub GRUB_DISABLE_OS_PROBER false
set_grub GRUB_CMDLINE_LINUX_DEFAULT "\"$CMDLINE\""

if [[ $HIBERNATE == 1 ]]; then
    say "resume hook"
    if ! grep -Eq '^HOOKS=.*\bresume\b' /etc/mkinitcpio.conf; then
        sed -i -E 's/^(HOOKS=\([^)]*)filesystems/\1resume filesystems/' /etc/mkinitcpio.conf
    fi
    mkinitcpio -P
fi

say "grub-mkconfig"
grub-mkconfig -o /boot/grub/grub.cfg
grub-editenv - set ok=1 || warn "grub-editenv failed (needs GRUB >= 2.14 on btrfs)"

say "zram"
pacman -S --noconfirm --needed zram-generator
cat > /etc/systemd/zram-generator.conf <<EOF
[zram0]
# 压缩算法：zstd 是性能与压缩率的最佳平衡
compression-algorithm = zstd
# ZRAM 大小 = 物理内存 x fraction（本机 $ZRAM_FRACTION x RAM）
zram-fraction = $ZRAM_FRACTION
# 必须解除默认的 4096MB 上限，否则大内存机器只会分到 4G
max-zram-size = none
# 优先级高于磁盘 swap（默认负数），内核优先使用 zram
swap-priority = 100
EOF

# earlyoom：zram 是内存压缩出来的，写满后不像磁盘 swap 那样先卡住给你反应时间，
# 而是直接触发内核 OOM killer（可能正好挑中 niri 或桌面壳）。earlyoom 在内存见底前
# 按 oom_score 主动杀进程：先牺牲浏览器，保住会话、桌面和正在跑的 pacman。
say "earlyoom"
pacman -S --noconfirm --needed earlyoom

# 匹配的是 /proc/<pid>/comm：大小写敏感，内核截断到 15 字节
EO_AVOID='^(init|systemd.*|dbus.*|dbus-broker.*|polkitd|sddm.*|gdm.*|lightdm.*|greetd|dms-greeter|Xorg|Xwayland|kwin_.*|plasmashell|gnome-shell|gnome-session.*|niri|sway|hyprland|quickshell|dms|pacman|pamac.*|yay|paru|sshd)$'
EO_PREFER='^(firefox|firefox-bin|chromium|chrome|brave|vivaldi.*|opera|microsoft-edge.*)$'

# 只写 -m 不写 -s：earlyoom 的 -m 与 -s 是"且"关系，两个都满足才动手。
# 本机 zram 是唯一 swap，等它剩余也低于阈值才杀，等于把介入时机推到临界点之后。
# 内存可用率才是唯一有意义的指标，-s 会在装了硬盘 swapfile 时再按需加回。
EO_ARGS="-m 10 -r 60"

_eo_rc=0
printf '' | grep -Eq "$EO_AVOID" || _eo_rc=$?
if ((_eo_rc > 1)); then
    warn "avoid regex is invalid, falling back to defaults"
    EO_AVOID=""
fi
_eo_rc=0
printf '' | grep -Eq "$EO_PREFER" || _eo_rc=$?
if ((_eo_rc > 1)); then
    warn "prefer regex is invalid, falling back to defaults"
    EO_PREFER=""
fi
if [[ -n $EO_AVOID ]]; then EO_ARGS="$EO_ARGS --avoid $EO_AVOID"; fi
if [[ -n $EO_PREFER ]]; then EO_ARGS="$EO_ARGS --prefer $EO_PREFER"; fi

mkdir -p /etc/default
{
    printf '# earlyoom 参数。systemd 只按空格切分，正则里不要加引号\n'
    printf '# 触发线：可用内存 < 10%%（-m 10）\n'
    printf '# avoid：会话 / 桌面壳 / 包管理器，被杀会丢会话或让更新中断\n'
    printf '# prefer：浏览器最先牺牲——占用最大，且都能恢复标签页\n'
    printf 'EARLYOOM_ARGS="%s"\n' "$EO_ARGS"
} > /etc/default/earlyoom

systemctl enable earlyoom || warn "could not enable earlyoom"

say "services"
systemctl enable NetworkManager
systemctl enable systemd-timesyncd || warn "could not enable systemd-timesyncd"

if [[ $IWD == 1 ]]; then
    pacman -S --noconfirm --needed iwd
    mkdir -p /etc/NetworkManager/conf.d
    printf '[device]\nwifi.backend=iwd\n' > /etc/NetworkManager/conf.d/iwd.conf
    systemctl enable iwd
fi

# SSH：在这里就装好并 enable，重启后随 NetworkManager 一起起来，第一次启动就能连。
# 同一个 drop-in 文件名也被 prep-desktop.sh 使用 —— 那边是「再改一遍」，不是第二份配置。
if [[ $ENABLE_SSH == 1 ]]; then
    say "sshd (port $SSH_PORT)"
    pacman -S --noconfirm --needed openssh
    mkdir -p /run/sshd /etc/ssh/sshd_config.d

    # 用 drop-in 而不是改主配置：Arch 的 sshd_config 第一行就是
    #   Include /etc/ssh/sshd_config.d/*.conf
    # 而 sshd 是「先读到的值生效」，所以 drop-in 压过主文件后面的默认值；回滚只删一个文件。
    # 不写 UsePAM：Arch 默认就对，动了反而可能让密码登录失效。
    cat > /etc/ssh/sshd_config.d/10-arch-ssh.conf <<EOF
# written by arch-install.sh -- prep-desktop.sh rewrites this same file
Port $SSH_PORT
PermitRootLogin $SSH_ROOT_LOGIN
PasswordAuthentication $SSH_PASS_AUTH
EOF

    # openssh 的 post_install 已经跑过一次 ssh-keygen -A，这里兜一次：
    # 缺 host key 时 sshd 连配置都过不了校验，重启后服务直接失败。
    ssh-keygen -A

    # 先验证再 enable，别把一个起不来的服务留在系统里
    if ! sshd -t; then
        warn "sshd config invalid -- removing the drop-in, keeping stock defaults"
        rm -f /etc/ssh/sshd_config.d/10-arch-ssh.conf
        sshd -t || warn "sshd still fails its config check; inspect /etc/ssh/sshd_config"
    fi

    # 生效值自检。Arch 的 openssh 把默认值放在 sshd_config.d/99-archlinux.conf 里，
    # 同样写了 Port / PermitRootLogin / PasswordAuthentication。sshd 的规则是「同名项
    # 取第一次读到的值」，主配置第 1 行就是 Include，drop-in 按字典序读 —— 所以
    # 10- 排在 99- 前面，我们赢。但这依赖排序，也依赖主配置真有那行 Include，
    # 一旦不成立，自定义端口（比如 2222）会静默失效、连都连不上。所以用 sshd -T
    # 把 sshd 自己解析出来的最终值读回来对一遍。
    _eff="$(sshd -T 2>/dev/null || true)"
    _chk() {  # _chk <key> <want>
        local _got
        _got="$(printf '%s\n' "$_eff" | awk -v k="$1" '$1==k{print $2; exit}')"
        if [[ -z $_got ]]; then
            warn "sshd -T did not report '$1'"
        elif [[ $_got != "$2" ]]; then
            warn "sshd reports $1=$_got, expected $2 -- a later drop-in is winning"
        else
            say "  $1=$_got"
        fi
    }
    _chk port "$SSH_PORT"
    _chk permitrootlogin "$SSH_ROOT_LOGIN"
    _chk passwordauthentication "$SSH_PASS_AUTH"

    systemctl enable sshd

    # 预建 ~/.ssh（700 + 正确属主）：之后贴公钥不用先 mkdir + chmod，
    # 也不会因为权限不对被 sshd 静默拒绝（那是很难查的失败）
    if [[ -n $USERNAME ]]; then
        install -d -m 700 -o "$USERNAME" -g "$(id -gn "$USERNAME")" "/home/$USERNAME/.ssh" \
            || warn "could not pre-create /home/$USERNAME/.ssh"
    fi
fi

if [[ $NEED_EFIBOOTMGR == 1 ]]; then
    warn "GRUB was installed without an NVRAM entry. After reboot run:"
    warn "  efibootmgr --create --disk /dev/<disk> --part 1 --label ARCH --loader '\EFI\ARCH\grubx64.efi'"
fi

say "done"
CHROOT

chmod +x "$MNT/root/.install-chroot.sh"

step "Configuring the new system (arch-chroot)"
arch-chroot "$MNT" /bin/bash /root/.install-chroot.sh 2>&1 | tee -a "$LOG"

rm -f "$MNT/root/.install-vars" "$MNT/root/.install-chroot.sh"

# ------------------------------------------------------------------------------
# 5. 收尾
# ------------------------------------------------------------------------------
step "Unmounting"

if [[ $WANT_SWAPFILE == 1 ]]; then
    swapoff "$MNT/swap/swapfile" 2>/dev/null || true
fi
sync
run umount -R "$MNT"
ok "unmounted"

step "Done"

say ""
say "  Installed: Arch Linux ($KERNEL) on $ROOT"
say "  Log      : $LOG"
_ssh_hint=""
if [[ $ENABLE_SSH == 1 ]]; then
    say "  sshd     : enabled on port $SSH_PORT (root=$SSH_ROOT_LOGIN, password=$SSH_PASS_AUTH)"
    if [[ $SSH_PORT == 22 ]]; then
        _ssh_hint="ssh ${USERNAME}@<the box's ip>"
    else
        _ssh_hint="ssh -p $SSH_PORT ${USERNAME}@<the box's ip>"
    fi
fi
say ""
say "Next:"
say "  1. reboot, remove the USB stick, pick 'Arch Linux' in the firmware boot menu"
say "  2. log in as ${USERNAME:-root}, connect wifi with: nmtui"
if [[ $ENABLE_SSH == 1 ]]; then
    say "     sshd needs a working network: wired comes up by itself, wifi needs nmtui once"
    say "     find the address with: ip -4 addr show scope global"
    say "  3. from another machine: $_ssh_hint"
    say "     now you can scp prep-desktop.sh over instead of typing it at the console"
    say "  4. deploy your dotfiles / desktop environment as usual"
else
    say "  3. deploy your dotfiles / desktop environment as usual"
fi
say "     (this script installs a plain base system only: no DE, no WM, no browser)"
say ""
warn "ZRAM and zswap.enabled=0 take effect on the next boot."
warn "If the machine does not boot, boot the ISO again and chroot into $ROOT."

printf 'Reboot now? [y/N]: '
_a=""
IFS= read -r _a || true
_a=$(_norm "$_a")
case "${_a,,}" in
    y|yes) reboot ;;
    *) say "Not rebooting. Run 'reboot' when ready." ;;
esac
