# arch-install

把 [shorin 的 Arch Linux 安装文档](https://github.com/SHORiN-KiWATA/Shorin-ArchLinux-Guide/tree/main/wiki/archlinux)
脚本化成两个可以反复重跑的单文件脚本。**独立项目**，不依赖任何 dotfiles 仓库。

```
arch-install.sh    Live ISO 里跑：分区 → 格式化 → pacstrap → GRUB → ZRAM → sshd → 重启
prep-desktop.sh    重启后跑：软件源 → AUR 助手 → 字体 → 音视频 → 再装桌面
```

第一个装出一个干净的基础系统（能开机、能联网、能 `sudo`），第二个把它补到「能装桌面环境」的状态。

## 用法

### 1 · 装基础系统（Live ISO，UEFI 启动，root 身份）

```bash
curl -fsSL https://raw.githubusercontent.com/Pullautumn/arch-install/main/arch-install.sh -o /tmp/ai.sh
bash /tmp/ai.sh
```

### 2 · 重启进新系统后，以普通用户身份

```bash
curl -fsSL https://raw.githubusercontent.com/Pullautumn/arch-install/main/prep-desktop.sh -o /tmp/pd.sh
bash /tmp/pd.sh
```

不想联网取脚本就把文件拷进 U 盘，`bash /path/to/x.sh` 一样跑。

第 1 步开了 SSH（默认开）的话，第 2 步可以换个姿势：重启后先 `ip -4 addr show scope global` 看地址，然后在另一台机器上 `scp prep-desktop.sh <user>@<ip>:` 再 `ssh <user>@<ip> bash prep-desktop.sh`。

## arch-install.sh 做什么

```
前置检查   UEFI x64 / 网络 / NTP / 扩大 cowspace / reflector 选源
分区       sgdisk 抹盘重建（512M ESP + 剩余 btrfs），或复用现有分区
格式化     mkfs.fat -F 32 + mkfs.btrfs
子卷       @  @home  （可选 @swap）
挂载       /  /home  /efi  （compress=zstd），可选 /swap
pacstrap   base linux linux-firmware btrfs-progs networkmanager 编辑器 sudo (+ucode)
           失败自动重试 3 次：原样 → 关下载超时+降并行 → 换单镜像
swapfile   可选，btrfs filesystem mkswapfile
fstab      genfstab -U
chroot     时区 / locale / hostname / hosts / 密码 / 普通用户(wheel+sudoers.d)
           GRUB 装到 ESP + grub-mkconfig + grub-editenv
           ZRAM（按内存分档 zram-fraction + zstd + swap-priority=100，zswap.enabled=0）
           earlyoom（-m 10，保护会话/显示器/包管理器，优先杀浏览器）
           NetworkManager / systemd-timesyncd
           sshd（可选，装进 chroot 并 enable：重启后第一次启动就能 scp 往里传东西）
收尾       umount -R → 打印后续步骤 / SSH 连接命令 → 询问是否重启
```

## 会问你的可选点

| 问题 | 默认 | 备注 |
|---|---|---|
| 分区方式 | 1 抹盘重建 | 2 = 复用现有分区，先列子卷校验 `@`/`@home`，默认不格式化 |
| 建硬盘 swapfile | **n** | 选 y 才建 `@swap` 子卷 |
| 使用休眠？ | n | 选 y 才按容量表算大小，并加 `resume=UUID=… resume_offset=…`、给 `HOOKS` 插 `resume`、`mkinitcpio -P` |
| microcode | 按 CPU 探测 | intel-ucode / amd-ucode / none |
| 内核 | linux | 可选 linux-lts |
| 编辑器 | vim | vim / nano / neovim |
| os-prober | n | 只有双系统要在 GRUB 里列 Windows 才需要 |
| 回退引导 `EFI/BOOT/BOOTX64.EFI` | n | 微星主板、会重置固件、移动硬盘装系统时才需要 |
| 创建普通用户 | y | 自动进 `wheel` + `/etc/sudoers.d/10-wheel` |
| 开启 SSH | **y** | 装 sshd 并 enable，重启后就能从另一台机器连进来传文件 |
| SSH 端口 / 允许 root / 允许密码 | 22 / n / y | 没建普通用户时整段跳过（root 登录是关的，留着也没人能进） |
| wifi 后端换 iwd | n | 部分网卡换 iwd 会连不上 |

ZRAM 不问，按物理内存自动分档，`zswap.enabled=0` 写进 cmdline：

| 物理内存 | `zram-fraction` | 实际 zram 容量 | 理由 |
|---|---|---|---|
| < 16G | 1.0 | = RAM | 小内存给满，宁可压内存也别被 OOM 打死 |
| 16–32G | 0.75 | 0.75 × RAM | 插值档 |
| ≥ 32G | 0.5 | 0.5 × RAM | 一半已够，留足物理内存安全红线 |

`max-zram-size = none` 必须写 —— zram-generator 默认上限是 4096MB，不解除的话 32G 机器也只会得到 4G。
`swap-priority = 100` 让内核优先压 zram、其次才写磁盘 swap。

<details>
<summary>生成的 /etc/systemd/zram-generator.conf</summary>

```ini
[zram0]
compression-algorithm = zstd
zram-fraction = 0.75
max-zram-size = none
swap-priority = 100
```

`zram-fraction` 与 `zram-size` 互斥（后者设了会覆盖前者），所以这里不再写 `zram-size = ram`。
</details>

## EarlyOOM

ZRAM 是拿内存压出来的，写满时**不会**像磁盘 swap 那样先卡住给你反应时间，而是直接掉进内核 OOM killer——它的选择可能正好是 niri 或桌面壳。`earlyoom` 在内存见底前就按 `oom_score` 动手，把损失限制在浏览器上。

装 `earlyoom` 并 enable，写 `/etc/default/earlyoom`：

```
EARLYOOM_ARGS="-m 10 -r 60 --avoid ^(init|systemd.*|…)$ --prefer ^(firefox|…)$"
```

- **只给 `-m`，不给 `-s`**。earlyoom 的 `-m` 与 `-s` 是**且**关系（两个都跌破才杀），不是「或」。本机 zram 是唯一 swap，等它剩余也低于阈值才动手，等于把介入时机推到临界点之后。装了硬盘 swapfile 之后再考虑把 `-s` 加回来。
- **`--avoid`** 护住会丢会话的东西：`systemd` / `dbus` / `polkitd`、显示器 `greetd` / `sddm` / `gdm` / `lightdm`、桌面 `niri` / `sway` / `hyprland` / `quickshell` / `dms` / `kwin` / `plasmashell` / `gnome-shell`、`Xorg` / `Xwayland`、以及 `pacman` / `yay` / `paru`（更新跑一半被杀会留下半升级的系统）。
- **`--prefer`** 让浏览器最先被牺牲：内存占用最大，且都有标签页恢复。
- 匹配对象是 `/proc/<pid>/comm`，**大小写敏感且被内核截断到 15 字节**。所以写 `microsoft-edge.*` 而不是 `microsoft-edge-.*`。
- 正则里**不要加引号**：`ExecStart=/usr/bin/earlyoom $EARLYOOM_ARGS` 由 systemd 按空格切分、不经过 shell，引号会连同正则一起传进去导致一条都匹配不上。

脚本里对两个正则做了 `grep -Eq` 语法预检，非法就退回只有 `-m` 的默认策略，不会让服务起不来。

## prep-desktop.sh 做什么

按 wiki 的顺序走一遍，每一项都问一句要不要：

```
前置检查    非 root / 是 Arch / 不在 Live ISO / sudo / 网络 / 找一个 uid≥1000 的用户
系统更新    pacman -Syu —— 先整体升级，避免「部分升级」
multilib    只放开 [multilib] 段，不动 #[multilib-testing]
archlinuxcn 追加源 + 单独装 keyring（没 keyring，该源的包一律判成损坏）
AUR 助手    base-devel + paru / yay（都来自 archlinuxcn，不在这里编译源码）
字体        fontconfig + noto-fonts + cjk + emoji + ttf-jetbrains-mono-nerd + fc-cache
音视频      sof-firmware + alsa-ucm-conf + pipewire 全家桶 + user unit
性能模式    power-profiles-daemon
蓝牙        bluez + bluez-utils（可选）
Flatpak     flatpak（可选，可把 flathub 换成国内镜像）
EDITOR      写 /etc/environment
```

**不管 SSH** —— sshd 在 `arch-install.sh` 的 chroot 阶段就配好了，这里彻底不碰（一个关注点只留一个 owner，见下一节）。

| 问题 | 默认 | 备注 |
|---|---|---|
| 默认编辑器 | 探测已装的 vim / nvim / nano | 三个都没有才问 |
| 开启 multilib | y | Steam、Wine 和一堆 Windows 程序的 32 位依赖 |
| archlinuxcn 用国内镜像 | y | 海外请选 n，否则反而慢 |
| AUR 助手 | paru | paru / yay / both / none |
| 装字体 | y | |
| 装 PipeWire | y | 声音和屏幕共享都靠它 |
| 装 power-profiles-daemon | y | 别再加 tlp / auto-cpufreq，会冲突 |
| 装蓝牙 | n | |
| 装 Flatpak | n | 选了才会问要不要换国内源 |

## SSH 远程登录

wiki 里没有这一节，是本项目额外加的 —— 接下来装显卡驱动和桌面要反复重启、试配置，能从另一台机器连进去比坐在机器前舒服得多。

**只在 `arch-install.sh` 里做，`prep-desktop.sh` 完全不碰 SSH。** 装完重启后手里只有 TTY，没有 scp/sftp 就没法把下一个脚本传进去（VMware 里还得靠共享文件夹或再挂一次 ISO），所以 sshd 在 chroot 阶段就装好、写好 drop-in、`systemctl enable`，第一次开机就能连。

两处都做等于同一件事有两份实现：端口、root 策略、drop-in 名字只要改一处就会漂移，而漂移的表现是「悄悄连不上」，最难查。一个关注点只留一个 owner。

手工装的系统（没跑 `arch-install.sh`）想开 SSH，四条命令：

```bash
sudo pacman -S --needed openssh
printf 'Port 22\nPermitRootLogin no\nPasswordAuthentication yes\n' \
  | sudo tee /etc/ssh/sshd_config.d/10-arch-ssh.conf
sudo ssh-keygen -A && sudo sshd -t
sudo systemctl enable --now sshd
```

那边写的是 `/etc/ssh/sshd_config.d/10-arch-ssh.conf`。

**优先级靠字典序 + 「先读到者生效」**（`sshd_config(5)`：*the first obtained value will be used*）。Arch 的 openssh（10.x 实测）主 `sshd_config` 第 2 行就是 `Include /etc/ssh/sshd_config.d/*.conf`，默认值挪在包自带的 `99-archlinux.conf` 里（`Port 22` / `PermitRootLogin prohibit-password` / `PasswordAuthentication yes`）。读取顺序是 `10-arch-ssh.conf` → `20-systemd-userdb.conf`（systemd 包的）→ `99-archlinux.conf`，所以同名项由我们决定。反过来说，**把自定义文件命名成 `99-zzz.conf` 或更靠后就压不动默认值了**。安装器不假设自己赢：写完用 `sshd -T` 把最终生效值读回来跟期望比对，不一致就 warn。

几个刻意的选择：

- **用 drop-in，不改主配置**：而 sshd 是「先读到的值生效」，所以 drop-in 能压过包自带默认值；回滚也只要删这一个文件，升级不会留 `.pacnew`。
- **先 `sshd -t` 再 enable**：配置不合法就删掉 drop-in、退回系统默认，而不是把一个起不来的服务留在那里 —— 那才是真的把自己锁在门外。
- **默认端口 22、`PermitRootLogin no`、`PasswordAuthentication yes`**。密码登录开着是为了让你第一次能进；把公钥贴进 `~/.ssh/authorized_keys` 之后应该关掉。
- **预建 `~/.ssh`**（700、属主正确），省得之后因为权限不对被 sshd 拒绝，还看不出原因。
- **不装防火墙、不装 fail2ban**。装 ufw 却忘了放行端口，是「SSH 配好了却连不上」最常见的原因；要用的话记得 `ufw allow <port>/tcp`。
- 不写 `UsePAM` / `ChallengeResponseAuthentication` —— Arch 的默认值本来就是对的，动了反而可能让密码登录失效。

**前提：机器得先有 IP。** 有线是 NetworkManager 起来就给；**只有 wifi 的机器仍然要在控制台登录一次、`nmtui` 连上网**，sshd 才可能被连上 —— 装系统阶段没法把 wifi 密码带进新系统（Live ISO 用的是 iwd，凭据不在 NetworkManager 的格式里）。连上之后 `ip -4 addr show scope global` 看地址，另一台机器 `ssh <user>@<ip>`。

连上之后再确认一遍（`sshd -T` 只能在运行中的系统里做，所以这一步没法放进安装器）：

```bash
sudo sshd -T | grep -E '^(port|permitrootlogin|passwordauthentication) '
ss -ltn | grep ':22 '
```

## 它不做什么

两个脚本共同的边界：

- **LUKS 加密**、RAID、LVM
- **Secure Boot**（全程不签名、不动固件密钥）
- **缩小 Windows 分区**（双系统请先自己腾出空间，再用「复用现有分区」模式）
- **BIOS / legacy 引导**（没有 `/sys/firmware/efi` 直接退出）
- **显卡驱动、硬件编解码**（wiki 的下一节，见 [显卡驱动和硬件编解码](https://github.com/SHORiN-KiWATA/Shorin-ArchLinux-Guide/blob/main/wiki/archlinux/%E6%98%BE%E5%8D%A1%E9%A9%B1%E5%8A%A8%E5%92%8C%E7%A1%AC%E4%BB%B6%E7%BC%96%E8%A7%A3%E7%A0%81.md)）
- 桌面环境、输入法、主题、dotfiles

`prep-desktop.sh` 还刻意跳过了 wiki 里两处标「可选，牺牲安全性」的调整：

- **不给 pacman 配免密 sudo**（`%wheel NOPASSWD: /usr/bin/pacman`）。pacman 能装任意包，等于把提权大门敞开；换来的只是少敲一次密码。
- **不改 `faillock.conf` 的 `deny = 3`**。改成 0 是关掉「连续输错密码就锁定」，对日用键盘的桌面机有意义，对能 SSH 登录的机器是净损失。

想要的话自己改，脚本不会拦。

## 安全设计

- 抹盘前把整块盘的分区表打出来，要求**原样输入设备名**才继续；最后还要打 `INSTALL`。
- 所有输入都会去掉空白字符（含 `\r`）再比较，大小写不敏感：从 Windows 粘贴进 VM console 常带 `\r`，`read -r` 会把它留在字符串尾部，导致「明明输了 `INSTALL` 却说 aborted」。密码是唯一例外，原样保留。
- `INSTALL` 那一关输入空行只会 `warn` 并重问，不会中止 —— 一路回车过来的人不至于被这个坑掉；输入其他具体内容（如 `no`）才真的中止。
- 两处确认都会写进 `/tmp/arch-install.log`（`wipe-confirm:` / `install-confirm:`），事后能查到当时到底读到了什么。
- Live U 盘自动排除：比对 `/run/archiso/bootmnt` 的父盘，不会把它列进候选。
- `@swap` 只在选了 swapfile 时才建；不建就是纯 ZRAM，和 wiki 的建议一致。
- 中途失败不自动清理，只打印失败行号、日志路径和 `lsblk -f` 提示，方便你自己判断从哪一步继续。
- **重跑安全**：整盘类型判定用 `lsblk -d`（`--nodeps`，不把分区列进来），盘上留着上次装了一半的 `sda1`/`sda2` 也不会被误判成「不是整盘」；`mkfs` 之前先检查 `/mnt` 没被挂载，避免往已挂载的设备上格式化。
- 密码通过 `printf %q` 写进临时的 `/root/.install-vars`（chmod 600），chroot 里 source 完立刻删除，不进 `ps`、不进日志。
- `prep-desktop.sh` 拒绝以 root 运行，并检查 `%wheel` 是否真有 sudo 权限 —— pipewire 的 user unit 和 `~/.ssh` 的属主都依赖「正确的用户」。
- SSH 默认不允许 root 登录；配置写坏会被 `sshd -t` 拦下并自动回退，不会留下起不来的 sshd。

## 验证状态

- `bash -n` 通过（主脚本 + 从 heredoc 抽出的 chroot 脚本 + `prep-desktop.sh`）。
- 桩测试覆盖：交互函数（回车取默认 / 非法输入重问 / `ask_yn` 在 `set -e` 下的行为）、输入归一化（`INSTALL\r`、首尾空格、小写、空行重问、`no` 中止）、整盘判定在「盘上已有分区」时的行为（`lsblk -d` 只回一行 `disk`）、pacstrap 三级重试（第 3 次成功 / 首次即成功不改配置 / 三次全失败 die / `_pacman_relax` 幂等）、`part_path`、GRUB 配置改写、`[multilib]` 段解锁（确认 `#[multilib-testing]` 没被误伤）、`set_env_kv` 四种情形、chroot 内 SSH 段（`sshd -T` 回读比对：匹配 / 被 99-archlinux.conf 压掉 / 无输出）、drop-in 写入内容。
- **虚拟机验证进度**：`arch-install.sh` 已在虚拟机（UEFI + 一块空盘）上完整跑通一次（分区 → pacstrap → GRUB → 建用户 → 重启登录）。`prep-desktop.sh` 在同一台虚拟机上跑到字体那步（`pacman -Syu` / multilib / archlinuxcn / paru / 字体均已通过），`fc-cache` 缺失的问题就是这一轮暴露出来的。

## 结构

```
arch-install.sh    Live ISO 阶段：分区 → pacstrap → GRUB → 收尾（单文件，无外部依赖）
prep-desktop.sh    装完系统后：软件源 → AUR → 字体 → 音视频 → EDITOR（不碰 SSH）
```

两个脚本都是单文件、零外部依赖（只用 pacman / systemctl / iproute2），互不引用。

## 已知限制

- `linux-firmware-marvell` 没装。Marvell 无线网卡的机器要自己补。
- `pacstrap` 装包时如果 Live 环境 cowspace 不够，会先自动扩到 4G；内存特别小的机器仍可能写满。
- **镜像慢 / 网络抖动**：`install_base` 会自动重试三次（原样 → 关掉 pacman 的 10 秒下载超时并降并行 → 换清华单镜像）。三次都失败才退出；此时已经格式化好、`/mnt` 也挂着，但脚本没有断点续跑，重跑会从头抹盘（Live 环境的包缓存还在，能省一部分下载）。`reflector --sort rate` 的测速只测数据库文件，不代表几百 MB 包的实际速度，所以排序第一的镜像未必最快。
- GRUB 是在 btrfs 上写 `grubenv`，需要 GRUB ≥ 2.14；更早的版本会 warn 但不中断。
- **纯 base 系统里没有 `fontconfig`**：`noto-fonts` 只 `Provides: ttf-font`，并不依赖它，桌面环境装完才会顺带把它带进来。所以字体那一步显式装 `fontconfig`（`fc-cache` / `fc-list` / 字体回退配置 / 装字体后自动刷缓存的 pacman hook 都在这个包里）。
- **凡是「桌面环境通常会带、纯 base 没有」的命令都要探测再调**：`set -Eeuo pipefail` + ERR trap 下，一个不存在的命令会让 `sudo` 退出 1，整个脚本当场停在中间 —— 后面还没跑的步骤（PipeWire / 蓝牙 / EDITOR）全部不执行，而屏幕上的最后一行看起来只是「某条命令找不到」，很容易被当成小问题。`fc-cache` 已改成 `command -v` 兜底。
- `prep-desktop.sh` 第一步就 `pacman -Syu`，机械硬盘 + 慢网络下会很久（几百 MB），这是必要的：只 `-Sy` 不 `-Su` 就是「部分升级」。
- 之前手动装过 `pulseaudio` / `jack2` 的机器，PipeWire 那步会因包冲突失败。脚本只 warn 不中断，手动跑一次 `pacman -S pipewire wireplumber pipewire-pulse pipewire-alsa pipewire-jack` 选替换即可。
- `archlinuxcn-keyring` 极少情况下已过期导致签名错误，届时 `sudo pacman-key --refresh-keys` 再重跑。
- 纯 TTY / SSH 会话里 `systemctl --user` 可能不可用，PipeWire 会降级成「只 enable」，下次图形登录才真正起来。
