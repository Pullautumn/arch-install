#!/usr/bin/env bash
# ==============================================================================
# prep-desktop.sh — 装完基础系统后、装桌面环境前的准备
#
# 独立脚本，无外部依赖：只用 pacman / systemctl / iproute2，不读任何仓库里的文件。
#
# 依据：SHORiN-KiWATA/Shorin-ArchLinux-Guide 的「安装桌面环境前的准备」章节
#   EDITOR → 32 位源(multilib) → archlinuxcn 源 → AUR 助手
#   → 字体 → 音视频(PipeWire) → 性能模式 → 蓝牙(可选) → Flatpak(可选)
#
# 前提：已经用 arch-install.sh（或手工）装好并重启进基础系统，普通用户可 sudo。
# 不覆盖：SSH、显卡驱动、桌面环境、dotfiles、LUKS、Secure Boot。
#
# 用法：
#   curl -fsSL https://raw.githubusercontent.com/Pullautumn/arch-install/main/prep-desktop.sh -o /tmp/pd.sh
#   bash /tmp/pd.sh
#
# 为什么输出全英文：TTY console 没有 CJK 字形，中文会是豆腐块（装了 noto-fonts-cjk 也不影响 console）。
# 每个可选步骤都会停下来问，默认值取 wiki 的推荐值，回车即为默认。
# 每一条都是幂等的：中途失败改好原因重跑即可，不用重装系统。
# ==============================================================================

set -Eeuo pipefail

LOG=/tmp/arch-prep.log
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
    printf 'Nothing was rolled back. Fix the cause and re-run — every step is idempotent.\n' >&2
    printf 'Full log: %s\n' "$LOG" >&2
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

# 命令执行：回显 + 落日志；配合 pipefail，失败会触发 ERR trap。
# 注意 stdin 不动：pacman 遇到冲突时还能在终端里问你。
run() {
    printf '%s+ %s%s\n' "$C_C" "$*" "$C_RST"
    printf '+ %s\n' "$*" >>"$LOG"
    "$@" 2>&1 | tee -a "$LOG"
}

# ------------------------------------------------------------------------------
# 交互函数
# ------------------------------------------------------------------------------
ask() {   # ask VAR "prompt" default
    local __var="$1" __prompt="$2" __def="${3-}" __ans
    while :; do
        if [[ -n $__def ]]; then
            printf '%s [%s]: ' "$__prompt" "$__def"
        else
            printf '%s: ' "$__prompt"
        fi
        IFS= read -r __ans || die "stdin closed"
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
        __a="${__a:-$__d}"
        case "${__a,,}" in
            y|yes) printf '%s=y\n' "$__p" >>"$LOG"; return 0 ;;
            n|no)  printf '%s=n\n' "$__p" >>"$LOG"; return 1 ;;
            *) warn "answer y or n" ;;
        esac
    done
}

# 在 KEY=VALUE 风格的文件里设一项（需要 root，内部走 sudo tee）。
# 有非注释的同名行就替换，否则追加 —— /etc/environment 是逐行解析、后者覆盖前者，
# 所以「追加」一定生效，不必先删旧的。
set_env_kv() {  # set_env_kv <abs-path> <KEY> <VALUE>
    local file="$1" key="$2" val="$3" tmp
    tmp="$(mktemp)"
    if grep -qE "^[[:space:]]*${key}=" "$file" 2>/dev/null; then
        awk -v k="$key" -v v="$val" '
            $0 ~ "^[ \t]*" k "=" { print k "=" v; next }
            { print }
        ' "$file" >"$tmp"
    else
        cat "$file" >"$tmp" 2>/dev/null || true
        printf '%s=%s\n' "$key" "$val" >>"$tmp"
    fi
    cat "$tmp" | sudo tee "$file" >/dev/null
    rm -f "$tmp"
}

# ------------------------------------------------------------------------------
# 0. 前置检查
# ------------------------------------------------------------------------------
step "Preflight"

if [[ $EUID -eq 0 ]]; then
    die "do not run as root. Log in as your normal user:
  pipewire runs as user units; running as root writes them in root's session instead."
fi

[[ -f /etc/arch-release ]] || die "this is not Arch Linux (/etc/arch-release missing)"
ok "Arch Linux"

if [[ -d /run/archiso ]]; then
    die "you are in the live ISO. Run arch-install.sh first, reboot into the new system, then run this."
fi

command -v sudo >/dev/null || die "sudo is missing. As root: pacman -S sudo"
sudo -v || die "sudo failed"
ok "sudo"

# base 里没有 curl / iputils，别假设它们存在
_net_ok=0
if command -v curl >/dev/null; then
    curl -fsS -m 8 -o /dev/null https://archlinux.org/ && _net_ok=1
elif command -v ping >/dev/null; then
    ping -c1 -W3 archlinux.org >/dev/null 2>&1 && _net_ok=1
else
    warn "neither curl nor ping is available, skipping the connectivity check"
    _net_ok=1
fi
(( _net_ok == 1 )) || die "no internet. Wired: automatic. Wifi: nmcli device wifi connect <SSID> --ask -a"
ok "internet reachable"

# sudo 保活：后面有 -Syu 和可能的 AUR 编译，默认 15 分钟的凭据会过期
( while true; do sudo -n true 2>/dev/null || true; sleep 50; kill -0 "$$" 2>/dev/null || exit; done ) &
KEEPALIVE_PID=$!
trap 'kill "$KEEPALIVE_PID" 2>/dev/null || true' EXIT

# 这个脚本的每一条 sudo 都该属于某个普通用户；摘要里也要打印他的名字
FIRST_USER="$(awk -F: '$3 >= 1000 && $3 < 65534 { print $1; exit }' /etc/passwd)"
[[ -n $FIRST_USER ]] || die "no normal user (uid >= 1000). Create one first:
  useradd -mG wheel <name> && passwd <name>
then ensure /etc/sudoers has: %wheel ALL=(ALL:ALL) ALL"
ok "user: $FIRST_USER"

if ! grep -qE '^[[:space:]]*%wheel[[:space:]]+ALL=' /etc/sudoers /etc/sudoers.d/* 2>/dev/null; then
    warn "%wheel may not have sudo rights — verify with: sudo visudo"
fi

# ------------------------------------------------------------------------------
# 1. 收集配置
# ------------------------------------------------------------------------------
step "Options"

# 编辑器：wiki 那一节就是为这三个写的。优先选已经装了的，免得选完发现命令不存在。
EDITOR_BIN=""
for e in vim nvim nano; do
    if command -v "$e" >/dev/null; then EDITOR_BIN="$e"; break; fi
done
if [[ -n $EDITOR_BIN ]]; then
    ok "editor detected: $EDITOR_BIN"
else
    warn "none of vim/nvim/nano is installed"
    ask EDITOR_BIN "Editor to use as default" "vim"
fi

say ""
say "32-bit packages (multilib) are needed by Steam and by Wine / Windows apps."
ENABLE_MULTILIB=0
ask_yn "Enable the [multilib] repo?" y && ENABLE_MULTILIB=1

say ""
say "archlinuxcn is a community repo. Its mirrors are in China; if you are outside"
say "China pick the official server, otherwise downloads crawl."
CN_MIRROR=0
ask_yn "Use Chinese mirrors (USTC + TUNA) for archlinuxcn?" y && CN_MIRROR=1

say ""
say "An AUR helper builds AUR packages. Both come prebuilt from archlinuxcn,"
say "so nothing is compiled from source at this step."
AUR_HELPER="paru"
ask AUR_HELPER "AUR helper: paru / yay / both / none" "paru"
case "$AUR_HELPER" in
    paru|yay|both|none) ;;
    *) warn "unknown choice, using paru"; AUR_HELPER="paru" ;;
esac

say ""
say "Fonts: fontconfig (the index/fallback layer) + noto-fonts (latin) +"
say "noto-fonts-cjk (CJK) + emoji + JetBrains Mono Nerd."
INSTALL_FONTS=0
ask_yn "Install these fonts?" y && INSTALL_FONTS=1

say ""
say "Audio: PipeWire stack (pipewire / wireplumber / pulse+alsa+jack shims) plus"
say "SOF firmware for modern laptop codecs. Needed for sound and screen sharing."
INSTALL_AUDIO=0
ask_yn "Install PipeWire + audio firmware?" y && INSTALL_AUDIO=1

say ""
say "power-profiles-daemon provides the performance/balanced/powersave switch that"
say "desktop shells show in their battery menu. Do not add tlp / auto-cpufreq."
INSTALL_PPD=0
ask_yn "Install power-profiles-daemon?" y && INSTALL_PPD=1

say ""
INSTALL_BT=0
ask_yn "Install Bluetooth (bluez)?" n && INSTALL_BT=1

say ""
say "Flatpak is optional — handy when the repo/AUR package of an app is broken."
INSTALL_FLATPAK=0
ask_yn "Install Flatpak?" n && INSTALL_FLATPAK=1
FLATPAK_CN=0
if [[ $INSTALL_FLATPAK == 1 ]]; then
    if ask_yn "  point flathub at a Chinese mirror?" n; then FLATPAK_CN=1; fi
fi

# ------------------------------------------------------------------------------
# 2. Summary
# ------------------------------------------------------------------------------
step "Summary"

say "  user            : $FIRST_USER (sudo)"
say "  editor          : $EDITOR_BIN  (written to /etc/environment)"
if [[ $ENABLE_MULTILIB == 1 ]]; then say "  multilib        : yes"; else say "  multilib        : no"; fi
if [[ $CN_MIRROR == 1 ]]; then
    say "  archlinuxcn     : USTC + TUNA"
else
    say "  archlinuxcn     : official (repo.archlinuxcn.org)"
fi
say "  AUR helper      : $AUR_HELPER"
if [[ $INSTALL_FONTS == 1 ]]; then say "  fonts           : fontconfig + noto + cjk + emoji + jetbrains-mono-nerd"; else say "  fonts           : skip"; fi
if [[ $INSTALL_AUDIO == 1 ]]; then say "  audio           : pipewire + wireplumber + sof-firmware"; else say "  audio           : skip"; fi
if [[ $INSTALL_PPD == 1 ]]; then say "  power profiles  : power-profiles-daemon"; else say "  power profiles  : skip"; fi
if [[ $INSTALL_BT == 1 ]]; then say "  bluetooth       : bluez"; else say "  bluetooth       : skip"; fi
if [[ $INSTALL_FLATPAK == 1 ]]; then
    if [[ $FLATPAK_CN == 1 ]]; then say "  flatpak         : yes (CN mirror)"; else say "  flatpak         : yes"; fi
else
    say "  flatpak         : skip"
fi
say ""
say "Only packages get installed and a few config files get written."
say "/etc/pacman.conf is appended to (never rewritten)."
say ""
ask_yn "Proceed?" y || die "aborted by user"

# ------------------------------------------------------------------------------
# 3. 系统更新
# ------------------------------------------------------------------------------
# 先整体升级再动 pacman.conf：Arch 的「部分升级」正是文档里反复警告的坏状态 ——
# 只 -Sy 不 -Su，新库配旧二进制，症状是各种 symbol lookup error。
step "Full system upgrade"
run sudo pacman -Syu --noconfirm
ok "system up to date"

# ------------------------------------------------------------------------------
# 3a. multilib
# ------------------------------------------------------------------------------
if [[ $ENABLE_MULTILIB == 1 ]]; then
    step "multilib"

    if grep -qE '^\[multilib\]' /etc/pacman.conf; then
        ok "[multilib] already enabled"
    else
        sudo cp /etc/pacman.conf /tmp/pacman.conf.bak
        # 只放开 [multilib] 段头 + 紧跟它的那行 Include。
        # 不能全局替换 '^#Include' —— 上面还有 #[multilib-testing]，一起放开会把测试源带进来。
        awk '
            /^#\[multilib\]$/          { print "[multilib]"; want=1; next }
            want && /^#Include[ \t]*=/ { sub(/^#/, ""); print; want=0; next }
            { print }
        ' /etc/pacman.conf >/tmp/pacman.conf.new

        if ! grep -qE '^\[multilib\]' /tmp/pacman.conf.new; then
            warn "no '#[multilib]' line found — appending a section instead"
            printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' >>/tmp/pacman.conf.new
        fi
        cat /tmp/pacman.conf.new | sudo tee /etc/pacman.conf >/dev/null
        rm -f /tmp/pacman.conf.new
        ok "[multilib] enabled (backup: /tmp/pacman.conf.bak)"
    fi

    run sudo pacman -Sy --noconfirm
fi

# ------------------------------------------------------------------------------
# 3b. archlinuxcn
# ------------------------------------------------------------------------------
step "archlinuxcn"

if grep -qE '^\[archlinuxcn\]' /etc/pacman.conf; then
    ok "[archlinuxcn] already configured"
else
    {
        printf '\n[archlinuxcn]\n'
        if [[ $CN_MIRROR == 1 ]]; then
            printf 'Server = https://mirrors.ustc.edu.cn/archlinuxcn/$arch\n'
            printf 'Server = https://mirrors.tuna.tsinghua.edu.cn/archlinuxcn/$arch\n'
        else
            printf 'Server = https://repo.archlinuxcn.org/$arch\n'
        fi
    } | sudo tee -a /etc/pacman.conf >/dev/null
    ok "[archlinuxcn] added"
fi

# keyring 必须单独先装：没有它，archlinuxcn 里的包一律是「invalid or corrupted package」
run sudo pacman -Sy --noconfirm archlinuxcn-keyring
run sudo pacman -Syu --noconfirm
ok "archlinuxcn keyring installed"

# ------------------------------------------------------------------------------
# 3c. base-devel + AUR helper
# ------------------------------------------------------------------------------
step "Build tools + AUR helper"

run sudo pacman -S --needed --noconfirm base-devel
ok "base-devel"

case "$AUR_HELPER" in
    paru) run sudo pacman -S --needed --noconfirm paru ;;
    yay)  run sudo pacman -S --needed --noconfirm yay ;;
    both) run sudo pacman -S --needed --noconfirm paru yay ;;
    none) warn "skipped — you will have to use makepkg by hand for AUR packages" ;;
esac
if [[ $AUR_HELPER != none ]]; then ok "AUR helper: $AUR_HELPER"; fi

# ------------------------------------------------------------------------------
# 3d. 字体
# ------------------------------------------------------------------------------
if [[ $INSTALL_FONTS == 1 ]]; then
    step "Fonts"

    # fontconfig 必须显式装。noto-fonts 只「Provides: ttf-font」，并不依赖 fontconfig，
    # 所以只装这几个字体包的话，base 系统上依然没有 fc-cache / fc-list，也没有
    # /etc/fonts —— 字体文件躺在 /usr/share/fonts 里，但没有任何东西去索引它们。
    # 桌面环境后来会把它当依赖带进来，所以真机上几乎碰不到；纯 base 系统上就会
    # 「pacman 说装好了，fc-cache 却不存在」。fontconfig.hook（Pacman 装了字体包后
    # 自动刷缓存）也在这个包里。
    run sudo pacman -S --needed --noconfirm fontconfig \
        noto-fonts noto-fonts-cjk noto-fonts-emoji ttf-jetbrains-mono-nerd

    # 上面那个 hook 已经刷过一遍了，这一步是兜底（比如 hook 被跳过）。
    # 不能无条件调：命令不存在时 sudo 退出 1，pipefail + ERR trap 会把整个脚本带崩。
    if command -v fc-cache >/dev/null; then
        run sudo fc-cache -f
    else
        warn "fc-cache not found — skipping the cache rebuild (see: pacman -Q fontconfig)"
    fi
    ok "fonts installed (re-login for apps to pick them up)"
fi

# ------------------------------------------------------------------------------
# 3e. 音视频
# ------------------------------------------------------------------------------
if [[ $INSTALL_AUDIO == 1 ]]; then
    step "Audio (PipeWire)"

    run sudo pacman -S --needed --noconfirm sof-firmware alsa-ucm-conf alsa-firmware

    # pipewire-pulse 与 pulseaudio 冲突、pipewire-jack 与 jack2 冲突。
    # 新系统两个都没有，--noconfirm 直接过；之前手动装过的话这里会失败 ——
    # 不中断脚本，只提示手动处理，因为这个人可能确实想留着旧的那套。
    if ! run sudo pacman -S --needed --noconfirm \
            pipewire wireplumber pipewire-pulse pipewire-alsa pipewire-jack rtkit; then
        warn "PipeWire install failed — usually a pulseaudio / jack2 conflict."
        warn "Resolve by hand: sudo pacman -S pipewire wireplumber pipewire-pulse pipewire-alsa pipewire-jack rtkit"
    else
        # 这三个是 user unit，走当前登录会话的 user manager。
        # 纯 TTY / SSH 会话里 XDG_RUNTIME_DIR 可能没配好，先探测再降级成「只 enable」。
        if systemctl --user show-environment >/dev/null 2>&1; then
            run systemctl --user enable --now pipewire pipewire-pulse wireplumber
            ok "pipewire running in this session"
        else
            warn "no usable user systemd session here; enabling for next login"
            systemctl --user enable pipewire pipewire-pulse wireplumber 2>/dev/null \
                || warn "run after login: systemctl --user enable --now pipewire pipewire-pulse wireplumber"
        fi
    fi
fi

# ------------------------------------------------------------------------------
# 3f. 性能模式
# ------------------------------------------------------------------------------
if [[ $INSTALL_PPD == 1 ]]; then
    step "Power profiles"
    run sudo pacman -S --needed --noconfirm power-profiles-daemon
    run sudo systemctl enable --now power-profiles-daemon
    ok "power-profiles-daemon active (it conflicts with tlp / auto-cpufreq — don't add those)"
fi

# ------------------------------------------------------------------------------
# 3g. 蓝牙
# ------------------------------------------------------------------------------
if [[ $INSTALL_BT == 1 ]]; then
    step "Bluetooth"
    # bluez-utils 才提供 bluetoothctl；只装 bluez 会「服务起来了但没法配对」
    run sudo pacman -S --needed --noconfirm bluez bluez-utils
    run sudo systemctl enable --now bluetooth
    ok "bluetooth active — pair with: bluetoothctl"
fi

# ------------------------------------------------------------------------------
# 3h. Flatpak
# ------------------------------------------------------------------------------
if [[ $INSTALL_FLATPAK == 1 ]]; then
    step "Flatpak"
    run sudo pacman -S --needed --noconfirm flatpak
    if [[ $FLATPAK_CN == 1 ]]; then
        # remote-modify 要求 flathub 这个 remote 已经存在；flatpak 首次装完通常会带，
        # 没有的话先 remote-add 再改，别让整步失败。
        if ! sudo flatpak remote-modify flathub --url=https://mirrors.ustc.edu.cn/flathub 2>>"$LOG"; then
            warn "flathub remote missing — adding it first"
            sudo flatpak remote-add --if-not-exists flathub \
                https://dl.flathub.org/repo/flathub.flatpakrepo >>"$LOG" 2>&1 || true
            sudo flatpak remote-modify flathub --url=https://mirrors.ustc.edu.cn/flathub >>"$LOG" 2>&1 \
                || warn "could not switch flathub to the USTC mirror"
        fi
        ok "flathub -> USTC mirror"
    fi
    ok "flatpak installed"
fi

# ------------------------------------------------------------------------------
# 3i. EDITOR
# ------------------------------------------------------------------------------
step "Default editor"

if grep -qE "^[[:space:]]*EDITOR=${EDITOR_BIN}\$" /etc/environment 2>/dev/null; then
    ok "EDITOR=$EDITOR_BIN already set"
else
    set_env_kv /etc/environment EDITOR "$EDITOR_BIN"
    ok "EDITOR=$EDITOR_BIN written to /etc/environment (effective after re-login)"
fi

# ------------------------------------------------------------------------------
# 4. 收尾
# ------------------------------------------------------------------------------
step "Done"

say ""
say "  Log: $LOG"

say ""
say "Next:"
say "  1. re-login (or reboot) so EDITOR takes effect"
say "  2. install the graphics driver, then the desktop environment"
say ""
if ask_yn "Reboot now?" n; then
    say "rebooting..."
    sudo reboot
else
    say "Not rebooting. Run 'reboot' when ready."
fi
