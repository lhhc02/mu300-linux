#!/usr/bin/env bash
# mu300-linux 定制 rootfs 构建脚本（署名 lhhc_02）
#
# 用法: customize-rootfs.sh <release目录> <system> <builder> <tag>
#   release目录: 含官方 release 资产的目录（custom-rootfs.yml 下载的那一套）
#   system:      openwrt | openwrt-luci
#   builder:     编译者署名，写入 /etc/banner、/etc/buildinfo、/etc/openwrt_release
#   tag:         所基于的官方 release tag（记录用）
#
# 自带插件（两个都带 LuCI 界面，装完进 LuCI 就能点开）:
#   - OpenClash : luci-app-openclash（vernesong 官方 release 的 .apk，界面自带）
#   - Tailscale : tailscale(守护进程/CLI) + luci-app-tailscale-community(+zh-cn)
#                 25.12 官方 feed 自带，不依赖任何第三方 bundle
#
# 内核：这个 rootfs 只配 5.4。/lib/modules/5.4.254-gb50db5b6224c 已经在镜像里；
#       内核 Image 不在 rootfs 内，由 mu300-kernel.tar.gz 写进 boot image 的 B 槽。
#
# 做的事:
#   1. 保留原始 rootfs 为 .orig（回退能力，永不覆盖原始输入）
#   2. docker import 为 arm64 容器，在容器内:
#      - dnsmasq -> dnsmasq-full（OpenClash 前置要求）
#      - 装 Tailscale / OpenClash（都带 LuCI）
#      - 清理 feed 的 kmod 包与 6.12 模块目录（设备跑 5.4 自带模块；
#        kmod-tun 保留，设备内核 CONFIG_TUN=y 已内建，tailscale 只是声明依赖）
#      - 校验两个插件的 LuCI 菜单/视图/程序文件都在，缺一个就让构建失败
#      - 写入 /etc/banner + /etc/buildinfo + /etc/openwrt_release 编译署名
#        （openwrt_release 的 DISTRIB_DESCRIPTION 会显示在 LuCI 概览页）
#   3. docker export -> 修复 Docker 注入的 resolv.conf/hosts/hostname -> gzip
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
  -e SYSTEM_LABEL="$SYSTEM" \
  "${IMG}:base" /bin/sh -euc '
    if [ -n "${OPENWRT_MIRROR:-}" ]; then
      sed -i "s_https\?://downloads.openwrt.org_${OPENWRT_MIRROR}_" /etc/apk/repositories.d/distfeeds.list 2>/dev/null || true
    fi
    apk update
    apk upgrade

    # --- OpenClash 依赖: dnsmasq 换 dnsmasq-full ---
    apk del dnsmasq
    apk add dnsmasq-full bash coreutils-nohup curl ca-certificates \
        ipset ip-full libcap ruby ruby-yaml unzip luci-compat luci-base

    # --- Tailscale: 官方 feed 的守护进程 + community LuCI 界面 ---
    apk add tailscale luci-app-tailscale-community
    apk add luci-i18n-tailscale-community-zh-cn >/dev/null 2>&1 \
      || echo "提示: feed 里没有 tailscale 中文语言包，界面维持英文"

    # --- OpenClash (vernesong 官方 apk，自带 LuCI 界面) ---
    VER=$(curl -fsSL "${GH_PROXY}https://api.github.com/repos/vernesong/OpenClash/releases/latest" \
          | sed -n "s/.*\"tag_name\": *\"v\([^\"]*\)\".*/\1/p" | head -n1)
    [ -n "$VER" ] || { echo "无法获取 OpenClash 最新版本号"; exit 1; }
    echo "OpenClash 版本: v${VER}"
    curl -fsSL -o /tmp/openclash.apk \
      "${GH_PROXY}https://github.com/vernesong/OpenClash/releases/download/v${VER}/luci-app-openclash-${VER}.apk"
    apk add --allow-untrusted /tmp/openclash.apk
    rm -f /tmp/openclash.apk

    # --- 清理 kmod 依赖（设备用自带 5.4 内核模块，feed 模块版本不匹配）---
    # kmod-tun 例外：tailscale 在 apk 里声明依赖它，硬删会让 apk 事务失败；
    # 设备内核 CONFIG_TUN=y 已经把 tun 编进去了，这个 .ko 永远不会被加载。
    # apk list --installed 带版本号，先切掉 -<版本>-r<修订> 只留包名。
    KMODS=$(apk list --installed 2>/dev/null | cut -d" " -f1 \
            | sed -E "s/-[0-9][^-]*-r[0-9]+$//" | grep "^kmod-" | grep -vx "kmod-tun" | sort -u || true)
    if [ -n "$KMODS" ]; then
      echo "移除 kmod 包: $(echo $KMODS | tr "\n" " ")"
      # shellcheck disable=SC2086
      apk del $KMODS || echo "提示: 有 kmod 被依赖，apk 拒绝整体删除，保持原样（不影响运行）"
    fi
    echo "剩余 kmod: $(apk list --installed 2>/dev/null | cut -d" " -f1 | grep "^kmod-" | tr "\n" " ")"
    # 刚装的 apk 会把 feed 的 6.12 模块目录带回来（kmod-tun 等），设备只跑 5.4，
    # 这些 feed 模块一律没用。只删 feed 的目录（名字形如 6.12.112-1-67e205...），
    # 5.4.254-gb50db5b6224c 必须留着，那是设备真正要用的模块。
    for d in /lib/modules/6.*-1-*; do [ -d "$d" ] && rm -rf "$d"; done
    echo "保留的内核模块目录: $(ls /lib/modules 2>/dev/null | tr "\n" " ")"

    # --- 校验两个插件都真的带 LuCI（缺一个就让构建失败）---
    MISS=0
    chk() {
      if [ -e "$1" ]; then echo "  ok    $1"; else echo "  MISS  $1"; MISS=1; fi
    }
    echo "校验 OpenClash / Tailscale 的 LuCI 与程序文件："
    chk /usr/share/luci/menu.d/luci-app-openclash.json
    chk /www/luci-static/resources/view/openclash
    chk /etc/init.d/openclash
    chk /usr/share/luci/menu.d/luci-app-tailscale-community.json
    chk /www/luci-static/resources/view/tailscale.js
    chk /usr/sbin/tailscaled
    chk /etc/init.d/tailscale
    # 5.4 的模块目录按内核 ABI 命名，上游升一次 KREL 名字就变，所以只认 5.4.* 前缀
    K54=$(ls -d /lib/modules/5.4.* 2>/dev/null | head -n1 || true)
    if [ -n "$K54" ]; then echo "  ok    $K54（5.4 内核模块）"; else echo "  MISS  /lib/modules/5.4.*"; MISS=1; fi
    [ "$MISS" = "0" ] || { echo "错误: 上面的插件缺少文件，构建终止"; exit 1; }

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
plugins=openclash-luci,tailscale-luci
system=${SYSTEM_LABEL}
EOB
    # LuCI 概览页「固件版本」一行读 /etc/openwrt_release 的 DISTRIB_DESCRIPTION
    # （rpcd 的 system board 接口），在原描述后追加署名，让网页端也能看到编译信息。
    # 注意：不要把这一步写成 sed s|...|...|，署名文本里含 "|" 会被当成分隔符，
    # 实测报 "sed: bad option in substitution expression" 并中断构建。
    # 这里改为逐行重写，完全避开 sed 的转义/分隔符问题。
    cp -a /etc/openwrt_release /etc/openwrt_release.orig 2>/dev/null || true
    # shellcheck disable=SC1091
    . /etc/openwrt_release 2>/dev/null || true
    NEWDESC="${DISTRIB_DESCRIPTION:-OpenWrt} | custom by ${BUILDER} (base ${BASE_TAG})"
    DESC_LINE="DISTRIB_DESCRIPTION=\"${NEWDESC}\""
    : > /etc/openwrt_release.new
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        DISTRIB_DESCRIPTION=*) printf "%s\n" "$DESC_LINE" >> /etc/openwrt_release.new ;;
        *)                     printf "%s\n" "$line"      >> /etc/openwrt_release.new ;;
      esac
    done < /etc/openwrt_release
    mv /etc/openwrt_release.new /etc/openwrt_release
    echo "署名完成: /etc/banner + /etc/buildinfo + /etc/openwrt_release"
    echo "固件版本: ${NEWDESC}"
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
  alpine:3.20 sh -euc '
    apk add -q tar >/dev/null 2>&1 || true
    mkdir -p /fix
    tar -xf /w/rootfs-export.tar -C /fix
    rm -f /fix/etc/resolv.conf /fix/etc/hosts /fix/etc/hostname
    printf "nameserver 127.0.0.1\nsearch lan\n"          > /fix/etc/resolv.conf
    printf "127.0.0.1 localhost\n\n::1 localhost ip6-localhost ip6-loopback\n" > /fix/etc/hosts
    printf "OpenWrt\n"                                   > /fix/etc/hostname
    tar -C /fix -czf /w/rootfs-fixed.tar.gz .
    rm -f /w/rootfs-export.tar
  '
mv "${REL_DIR}/rootfs-fixed.tar.gz" "$SRC"

NEWHASH="$(sha256sum "$SRC" | cut -d' ' -f1)"
echo "完成: ${SRC}"
echo "新 sha256: ${NEWHASH}"
echo "原始备份: ${SRC}.orig（如需回退: cp ${SRC}.orig ${SRC}）"
