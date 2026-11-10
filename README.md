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
| `luci-app-adguardhome` | DNS 去广告，用的是 rufengsuixing 的经典 Lua 界面 |
| `luci-app-diskman` | 磁盘分区 / 格式化 / 挂载 / SMART |
| `luci-app-advancedplus` | sirpdboy 的高级设置合集 |
| `luci-app-syscontrol` | 系统控制面板（进程、服务、温度等） |
| `luci-app-filemanager` | LuCI 里的文件管理器 |
| `luci-app-ttyd` | 网页终端 |
| `luci-app-upnp` + `miniupnpd` | 内网设备自动端口映射 |
| `luci-app-hd-idle` + `hd-idle` | 机械盘空闲后停转（硬盘休眠） |

**不含 Docker**：`docker`、`dockerd`、`luci-app-dockerman` 一个都没有编进固件，`config/openwrt.config` 里没有任何 docker 相关配置行。刷完在 LuCI「软件包」里也看不到 Docker。

**两个插件需要固件首次联网**：

- OpenClash 的 clash / mihomo 内核不在固件内，第一次进页面时要下载（或手动上传核心文件）。
- AdGuardHome 的经典界面同理，首次使用会去上游拉二进制。

离线环境要用这两个，得改成编译时嵌入，代价是编译时间和固件体积都会上去。

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

为了让升级不丢东西，本仓库做了三件事：

- `CONFIG_TARGET_ROOTFS_PARTSIZE` 固定 4096。改这个值会导致已有机器无法原地升级。
- `files/etc/sysupgrade.conf` 里额外保留面板中的自定义 nftables 规则，否则升级后规则会被新镜像覆盖成空文件。
- `files/etc/uci-defaults/99-default-settings` 只在首次启动执行一次，升级后不会重跑，不会覆盖你后来改过的设置。

回滚：每次构建都产出 `build-info.txt`（源码 ref + commit + 构建时间）和 `sha256sums`，对比着换回上一个产物即可。

## 这套配置相对参考实现的改动

| 改动 | 原因 |
| --- | --- |
| `.config` 移出脚本，变成 `config/openwrt.config` | 原来用 `sed` 先删再追加的方式「修正」配置，`make defconfig` 之后被丢掉的包不会报错，只会在固件里静默少功能 |
| 增加必需项校验 | 关键项缺一个就直接失败，其余被丢弃的逐条列出 |
| 加 `CONFIG_CCACHE=y` | OpenWrt 只认这个开关（`rules.mk:347`）；原来只 `export USE_CCACHE=1`，ccache 实际没生效 |
| 强制 ccache 压缩 | `rules.mk` 默认 `CCACHE_NOCOMPRESS:=true`，缓存体积是压缩后的 2~3 倍，会把 Actions 的 10GB 池吃满 |
| 三方 feed 锁 commit | 原来全部跟 master，上游一改就可能编译失败或刷进去出问题 |
| 面板菜单改用独立 `menu.d` 文件 | 原来用 python 改 luci feed 里的 `menu.json`，feed 换路径就静默失效 |
| 不再源码编译 `adguardhome` | packages feed 里那个要从 Go 源码编，会拉 golang 工具链，单这一项 20~40 分钟；改用经典 LuCI 界面在首次使用时下载上游二进制 |
| 去掉 `luci-light` | 和完整版 `luci` 同时装是纯冗余 |
| 额外产出 `rootfs.tar.gz` | 容器 / LXC / WSL 场景可直接用，几乎不增加编译时间 |

## 已知限制

- **别从官方源装 kmod**。固件是自己编译的，内核和官方 `downloads.openwrt.org` 上的 kmod 不配套，装了会 `kernel version mismatch`。纯用户空间的包（`luci-app-*`、`curl` 之类）从官方源装没有问题。
- `adguardhome` 上游二进制在**首次进入 AdGuardHome 页面时下载**，这一步需要路由器能上外网。要固件自带二进制，得改回源码编译版本。
- 三方 feed 锁的是 commit，不是 tag，升不升级由你决定；`--update-pins` 只刷新 `feeds.conf`，`build-openwrt.sh` 里 `PINNED_PACKAGES` 的 sha 需要手动改（改脚本要走 review，不自动动）。
- 首次构建：公开仓库（4 vCPU）约 2~3 小时，私有仓库（2 vCPU）约 3.5~4.5 小时；ccache 热了之后大约是首次的 1/3。GitHub 作业硬上限 6 小时，所以编译步骤卡了 300 分钟超时——真超时不会白跑，`dl/` 和 ccache 会照常存下来，下一轮带热缓存接着编。
- 纯 Hyper-V 使用的话，`config/openwrt.config` 里那批裸机网卡驱动（r8125/r8126/r8168 等）可以整段删掉，省几分钟和十几 MB。
