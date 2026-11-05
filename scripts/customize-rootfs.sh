#!/usr/bin/env bash
# mu300-linux 定制 rootfs 构建脚本（署名 lhhc_02）
#
# 用法: customize-rootfs.sh <release目录> <system> <builder> <tag>
#   release目录: 含官方 release 资产的目录（custom-rootfs.yml 下载的那一套）
#   system:      openwrt | openwrt-luci
#   builder:     编译者署名，写入 /etc/banner 和 /etc/buildinfo
#   tag:         所基于的官方 release tag（记录用）
#
# 做的事:
#   1. 保留原始 rootfs 为 .orig（回退能力，永不覆盖原始输入）
#   2. docker import 为 arm64 容器，在容器内:
#      - dnsmasq -> dnsmasq-full（OpenClash 前置要求）
#      - 安装 whzhni1/luci-app-tailscale（Tailscale 的 LuCI 界面 + 中文包）
#      - 安装 vernesong/OpenClash 最新版 apk 包
#      - 清理 feed 的 kmod-* 包与 6.x 模块目录（设备使用 mu300 自带 5.4 内核模块）
#      - 写入署名：/etc/banner（SSH/串口登录横幅）+ /etc/buildinfo（cat 可查）
#        ※ 不再改写 /etc/openwrt_release 与 /usr/lib/os-release。
#          os-release 由 procd 解析后直接喂给 ubus system board，引号/转义处理不当会让
#          LuCI 概览页那行显示成乱码，风险远大于收益，按需求整块去掉。
#   3. docker export -> 修复 Docker 注入的 resolv.conf/hosts/hostname -> gzip
#
# 插件只有两个：OpenClash + Tailscale（都带 LuCI 界面）。AdGuard Home 已按需求去掉。
# Tailscale 用 whzhni1 的 bundle，不装官方 tailscale 包——两者都带
# etc/config/tailscale 与 etc/init.d/tailscale，会互相覆盖导致 apk 报错退出（实测 1 error）。
# 这个 bundle 自己负责下载/管理 tailscaled 二进制（LuCI 页面里一键下载或手动上传）。
#
# 环境变量（可选）:
#   GH_PROXY        GitHub 加速前缀，如 https://gh-proxy.com/（构建机访问 GitHub 失败时用）

set -euo pipefail

REL_DIR="${1:?用法: customize-rootfs.sh <release目录> <system> <builder> <tag>}"
SYSTEM="${2:-openwrt-luci}"
BUILDER="${3:-lhhc_02}"
TAG="${4:-unknown}"

case "$SYSTEM" in
  openwrt|openwrt-luci) ;;
  *) echo "错误: system 只能是 openwrt 或 openwrt-luci"; exit 1 ;;
esac

ROOTFS="mu300-${SYSTEM}-rootfs.tar.gz"
SRC="${REL_DIR}/${ROOTFS}"
[ -f "$SRC" ] || { echo "错误: 找不到 ${SRC}"; exit 1; }

BUILD_DATE="$(date -u '+%Y-%m-%d %H:%M UTC')"
IMG="mu300-custom-${SYSTEM}"

echo "==> [1/4] 保留原始 rootfs（回退用）"
[ -f "${SRC}.orig" ] || cp -a "$SRC" "${SRC}.orig"

echo "==> [2/4] docker import 并定制容器"
docker import --platform linux/arm64 "${SRC}.orig" "${IMG}:base" >/dev/null

docker rm -f "${IMG}-build" >/dev/null 2>&1 || true

# shellcheck disable=SC2016
docker run --platform linux/arm64 --name "${IMG}-build" \
  -e BUILDER="$BUILDER" \
  -e BUILD_DATE="$BUILD_DATE" \
  -e BASE_TAG="$TAG" \
  -e GH_PROXY="${GH_PROXY:-}" \
  -e OPENWRT_MIRROR="${OPENWRT_MIRROR:-}" \
  -e SYSTEM_LABEL="$SYSTEM" \
  "${IMG}:base" /bin/sh -euc '
    if [ -n "${OPENWRT_MIRROR:-}" ]; then
      sed -i "s_https\?://downloads.openwrt.org_${OPENWRT_MIRROR}_" /etc/apk/repositories.d/distfeeds.list 2>/dev/null || true
    fi
    # 只刷新索引，不做 apk upgrade：整库升级会动 glibc/内核相关包，
    # 与设备固化的 5.4 内核模块存在版本错配风险，收益为零。
    apk update

    # --- OpenClash 依赖: dnsmasq 换 dnsmasq-full ---
    apk del dnsmasq || true
    apk add dnsmasq-full bash coreutils-nohup curl ca-certificates \
        ipset ip-full libcap ruby ruby-yaml unzip luci-compat luci-base
    # OpenClash 的界面是旧式 Lua 控制器；新版 LuCI 把 Lua 运行时拆成了独立包，
    # 装上才能渲染。老版本已内置，所以这里失败不算错误。
    apk add luci-lua-runtime || echo "提示: 没有独立的 luci-lua-runtime 包（新款已内置 Lua 运行时）"

    # --- Tailscale LuCI 界面（whzhni1/luci-app-tailscale，自带 config/init + 中文包）---
    # 不装官方 tailscale 包：它也带 etc/config/tailscale 与 etc/init.d/tailscale，
    # 与本 bundle 互相覆盖会让 apk 报错退出（实测 1 error）。
    LTS_VER=$(curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 "${GH_PROXY}https://api.github.com/repos/whzhni1/luci-app-tailscale/releases/latest" \
          | sed -n "s/.*\"tag_name\" *: *\"v\{0,1\}\([^\"]*\)\".*/\1/p" | head -n1)
    [ -n "$LTS_VER" ] || { echo "无法获取 luci-app-tailscale 版本号"; exit 1; }
    echo "luci-app-tailscale 版本: v${LTS_VER}"
    curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 -o /tmp/lts.apk \
      "${GH_PROXY}https://github.com/whzhni1/luci-app-tailscale/releases/download/v${LTS_VER}/luci-app-tailscale-${LTS_VER}-r1.apk"
    curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 -o /tmp/lts-zh.apk \
      "${GH_PROXY}https://github.com/whzhni1/luci-app-tailscale/releases/download/v${LTS_VER}/luci-i18n-tailscale-zh-cn-${LTS_VER}.apk"
    apk add --allow-untrusted /tmp/lts.apk /tmp/lts-zh.apk
    rm -f /tmp/lts.apk /tmp/lts-zh.apk

    # --- OpenClash (vernesong 官方 apk) ---
    VER=$(curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 "${GH_PROXY}https://api.github.com/repos/vernesong/OpenClash/releases/latest" \
          | sed -n "s/.*\"tag_name\" *: *\"v\{0,1\}\([^\"]*\)\".*/\1/p" | head -n1)
    [ -n "$VER" ] || { echo "无法获取 OpenClash 最新版本号"; exit 1; }
    echo "OpenClash 版本: v${VER}"
    curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 -o /tmp/openclash.apk \
      "${GH_PROXY}https://github.com/vernesong/OpenClash/releases/download/v${VER}/luci-app-openclash-${VER}.apk"
    apk add --allow-untrusted /tmp/openclash.apk
    rm -f /tmp/openclash.apk

    # --- 清理 kmod 依赖（设备用自带 5.4 内核模块，feed 模块版本不匹配）---
    # kmod-tun 例外：OpenClash 在 apk 里声明依赖它，硬删会让 apk 事务失败；
    # 设备内核 CONFIG_TUN=y 已经把 tun 编进去了，这个 .ko 永远不会被加载。
    # apk list --installed 带版本号，先切掉 -<版本>-r<修订> 只留包名。
    KMODS=$(apk list --installed 2>/dev/null | cut -d" " -f1 \
            | sed -E "s/-[0-9][^-]*-r[0-9]+$//" | grep "^kmod-" | grep -vx "kmod-tun" | sort -u || true)
    if [ -n "$KMODS" ]; then
      echo "移除 kmod 包: $(echo $KMODS | tr "\n" " ")"
      # shellcheck disable=SC2086
      apk del $KMODS || echo "提示: 有 kmod 被 ppp/firewall/sqm 等锁着，apk 拒绝整体删除（无妨，下面直接删 .ko 目录）"
    fi
    # feed 的 kmod 把 .ko 装到 /lib/modules/<内核版本>/（这台是 6.12.112），upstream 构建镜像时
    # 是 rm -rf lib/modules/6.* 清掉的，我们 apk add 之后又被带回来了，所以照样清。
    # 只删 feed 那个 kmod 版本的目录，5.4.* 一律不碰。
    FEEDREL=$(sed -n "s|.*/kmods/\([^/]*\)/packages.adb.*|\1|p" /etc/apk/repositories.d/distfeeds.list 2>/dev/null | head -n1)
    FEEDREL=${FEEDREL%-*-*}          # 6.12.112-1-67e205... -> 6.12.112
    if [ -n "$FEEDREL" ]; then
      echo "清理 feed 模块目录: /lib/modules/$FEEDREL"
      rm -rf "/lib/modules/$FEEDREL"
    fi
    # 同一逻辑的兜底：任何 <ver>-1-<hash> 形式的目录也清掉。
    # 注意 glob 没匹配到东西时 $d 是字面量，[ -d ] 为假会让整条 for 返回非零，
    # 在 set -e 下直接中断构建，所以必须写成 if 而不是 && 链。
    set +e
    for d in /lib/modules/*-1-*; do
      if [ -d "$d" ]; then rm -rf "$d"; fi
    done
    set -e
    echo "保留的内核模块目录: $(ls /lib/modules 2>/dev/null | tr "\n" " ")"

    # --- 清点两个插件的文件（只报告，不让构建失败；缺了看日志里的 MISS）---
    MISS=0
    chk() {
      if [ -e "$1" ]; then echo "  ok    $1"; else echo "  MISS  $1"; MISS=1; fi
    }
    echo "清点 OpenClash / Tailscale 的 LuCI 与程序文件："
    # OpenClash 用旧式 Lua 控制器（包里没有 menu.d JSON）：入口 controller/openclash.lua，
    # 资源 www/luci-static/resources/openclash。新版若改 menu.d/view 布局，这里只看不判。
    chk /usr/lib/lua/luci/controller/openclash.lua
    chk /www/luci-static/resources/openclash
    chk /etc/init.d/openclash
    # Tailscale 是 whzhni1 的 bundle：menu 叫 luci-app-tailscale.json，视图在 view/tailscale/
    chk /usr/share/luci/menu.d/luci-app-tailscale.json
    chk /www/luci-static/resources/view/tailscale
    chk /etc/init.d/tailscale
    chk /etc/config/tailscale
    K54=$(ls -d /lib/modules/5.4.* 2>/dev/null | head -n1 || true)
    if [ -n "$K54" ]; then echo "  ok    $K54（5.4 内核模块）"; else echo "  MISS  /lib/modules/5.4.*"; MISS=1; fi
    [ "$MISS" = "0" ] || echo "::warning::上面有 MISS 项，插件文件可能不全，请核对"

    # --- 注册开机自启（LuCI 中仍可手动启停）---
    for s in tailscale openclash; do
      [ -e "/etc/init.d/$s" ] && /etc/init.d/$s enable || true
    done

    # --- 编译署名 lhhc_02 ---
    cat > /etc/banner <<EOB
==============================================
 mu300-custom : ZTE F50 / MU300 OpenWrt
 Builder : ${BUILDER}
 Base    : ${BASE_TAG}
 Kernel  : 5.4 (vendor)
 Plugins : OpenClash(+LuCI) | Tailscale(+LuCI)
 Built   : ${BUILD_DATE}
==============================================
EOB
    cat > /etc/buildinfo <<EOB
builder=${BUILDER}
base_tag=${BASE_TAG}
built_at=${BUILD_DATE}
kernel=5.4
plugins=openclash,tailscale-luci
system=${SYSTEM_LABEL}
EOB
    # 署名只写 /etc/banner 与 /etc/buildinfo 这两个「自己的文件」。
    #
    # 不再改写 /etc/openwrt_release 和 /usr/lib/os-release：
    #   LuCI 概览页那行版本串由 procd 解析 /usr/lib/os-release 的 OPENWRT_RELEASE 得到，
    #   procd 是按空白切分 "key=value" 的，值里带空格/竖线/括号时极易解析错位，
    #   实测会出现整行乱码。收益只是网页上多一行字，风险却是整块系统信息显示异常，
    #   按需求整块去掉。看署名请用：cat /etc/buildinfo，或 SSH 登录时的 banner。
    echo "署名完成: /etc/banner + /etc/buildinfo"
    echo "固件版本(系统自带): $( ( . /etc/openwrt_release 2>/dev/null; echo "${DISTRIB_DESCRIPTION:-未知}" ) )"
  '

echo "==> [3/4] 导出容器"
docker export "${IMG}-build" -o "${REL_DIR}/rootfs-export.tar"
docker rm "${IMG}-build" >/dev/null

echo "==> [4/4] 容器内修复 Docker 残留文件并重打包"
# docker export 的 tar 带 pax 扩展头，GNU tar --delete 无法原地修改（实测报
# "Skipping to next header"），因此改为完整解包 -> 修正三个被 Docker 运行时
# 影响的文件 -> 重打包。在 root 容器内执行以保留 uid/gid，且不依赖宿主机 tar。
docker run --rm \
  -v "$(realpath "$REL_DIR"):/w" \
  -e ROOTFS="$ROOTFS" \
  alpine:3.20 sh -euc '
    mkdir -p /fix
    tar -xf /w/rootfs-export.tar -C /fix
    # docker export 会带出容器运行时生成的 /etc/hosts、/etc/hostname。
    # 优先从原始 tarball 里取回原样内容（镜像自带的 hosts 可能被上游 overlay 加过条目，
    # 无条件覆盖会丢东西），取不到才写 OpenWrt 默认值。
    for f in etc/hosts etc/hostname; do
      if { tar -xzOf "/w/${ROOTFS}.orig" "$f" 2>/dev/null || tar -xzOf "/w/${ROOTFS}.orig" "./$f" 2>/dev/null; } > /tmp/orig && [ -s /tmp/orig ]; then
        cp /tmp/orig "/fix/$f"
        echo "  还原 $f（取自原始 rootfs）"
      fi
      rm -f /tmp/orig
    done
    [ -s /fix/etc/hosts ] \
      || printf "127.0.0.1 localhost\n::1 localhost ip6-localhost ip6-loopback\n" > /fix/etc/hosts
    [ -s /fix/etc/hostname ] || printf "OpenWrt\n" > /fix/etc/hostname
    printf "nameserver 127.0.0.1\nsearch lan\n" > /fix/etc/resolv.conf
    tar -C /fix -czf /w/rootfs-fixed.tar.gz .
    rm -f /w/rootfs-export.tar
    echo "  重打包完成"
  '
mv "${REL_DIR}/rootfs-fixed.tar.gz" "$SRC"

NEWHASH="$(sha256sum "$SRC" | cut -d' ' -f1)"
echo "完成: ${SRC}"
echo "新 sha256: ${NEWHASH}"
echo "原始备份: ${SRC}.orig（如需回退: cp ${SRC}.orig ${SRC}）"
