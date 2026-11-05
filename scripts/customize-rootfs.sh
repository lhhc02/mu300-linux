#!/usr/bin/env bash
# mu300-linux 定制 rootfs 构建脚本（署名 lhhc_02）
#
# 用法: customize-rootfs.sh <release目录> <system> <builder> <tag>
#   release目录: 含官方 release 资产的目录（magisk.yml 下载的那一套）
#   system:      openwrt | openwrt-luci
#   builder:     编译者署名，写入 /etc/banner 和 /etc/buildinfo
#   tag:         所基于的官方 release tag（记录用）
#
# 做的事:
#   1. 保留原始 rootfs 为 .orig（回退能力，永不覆盖原始输入）
#   2. docker import 为 arm64 容器，在容器内:
#      - dnsmasq -> dnsmasq-full（OpenClash 前置要求）
#      - apk add tailscale adguardhome（OpenWrt 25.12 官方 feed）
#      - 安装 vernesong/OpenClash 最新版 apk 包
#      - 清理所有 kmod-* 包（设备使用 mu300 自带 5.4 内核模块）
#      - 写入 /etc/banner 与 /etc/buildinfo 编译署名
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

    # --- 官方 feed 插件 ---
    apk add tailscale adguardhome

    # --- OpenClash (vernesong 官方 apk) ---
    VER=$(curl -fsSL "${GH_PROXY}https://api.github.com/repos/vernesong/OpenClash/releases/latest" \
          | sed -n "s/.*\"tag_name\": *\"v\([^\"]*\)\".*/\1/p" | head -n1)
    [ -n "$VER" ] || { echo "无法获取 OpenClash 最新版本号"; exit 1; }
    echo "OpenClash 版本: v${VER}"
    curl -fsSL -o /tmp/openclash.apk \
      "${GH_PROXY}https://github.com/vernesong/OpenClash/releases/download/v${VER}/luci-app-openclash-${VER}.apk"
    apk add --allow-untrusted /tmp/openclash.apk
    rm -f /tmp/openclash.apk

    # --- 清理 kmod 依赖（设备用自带 5.4 内核模块，feed 模块版本不匹配）---
    KMODS=$(apk info 2>/dev/null | grep "^kmod-" || true)
    if [ -n "$KMODS" ]; then
      echo "移除 kmod 包: $KMODS"
      # shellcheck disable=SC2086
      apk del $KMODS || true
    fi

    # --- 注册开机自启（LuCI 中仍可手动启停）---
    for s in tailscale adguardhome openclash; do
      [ -e "/etc/init.d/$s" ] && /etc/init.d/$s enable || true
    done

    # --- 编译署名 lhhc_02 ---
    cat > /etc/banner <<EOB
==============================================
 mu300-custom : ZTE F50 / MU300 OpenWrt
 Builder : ${BUILDER}
 Base    : ${BASE_TAG}
 Plugins : OpenClash | Tailscale | AdGuard Home
 Built   : ${BUILD_DATE}
==============================================
EOB
    cat > /etc/buildinfo <<EOB
builder=${BUILDER}
base_tag=${BASE_TAG}
built_at=${BUILD_DATE}
plugins=openclash,tailscale,adguardhome
system=${SYSTEM_LABEL}
EOB
    echo "署名完成: /etc/banner + /etc/buildinfo"
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
