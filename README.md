# DreamOpenWRT

OpenWrt **v25.12.6**（x86/64）个人定制固件，用 GitHub Actions 构建，面向 Hyper-V 虚拟机跑旁路由。

## 目录结构

```
build-openwrt.sh          构建脚本（本地和 Actions 共用一份）
config/openwrt.config     .config 的唯一来源，增删软件包只改这里
feeds.conf                软件源清单，三方仓库锁定 commit
files/                    写进固件的默认配置（overlay，会被拷到源码树 files/）
.github/workflows/build.yml  Actions 流程
```

## 默认参数

| 项 | 值 |
| --- | --- |
| 上游 | `openwrt/openwrt` @ `v25.12.6`（可用 `OPENWRT_REF` 覆盖） |
| 目标 | x86/64 generic，SquashFS + GRUB + EFI，`rootfs` 分区 4096MB |
| 产物 | `*-combined.img.gz`、`*-combined-efi.img.gz`、`*-rootfs.tar.gz`、manifest、sha256sums |
| 后台 | `http://192.168.31.254`（只开 80，不走 HTTPS） |
| root 密码 | `root` |
| 时区 / 语言 | `Asia/Shanghai` / 简体中文 |
| 主题 | Argon |
| 网口 | `eth0` 加入 `br-lan`，网关 `192.168.31.1`，DNS `223.5.5.5`、`119.29.29.29` |

## 预装内容

下面这些都**编译进了固件**，刷完机打开 LuCI 就有，不需要再用 apk 安装：

| 包 | 作用 |
| --- | --- |
| `luci-app-openclash` | Clash / mihomo 的 LuCI 前端：订阅、规则分流、TProxy/TUN |
| `luci-app-mosdns` + `mosdns` | DNS 分流与缓存，常和 OpenClash 搭配 |
| `luci-app-adguardhome` | DNS 去广告，经典 Lua 界面；AdGuardHome 二进制已内置到 `/usr/bin/AdGuardHome/`，离线可用 |
| `luci-app-diskman` | 磁盘分区 / 格式化 / 挂载 / SMART |
| `luci-app-advancedplus` | sirpdboy 的高级设置合集 |
| `luci-app-syscontrol` | 系统控制面板（进程、服务、温度等） |
| `luci-app-filemanager` | LuCI 里的文件管理器 |
| `luci-app-ttyd` | 网页终端 |
| `luci-app-upnp` + `miniupnpd` | 内网设备自动端口映射 |
| `luci-app-hd-idle` + `hd-idle` | 机械盘空闲后停转（硬盘休眠） |

**不含 Docker**：`docker`、`dockerd`、`luci-app-dockerman` 一个都没有编进固件，`config/openwrt.config` 里没有任何 docker 相关配置行。刷完在 LuCI「软件包」里也看不到 Docker。

**AdGuardHome 的二进制是内置的**：构建时下载官方 release（`AdGuardHome_linux_amd64.tar.gz`，约 12MB，CGO 静态链接，musl 上直接可跑），校验 sha256 后解到 `/usr/bin/AdGuardHome/AdGuardHome`，正好是经典界面的默认 `binpath`。所以这一项**不需要联网**，代价是固件体积增加约 12~15MB。

**只有 OpenClash 需要固件首次联网**：clash / mihomo 内核不在固件内，第一次进页面时要下载（或手动上传核心文件）。要离线可用得把核心也嵌进来，做法同 AdGuardHome——在 `build-openwrt.sh` 里加一段下载 + 校验 + install。

升级 AdGuardHome 版本：改 `build-openwrt.sh` 顶部的 `ADGUARDHOME_VERSION` 和 `ADGUARDHOME_SHA256`（两个必须成对改），sha256 用这条命令取：

```bash
curl -s https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest \
  | jq -r '.assets[]|select(.name=="AdGuardHome_linux_amd64.tar.gz")|.digest'
```

> root 密码是明文写在 `files/etc/uci-defaults/99-default-settings` 里的。仓库一旦公开，等于把默认密码公开，刷完请立刻改。

## 本地构建

只支持 Linux（Debian/Ubuntu 系，需要 apt）：

```bash
chmod +x build-openwrt.sh
./build-openwrt.sh                    # 完整构建
OPENWRT_REF=openwrt-25.12 ./build-openwrt.sh   # 跟分支而不是锁 tag
JOBS=8 ./build-openwrt.sh             # 指定并行度
SKIP_DEPS=1 ./build-openwrt.sh        # 已装好依赖，跳过 apt
./build-openwrt.sh --update-pins      # 刷新 feeds.conf 里三方仓库的 commit
```

产物在 `output/`，中间文件在 `work/`（两者都已 gitignore）。重复构建时 `work/` 会被复用，ccache 和已下载的源码包都不用重来。

## Actions 构建

推到 GitHub 后，在仓库 Settings 里什么都不用配（不依赖任何 secret）：

- 手动 `Run workflow`，可填源码 ref / 并行度
- 推 `main` 且改到 `build-openwrt.sh`、`config/`、`files/`、`feeds.conf` 时触发
- 每周六 02:00（CST）定时重建，跟随 25.12 分支的安全更新
- 打 `fw-v*` tag，构建完自动发 Release

## 在 Hyper-V 里用

镜像不能直接挂给 Hyper-V，要先转成 VHDX：

```bash
gunzip -k openwrt-x86-64-generic-squashfs-combined-efi.img.gz
qemu-img convert -f raw -O vhdx \
  openwrt-x86-64-generic-squashfs-combined-efi.img openwrt.vhdx
```

Hyper-V 侧：

1. 新建 **第 2 代**虚拟机，**关闭安全启动**（OpenWrt 的 grub 没有签名）
2. 网络适配器接外部交换机；开机后网卡名就是 `eth0`
3. 内存 2GB 起步，动态内存可以开（`hv_balloon` 已内置）

Hyper-V 相关的驱动（`hv_storvsc`、`hv_netvsc`、`hv_balloon`、`hv_utils`）在 x86/64 的默认内核配置里已经是 `=y`，**不需要额外装任何 kmod**。

## 升级

x86 的 `*-combined-efi.img.gz` 本身就是 sysupgrade 镜像，直接在 LuCI 的「系统 → 备份/升级 → 刷写新固件」里上传即可，勾选保留配置就不会丢设置。

为了让升级不丢东西，本仓库做了两件事：

- `CONFIG_TARGET_ROOTFS_PARTSIZE` 固定 4096。改这个值会导致已有机器无法原地升级。
- `files/etc/uci-defaults/99-default-settings` 只在首次启动执行一次，升级后不会重跑，不会覆盖你后来改过的设置。

### 自定义防火墙规则

两条路都能用：

1. **LuCI 页面**：「网络 → 防火墙 → 自定义规则」，写 nft 命令，保存即生效。这个页面写的是 `/etc/firewall.user`，而 fw4 只执行 `/etc/config/firewall` 里 `config include` 声明的脚本——默认配置一条都没有，所以首次启动的 uci-defaults 会补一条 `type script` 的 include。`/etc/firewall.user` 已经进 `/etc/sysupgrade.conf`，升级不会丢。

2. **仓库管理**：把 `99-mine.nft` 放进 `files/etc/nftables.d/`，重建固件。fw4 直接 `include "/etc/nftables.d/*.nft"`（`ruleset.uc:107`），走 git 最适合长期维护。

页面里要写 **nft 命令**（`nft insert rule inet fw4 ...`），不是老的 iptables 语法——官方那段页面文案还是 fw3 时代的。

回滚：每次构建都产出 `build-info.txt`（源码 ref + commit + 构建时间）和 `sha256sums`，对比着换回上一个产物即可。

## 这套配置相对参考实现的改动

| 改动 | 原因 |
| --- | --- |
| `.config` 移出脚本，变成 `config/openwrt.config` | 原来用 `sed` 先删再追加的方式「修正」配置，`make defconfig` 之后被丢掉的包不会报错，只会在固件里静默少功能 |
| 增加必需项校验 | 关键项缺一个就直接失败，其余被丢弃的逐条列出 |
| 加 `CONFIG_DEVEL=y` + `CONFIG_CCACHE=y` | OpenWrt 只认 `CONFIG_CCACHE`（`rules.mk:347`），而它挂在 `menuconfig DEVEL` 下面，不开 DEVEL 会被 defconfig 丢掉；原来只 `export USE_CCACHE=1`，ccache 实际没生效 |
| 强制 ccache 压缩 | `rules.mk` 默认 `CCACHE_NOCOMPRESS:=true`，缓存体积是压缩后的 2~3 倍，会把 Actions 的 10GB 池吃满 |
| 三方 feed 锁 commit | 原来全部跟 master，上游一改就可能编译失败或刷进去出问题 |
| 不自制 LuCI 页面、只修官方那个 | 原来那套「自定义规则」页和官方 `luci-app-firewall` 的 `firewall/custom` 撞同一路径、同一菜单项，`files/` 覆盖时会顶掉官方页面。删掉后用一条 `config include` 让官方页面真正生效（它默认是"写了不生效"的） |
| 不源码编译 `adguardhome`，改成嵌入官方二进制 | packages feed 里那个要从 Go 源码编、还得先编 golang 工具链，2 核上 20~40 分钟；改成下载官方 release + sha256 校验 + 写进 `files/`，编译时间 0，代价是固件 +12~15MB |
| 去掉 `luci-light` | 和完整版 `luci` 同时装是纯冗余 |
| 额外产出 `rootfs.tar.gz` | 容器 / LXC / WSL 场景可直接用，几乎不增加编译时间 |

## 已知限制

- **别从官方源装 kmod**。固件是自己编译的，内核和官方 `downloads.openwrt.org` 上的 kmod 不配套，装了会 `kernel version mismatch`。纯用户空间的包（`luci-app-*`、`curl` 之类）从官方源装没有问题。
- AdGuardHome 二进制是**裸文件**放在 `/usr/bin/AdGuardHome/`，不受 apk 管理：`apk list` 里看不到它，升级只能改脚本版本号后重刷固件（或在该界面里点「更新核心」，但那会写进可写层、占 overlay 空间）。
- 三方 feed 锁的是 commit，不是 tag，升不升级由你决定；`--update-pins` 只刷新 `feeds.conf`，`build-openwrt.sh` 里 `PINNED_PACKAGES` 的 sha 需要手动改（改脚本要走 review，不自动动）。
- 首次构建：公开仓库（4 vCPU）约 2~3 小时，私有仓库（2 vCPU）约 3.5~4.5 小时；ccache 热了之后大约是首次的 1/3。GitHub 作业硬上限 6 小时，所以编译步骤卡了 300 分钟超时——真超时不会白跑，`dl/` 和 ccache 会照常存下来，下一轮带热缓存接着编。
- 纯 Hyper-V 使用的话，`config/openwrt.config` 里那批裸机网卡驱动（r8125/r8126/r8168 等）可以整段删掉，省几分钟和十几 MB。
