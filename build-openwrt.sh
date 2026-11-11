#!/usr/bin/env bash
#
# DreamOpenWRT — OpenWrt x86_64 固件构建脚本
#
# 一份脚本同时服务两个场景：
#   本地 Linux 机器：  ./build-openwrt.sh
#   GitHub Actions：   CI_MODE=1 ./build-openwrt.sh
#
# 设计原则：
#   1. 可调项集中在「参数」一节，逻辑部分不写死具体值
#   2. 配置以 config/openwrt.config 为唯一来源，脚本不负责在运行时拼 .config
#   3. 三方仓库锁定 commit，同一个 ref 每次构建内容一致
#   4. 产物、完整配置、manifest 一起归档，方便比对和回滚
#
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

###############################################################################
# 参数（都可以用环境变量覆盖）
###############################################################################

WORKDIR="${WORKDIR:-$SCRIPT_DIR/work}"
SRC="${SRC:-$WORKDIR/openwrt}"
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/output}"
LOG_DIR="$WORKDIR/build-logs"

OPENWRT_REPO="${OPENWRT_REPO:-https://github.com/openwrt/openwrt.git}"
# 默认锁定 release tag；想跟分支就 OPENWRT_REF=openwrt-25.12
OPENWRT_REF="${OPENWRT_REF:-v25.12.6}"

CPU_COUNT="$(nproc)"
JOBS="${JOBS:-$CPU_COUNT}"
DL_JOBS="${DL_JOBS:-$((CPU_COUNT * 2))}"

SKIP_DEPS="${SKIP_DEPS:-0}"
CI_MODE="${CI_MODE:-0}"

BIN_DIR="$SRC/bin/targets/x86/64"
START_TS="$(date +%s)"
COMMIT=""
BUILD_LOG=""

# 构建版本号，形如 2026.11.11.3（日期 + 当天第几次构建）。
# CI 里由 workflow 数当天已有的 snapshot-* tag 算出来再传进来；本地直接跑时留空，
# 由 write_version_info 生成 local- 前缀的标识。它会写进固件的 /etc/dreamopenwrt-version。
BUILD_VERSION="${BUILD_VERSION:-}"

# 嵌进固件的 AdGuardHome 二进制：直接用官方 release，不走源码编译。
# packages feed 里那个 adguardhome 要从 Go 源码编，还要先编 golang 工具链，
# 2 核上单这一项就要 20~40 分钟；而官方 tar 是 CGO 静态链接的，在 musl 上直接能跑。
# VERSION 和 SHA256 必须成对改，SHA256 取自 GitHub release 资产的 digest 字段：
#   curl -s https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest \
#     | jq -r '.assets[]|select(.name=="AdGuardHome_linux_amd64.tar.gz")|.digest'
ADGUARDHOME_VERSION="${ADGUARDHOME_VERSION:-0.107.80}"
ADGUARDHOME_SHA256="${ADGUARDHOME_SHA256:-28593bc761d71469abdbc6f39ca42cbed763ec92b63082c729177b037ed51d18}"
ADGUARDHOME_URL="https://github.com/AdguardTeam/AdGuardHome/releases/download/v${ADGUARDHOME_VERSION}/AdGuardHome_linux_amd64.tar.gz"

export FORCE_UNSAFE_CONFIGURE=1
export LC_ALL=C

###############################################################################
# 输出与工具
###############################################################################

fmt_dur() { local s="$1"; printf '%dh%02dm%02ds' $((s / 3600)) $(((s % 3600) / 60)) $((s % 60)); }
section() { printf '\n\033[36m===== %s =====\033[0m\n' "$*"; }
info()    { printf '  %s\n' "$*"; }
ok()      { printf '  [OK] %s\n' "$*"; }
warn()    { printf '  [!] %s\n' "$*" >&2; }
die()     { printf '\n[FAIL] %s\n' "$*" >&2; exit 1; }

# 已经编完的包数量，构建心跳里用来判断「卡住了」还是「在推进」
built_count() { find "$SRC/build_dir" -maxdepth 4 -name .built 2>/dev/null | wc -l; }

trap 'printf "\n[FAIL] 第 %s 行的命令失败（退出码 %s）\n" "$LINENO" "$?" >&2' ERR

###############################################################################
# 预检
###############################################################################

preflight() {
  section "预检"
  [ "$(uname -s)" = "Linux" ] || die "本脚本只支持 Linux：OpenWrt 编译工具链依赖 Linux 内核接口"
  [ -f "$SCRIPT_DIR/config/openwrt.config" ] || die "缺少 config/openwrt.config"
  [ -f "$SCRIPT_DIR/feeds.conf" ] || die "缺少 feeds.conf"
  [ -d "$SCRIPT_DIR/files" ] || die "缺少 files/ 目录"

  mkdir -p "$WORKDIR" "$OUTPUT_DIR" "$LOG_DIR"
  local avail_mb
  avail_mb="$(df -Pk "$WORKDIR" | awk 'NR==2 {print int($4/1024)}')"
  if [ "$avail_mb" -lt 25600 ]; then
    warn "工作目录可用空间只有 ${avail_mb}MB，一次完整编译通常需要 25~35GB"
  else
    info "可用空间 ${avail_mb}MB"
  fi
  info "CPU ${CPU_COUNT} 核 / 编译 -j$JOBS / 下载 -j$DL_JOBS"
  info "源码 $OPENWRT_REPO @ $OPENWRT_REF"
}

###############################################################################
# 编译依赖
###############################################################################

APT_BASE=(
  build-essential clang flex bison g++ gawk gcc-multilib g++-multilib
  gettext git libncurses-dev libssl-dev python3-setuptools rsync swig
  unzip zlib1g-dev file wget curl ccache quilt zstd libelf-dev time xsltproc
)
# 只有个别语言生态的包才用得上，装不上不阻断构建
APT_EXTRA=(ecj fastjar java-propose-classpath ocaml-nox ocaml-findlib subversion libxml-parser-perl)

install_deps() {
  section "安装编译依赖"
  if [ "$SKIP_DEPS" = "1" ]; then
    info "SKIP_DEPS=1，跳过"
    return 0
  fi
  command -v apt-get >/dev/null 2>&1 || die "没找到 apt-get，本脚本只支持 Debian/Ubuntu 系"

  local sudo_cmd=""
  if [ "$(id -u)" != "0" ]; then
    command -v sudo >/dev/null 2>&1 || die "当前不是 root 且没有 sudo"
    sudo_cmd="sudo"
  fi

  export DEBIAN_FRONTEND=noninteractive
  local log="$LOG_DIR/apt.log"

  # 输出重定向到文件：dpkg 解包时会刷几百行 "Reading database ..."，把 Actions 日志撑长
  # 又没有信息量。失败时再把尾部打出来。
  # shellcheck disable=SC2086
  if ! $sudo_cmd apt-get update -qq >"$log" 2>&1 \
    || ! $sudo_cmd apt-get install -y -qq --no-install-recommends "${APT_BASE[@]}" >>"$log" 2>&1; then
    tail -n 40 "$log" >&2
    die "基础依赖安装失败，详见 $log"
  fi

  # 可选依赖：先整体装一次，失败再逐个试。发行版升级后这些老包名会消失
  # （Ubuntu 26.04 上 ecj / ocaml-nox 之类就没了），逐个装能看出缺哪个，
  # 也不会因为一个装不上连累其它。
  # shellcheck disable=SC2086
  if ! $sudo_cmd apt-get install -y -qq --no-install-recommends "${APT_EXTRA[@]}" >>"$log" 2>&1; then
    local pkg
    local skipped=()
    for pkg in "${APT_EXTRA[@]}"; do
      # shellcheck disable=SC2086
      $sudo_cmd apt-get install -y -qq --no-install-recommends "$pkg" >>"$log" 2>&1 \
        || skipped+=("$pkg")
    done
    [ ${#skipped[@]} -eq 0 ] || warn "当前发行版没有这些可选依赖，已跳过：${skipped[*]}"
  fi
  ok "依赖就绪（详细日志 $log）"
}

###############################################################################
# 源码
###############################################################################

# OpenWrt 的 rules.mk 会 export CCACHE_NOCOMPRESS:=true，cache 体积约为压缩后的 2~3 倍。
# Actions 的缓存池是按仓库共享的 10GB，必须压。
#
# ⚠ 不能把它改成 =false：ccache 4.x 的布尔解析不接受 "false"，
#   会直接报 CCACHE_NOCOMPRESS: invalid boolean environment variable value "false"
#   然后退出，表现成 "C compiler cannot create executables"（已经踩过一次）。
#   正确做法是把那句删掉，改用 CCACHE_COMPRESS=true。
patch_ccache_compression() {
  local rules="$SRC/rules.mk"
  grep -q 'CCACHE_NOCOMPRESS' "$rules" \
    || die "rules.mk 里没有 CCACHE_NOCOMPRESS，上游可能改了写法，请更新 patch_ccache_compression"
  sed -i '/CCACHE_NOCOMPRESS/d' "$rules"
  export CCACHE_COMPRESS=true
  info "已开启 ccache 压缩（CCACHE_COMPRESS=true）"
}

sync_source() {
  section "获取 OpenWrt 源码（$OPENWRT_REF）"
  # CI 里 actions/cache 会先把 dl/ 和 .ccache/ 还原到 $SRC 下，所以这里**不能假设
  # $SRC 不存在或为空** —— 之前用 git clone 就直接挂在
  # "destination path already exists and is not an empty directory"。
  # 改成 git init + fetch + checkout：在非空目录里也能建立工作树，
  # 未跟踪的 dl/ 和 .ccache/ 不会被碰，而且比 clone 少一次全量拷贝。
  if [ -d "$SRC/.git" ]; then
    info "复用已有源码目录，更新到 $OPENWRT_REF"
    git -C "$SRC" fetch --depth 1 origin "$OPENWRT_REF"
  else
    info "初始化源码目录（$SRC 里可能已有 dl/、.ccache/ 缓存）"
    mkdir -p "$SRC"
    git -C "$SRC" init -q
    git -C "$SRC" remote add origin "$OPENWRT_REPO" 2>/dev/null \
      || git -C "$SRC" remote set-url origin "$OPENWRT_REPO"
    git -C "$SRC" fetch --depth 1 origin "$OPENWRT_REF"
  fi
  git -C "$SRC" -c advice.detachedHead=false checkout -f FETCH_HEAD
  COMMIT="$(git -C "$SRC" rev-parse HEAD)"
  patch_ccache_compression
  ok "源码 $OPENWRT_REF @ ${COMMIT:0:12}"
}

###############################################################################
# feeds
###############################################################################

sync_feeds() {
  section "更新软件源（feeds）"
  install -m 0644 "$SCRIPT_DIR/feeds.conf" "$SRC/feeds.conf.default"
  ( cd "$SRC" && ./scripts/feeds update -a )

  # 官方 luci feed 里也有一个同名 luci-app-adguardhome，会和 package/custom 下的
  # 经典版本抢同一个包名。必须在建软链之前把它从索引里摘掉，否则会留下指向
  # 已删除目录的坏链接，defconfig 阶段直接失败。
  rm -rf "$SRC/feeds/luci/applications/luci-app-adguardhome"
  if [ -f "$SRC/feeds/luci.index" ]; then
    sed -i '\#^luci/applications/luci-app-adguardhome$#d' "$SRC/feeds/luci.index"
  fi
  rm -rf "$SRC/package/feeds/luci/luci-app-adguardhome"

  ( cd "$SRC" && ./scripts/feeds install -a )
  ok "feeds 就绪"
}

###############################################################################
# 自定义软件包（不进 feeds 的独立仓库）
###############################################################################

# 格式：目录名|仓库地址|commit
PINNED_PACKAGES=(
  "luci-theme-argon|https://github.com/jerrykuku/luci-theme-argon.git|c6d63bd68aa9272e40c35cee5e615f45cc1e4eb0"
  "luci-app-adguardhome|https://github.com/rufengsuixing/luci-app-adguardhome.git|37fdf502b99328b37c9ef4c4387f069f67253f85"
)

# 只拉这一个 commit，不要历史。比 clone 再 checkout 省一半以上时间。
fetch_pinned() {
  local dest="$1" url="$2" sha="$3"
  rm -rf "$dest"
  mkdir -p "$dest"
  git -C "$dest" init -q
  git -C "$dest" remote add origin "$url"
  git -C "$dest" fetch -q --depth 1 origin "$sha"
  git -C "$dest" -c advice.detachedHead=false checkout -q -f FETCH_HEAD
}

sync_custom_packages() {
  section "写入自定义软件包"
  local entry name url sha
  for entry in "${PINNED_PACKAGES[@]}"; do
    IFS='|' read -r name url sha <<<"$entry"
    fetch_pinned "$SRC/package/custom/$name" "$url" "$sha"
    info "$name @ ${sha:0:12}"
  done
  # 换掉了同名包，包索引缓存必须重建，否则 defconfig 看到的还是旧元数据
  rm -rf "$SRC/tmp/info" "$SRC"/tmp/.packageinfo* "$SRC/tmp/.config-package.in"
  ok "自定义软件包就绪"
}

###############################################################################
# 默认配置 overlay
###############################################################################

sync_overlay() {
  section "同步默认配置（files/）"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete "$SCRIPT_DIR/files/" "$SRC/files/"
  else
    rm -rf "$SRC/files"
    mkdir -p "$SRC/files"
    cp -a "$SCRIPT_DIR/files/." "$SRC/files/"
  fi

  # 仓库在 Windows 上开发时 NTFS 不保存可执行位，git 可能把这些文件记成
  # 100644。init.d / usr/sbin / uci-defaults 少了 +x 就等于没装，且失败是静默的。
  # 不依赖工作区的文件模式，进源码树后统一补一次。
  # 注意这里必须用 if 而不是 `[ -f ] && chmod`：glob 没匹配时会留下字面量
  # 带 * 的路径，&& 短路返回 1，在 set -e 下会直接把整个构建打断。
  for f in \
    "$SRC/files/etc/uci-defaults/"* \
    "$SRC/files/etc/init.d/"* \
    "$SRC/files/usr/sbin/"*; do
    if [ -f "$f" ]; then
      chmod 0755 "$f"
    fi
  done

  ok "$(find "$SCRIPT_DIR/files" -type f | wc -l) 个文件写入 files/"
}

###############################################################################
# 嵌入第三方二进制（官方 release，不进编译流程）
###############################################################################

# 下载 + 强制 sha256 校验；命中缓存且哈希对得上就跳过下载。
# 哈希不对就删文件并让构建失败：宁可失败，也别把来路不明的二进制刷进固件。
fetch_verified() {
  local url="$1" sha="$2" dest="$3"
  command -v curl >/dev/null 2>&1 || die "需要 curl"
  if [ -f "$dest" ] && echo "$sha  $dest" | sha256sum -c --status 2>/dev/null; then
    info "缓存命中：$(basename "$dest")"
    return 0
  fi
  info "下载 $url"
  rm -f "$dest"
  curl -fL --retry 3 --retry-delay 5 --connect-timeout 20 -o "$dest" "$url" \
    || die "下载失败：$url"
  if ! echo "$sha  $dest" | sha256sum -c --status 2>/dev/null; then
    rm -f "$dest"
    die "sha256 校验失败：$(basename "$dest")（版本或上游资产改过？）"
  fi
}

# 必须在 sync_overlay 之后跑：rsync --delete 会把这里放进 $SRC/files 的文件清掉。
# 目标路径要和经典 LuCI 界面的默认 binpath 一致，否则它会认为自己没装而重新下载：
#   /etc/config/AdGuardHome 里 option binpath '/usr/bin/AdGuardHome/AdGuardHome'
embed_adguardhome() {
  section "嵌入 AdGuardHome 二进制（v$ADGUARDHOME_VERSION）"
  local cache="$WORKDIR/cache"
  local tarball="$cache/AdGuardHome_linux_amd64-${ADGUARDHOME_VERSION}.tar.gz"
  local stage="$WORKDIR/stage-adguardhome"
  local dest="$SRC/files/usr/bin/AdGuardHome"

  mkdir -p "$cache" "$dest"
  fetch_verified "$ADGUARDHOME_URL" "$ADGUARDHOME_SHA256" "$tarball"

  # 不要写死包内路径：不同版本的 tar 结构不一样（v0.107.80 里二进制在顶层
  # ./AdGuardHome，更早的版本在 AdGuardHome/ 子目录），写死成员名会直接
  # "Not found in archive"。全解后用 find + ELF 头校验来确定哪个才是二进制。
  rm -rf "$stage"
  mkdir -p "$stage"
  tar -xzf "$tarball" -C "$stage" || die "解包 AdGuardHome 失败：tar 报错"
  local bin
  bin="$(find "$stage" -type f -name AdGuardHome | head -1)"
  [ -n "$bin" ] || die "包里没有名为 AdGuardHome 的文件，上游结构变了"
  [ "$(head -c 4 "$bin" | od -An -c | tr -d ' \n')" = "177ELF" ] \
    || die "解出来的 AdGuardHome 不是 ELF 可执行文件（$bin）"
  # 用 install 而不是 mv + chmod：权限在建文件时一次设定，不依赖后续 chmod 生效
  install -m 0755 "$bin" "$dest/AdGuardHome" || die "安装 AdGuardHome 失败"
  ok "$(du -h "$dest/AdGuardHome" | cut -f1) 已写入 /usr/bin/AdGuardHome/AdGuardHome"
}

###############################################################################
# 把构建版本写进固件
###############################################################################

# 刷完 `cat /etc/dreamopenwrt-version` 就能知道这机器上是哪一次构建，
# 不用去翻 Actions 记录。必须在 sync_overlay 之后写，否则会被 rsync --delete 清掉。
write_version_info() {
  section "写入构建版本"
  # 本地直接跑脚本时没有 CI 算好的号，用时间戳兜底，避免把空值写进固件
  if [ -z "$BUILD_VERSION" ]; then
    BUILD_VERSION="local-$(TZ=CST-8 date +%Y.%m.%d.%H%M)"
    info "未指定 BUILD_VERSION，本地构建用 $BUILD_VERSION"
  fi

  local dir="$SRC/files/etc"
  mkdir -p "$dir"
  {
    echo "VERSION=$BUILD_VERSION"
    echo "OPENWRT_REF=$OPENWRT_REF"
    echo "OPENWRT_COMMIT=${COMMIT:-unknown}"
    echo "BUILD_TIME=$(date -Iseconds)"
  } >"$dir/dreamopenwrt-version"
  ok "$BUILD_VERSION 已写入 /etc/dreamopenwrt-version"
}

###############################################################################
# .config
###############################################################################

# 少一个就是固件少一个功能，必须硬失败。别把这里当成普通校验放过去。
REQUIRED_SYMBOLS=(
  CONFIG_TARGET_x86_64_DEVICE_generic
  CONFIG_PACKAGE_luci
  CONFIG_PACKAGE_luci-base
  CONFIG_PACKAGE_luci-ssl
  CONFIG_PACKAGE_luci-mod-dashboard
  CONFIG_PACKAGE_luci-app-nlbwmon
  CONFIG_PACKAGE_luci-app-uhttpd
  CONFIG_PACKAGE_kmod-tcp-bbr
  CONFIG_PACKAGE_luci-theme-argon
  CONFIG_PACKAGE_luci-compat
  CONFIG_PACKAGE_luci-app-firewall
  CONFIG_PACKAGE_luci-app-package-manager
  CONFIG_PACKAGE_luci-app-openclash
  CONFIG_PACKAGE_luci-app-mosdns
  CONFIG_PACKAGE_mosdns
  CONFIG_PACKAGE_luci-app-adguardhome
  CONFIG_PACKAGE_firewall4
  CONFIG_PACKAGE_dnsmasq-full
  CONFIG_CCACHE
)

verify_config() {
  local sym missing=() dropped=()
  for sym in "${REQUIRED_SYMBOLS[@]}"; do
    grep -qxF "${sym}=y" "$SRC/.config" || missing+=("$sym")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    printf '\n以下关键项被 make defconfig 丢掉了：\n' >&2
    printf '  - %s\n' "${missing[@]}" >&2
    die "配置校验失败（缺 ${#missing[@]} 项）。通常是依赖不满足或包名在上游变了，别直接放行"
  fi

  while IFS= read -r sym; do
    grep -qxF "${sym}=y" "$SRC/.config" || dropped+=("$sym")
  # 字符集要带连字符，否则 CONFIG_PACKAGE_luci-app-firewall 这类符号会被整条漏掉
  done < <(sed -n 's/^\(CONFIG_[A-Za-z0-9_-]*\)=y$/\1/p' "$SCRIPT_DIR/config/openwrt.config")

  if [ ${#dropped[@]} -gt 0 ]; then
    warn "另有 ${#dropped[@]} 项在 defconfig 后被丢弃（依赖不全或包名已变），核对一下："
    printf '  - %s\n' "${dropped[@]}" >&2
  fi
}

write_config() {
  section "生成 .config"
  cp "$SCRIPT_DIR/config/openwrt.config" "$SRC/.config"
  rm -rf "$SRC/tmp/info" "$SRC"/tmp/.packageinfo* "$SRC/tmp/.config-package.in"
  ( cd "$SRC" && make defconfig )
  verify_config

  cp "$SRC/.config" "$OUTPUT_DIR/config.full"
  ( cd "$SRC" && ./scripts/diffconfig.sh >"$OUTPUT_DIR/config.diff" 2>/dev/null ) \
    || warn "diffconfig 生成失败（不影响构建）"
  ok "配置已确定，已存 $OUTPUT_DIR/config.full"
}

###############################################################################
# 下载
###############################################################################

download_sources() {
  section "下载源码包（-j$DL_JOBS）"
  if ( cd "$SRC" && make download -j"$DL_JOBS" V=s ) 2>&1 | tee "$LOG_DIR/download.log"; then
    ok "全部源码包就绪"
  else
    warn "并行下载有失败，改单线程重试一次"
    if ( cd "$SRC" && make download -j1 V=s ) 2>&1 | tee -a "$LOG_DIR/download.log"; then
      ok "重试成功"
    else
      grep -E 'Download failed|Hash mismatch|ERROR|failed' "$LOG_DIR/download.log" | tail -20 >&2 || true
      die "源码包下载失败，详见 $LOG_DIR/download.log"
    fi
  fi
  # 给 CI 的缓存保存步骤做完整性标记：只有下载真跑完了才允许把 dl/ 写进固定 key，
  # 否则残缺的目录会把那个不可变的 key 永久毒化。
  touch "$SRC/.dl-complete"
}

###############################################################################
# 编译
###############################################################################

build_image() {
  section "开始编译（-j$JOBS）"
  BUILD_LOG="$LOG_DIR/build-$(date +%Y%m%d-%H%M%S).log"
  info "完整日志：$BUILD_LOG"

  # 输出写到文件而不是直接刷屏：Actions 日志有大小上限，几万行 make 输出会把
  # 真正的报错挤出可见范围。前台只留每分钟一行心跳。
  #
  # 子 shell 里先 trap - ERR：否则 set -E 会让它按自己的行号打一条
  # "[FAIL] 第 N 行命令失败"，那个行号是子 shell 里的、指向不着边际的位置，
  # 真正的失败处理交给下面的 wait + die。
  ( trap - ERR; cd "$SRC" && make -j"$JOBS" V=s ) >"$BUILD_LOG" 2>&1 &
  local pid=$!
  local rc=0

  while kill -0 "$pid" 2>/dev/null; do
    sleep 60 || true
    printf '  [%s] 已编译 %s 个包 / 剩余 %sMB\n' \
      "$(date +%H:%M:%S)" "$(built_count)" \
      "$(df -Pk "$WORKDIR" | awk 'NR==2 {print int($4/1024)}')"
  done

  wait "$pid" || rc=$?
  if [ "$rc" -ne 0 ]; then
    # make -j 下末尾几十行往往只剩并行任务的输出，真正的报错在前面。
    # 按优先级找第一条：OpenWrt 收尾一定会打 "ERROR: <pkg> failed to build."，
    # 这条最有信息量；其次是 make 的 "*** [...]"；再往后才是不太精确的关键字。
    # 注意别把 kconfig 的 "recursive dependency" 之类噪音当成根因（它带 error: 前缀）。
    local first="" pat n from
    for pat in 'ERROR: .*failed to build' '\*\*\* \[' 'configure: error' 'No space left' 'error: '; do
      n="$(grep -nE "$pat" "$BUILD_LOG" | head -1 | cut -d: -f1)"
      if [ -n "$n" ]; then
        first="$n"
        break
      fi
    done
    if [ -n "$first" ]; then
      from=$(( first > 20 ? first - 20 : 1 ))
      printf '\n===== 第一个报错附近（日志第 %s 行）=====\n' "$first"
      sed -n "${from},$(( first + 10 ))p" "$BUILD_LOG"
    else
      warn "日志里没匹配到已知的报错关键字，直接看末尾"
    fi
    printf '\n===== 日志末尾 40 行 =====\n'
    tail -n 40 "$BUILD_LOG" || true
    printf '\n===== 磁盘占用 =====\n'
    df -h "$WORKDIR" || true
    die "编译失败（退出码 $rc），完整日志 $BUILD_LOG"
  fi
  ok "编译完成，耗时 $(fmt_dur $(($(date +%s) - START_TS)))"
}

###############################################################################
# 产物
###############################################################################

collect_artifacts() {
  section "收集产物"
  [ -d "$BIN_DIR" ] || die "找不到产物目录 $BIN_DIR"

  shopt -s nullglob
  local files=(
    "$BIN_DIR"/*.img.gz
    "$BIN_DIR"/*rootfs.tar.gz
    "$BIN_DIR"/sha256sums
    "$BIN_DIR"/*.manifest
  )
  shopt -u nullglob
  [ ${#files[@]} -gt 0 ] || die "产物目录为空，编译没有真正完成"

  cp -f "${files[@]}" "$OUTPUT_DIR/"
  cp -f "$SRC/.config" "$OUTPUT_DIR/config.full"
  cp -f "$SCRIPT_DIR/feeds.conf" "$OUTPUT_DIR/feeds.lock"

  {
    echo "BUILD_VERSION=$BUILD_VERSION"
    echo "OPENWRT_REPO=$OPENWRT_REPO"
    echo "OPENWRT_REF=$OPENWRT_REF"
    echo "OPENWRT_COMMIT=$COMMIT"
    echo "OPENWRT_SUBJECT=$(git -C "$SRC" log -1 --pretty=%s)"
    echo "BUILD_TIME=$(date -Iseconds)"
    echo "BUILD_HOST=$(uname -srm)"
    echo "BUILD_JOBS=$JOBS"
    echo "BUILD_DURATION=$(fmt_dur $(($(date +%s) - START_TS)))"
    echo "ADGUARDHOME_VERSION=$ADGUARDHOME_VERSION"
  } >"$OUTPUT_DIR/build-info.txt"

  ok "$(ls -1 "$OUTPUT_DIR" | wc -l) 个文件写入 $OUTPUT_DIR"
}

###############################################################################
# 刷新三方 commit 锁定
###############################################################################

update_pins() {
  section "刷新三方仓库锁定的 commit"
  local tmp name url sha
  tmp="$(mktemp)"
  while IFS= read -r line; do
    if [[ "$line" =~ ^src-git[[:space:]]+([A-Za-z0-9_-]+)[[:space:]]+(https://[^[:space:]^;]+) ]]; then
      name="${BASH_REMATCH[1]}"
      url="${BASH_REMATCH[2]}"
      if [[ "$url" == https://github.com/openwrt/* ]]; then
        # 官方 feed 跟随分支，不锁 commit
        printf '%s\n' "$line" >>"$tmp"
      else
        sha="$(git ls-remote "$url" HEAD | cut -f1)"
        [ -n "$sha" ] || die "取不到 $url 的 HEAD"
        printf 'src-git %s %s^%s\n' "$name" "$url" "$sha" >>"$tmp"
        info "$name -> ${sha:0:12}"
      fi
    else
      printf '%s\n' "$line" >>"$tmp"
    fi
  done <"$SCRIPT_DIR/feeds.conf"
  mv "$tmp" "$SCRIPT_DIR/feeds.conf"

  # PINNED_PACKAGES 里的 sha 需要人工确认，这里只提示，不自动改脚本（改脚本要过 review）
  warn "feeds.conf 已更新。PINNED_PACKAGES 里的 sha 请按需手动更新：${PINNED_PACKAGES[*]}"
}

###############################################################################
# 收尾
###############################################################################

summary() {
  section "完成"
  info "版本：$BUILD_VERSION"
  info "耗时：$(fmt_dur $(($(date +%s) - START_TS)))"
  info "源码：$OPENWRT_REF @ ${COMMIT:0:12}"
  info "产物：$OUTPUT_DIR"
  ls -lh "$OUTPUT_DIR" | sed 's/^/  /'
  printf '\nHyper-V 使用（Gen2，记得关 Secure Boot）：\n'
  printf '  gunzip -k openwrt-x86-64-generic-squashfs-combined-efi.img.gz\n'
  printf '  qemu-img convert -f raw -O vhdx openwrt-x86-64-generic-squashfs-combined-efi.img openwrt.vhdx\n'
}

usage() {
  cat <<'EOF'
DreamOpenWRT 构建脚本

  ./build-openwrt.sh                 完整构建
  ./build-openwrt.sh --update-pins   刷新 feeds.conf 里三方仓库锁定的 commit
  ./build-openwrt.sh --help          显示本帮助

环境变量：
  OPENWRT_REF     源码 tag 或分支，默认 v25.12.6
  BUILD_VERSION   构建版本号（如 2026.11.11.3），写进固件 /etc/dreamopenwrt-version；
                  留空则本地构建自动用 local-<日期时间>
  JOBS            编译并行度，默认 CPU 核心数
  DL_JOBS         下载并行度，默认 CPU 核心数 x2
  SKIP_DEPS=1     跳过 apt 依赖安装
  CI_MODE=1       按 CI 方式输出（心跳 + 日志落盘）
  WORKDIR         工作目录，默认 ./work
EOF
}

main() {
  case "${1:-}" in
    --update-pins) update_pins; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    "") ;;
    *) die "未知参数：$1（用 --help 看用法）" ;;
  esac

  preflight
  install_deps
  sync_source
  sync_feeds
  sync_custom_packages
  sync_overlay
  embed_adguardhome
  write_version_info
  write_config
  download_sources
  build_image
  collect_artifacts
  summary
}

main "$@"
