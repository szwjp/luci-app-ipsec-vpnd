#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# 标准 OpenWrt/ImmortalWrt SDK 编译脚本（测试用途）
# 与 .github/build-pkg.sh（无 SDK 直接组包）方案对比。
# 流程遵循官方标准：feeds update/install -> 包源码放入 package/ ->
# make defconfig -> make package/<name>/compile
#
# 用法: bash build-sdk.sh <sdk目录> [包源码目录]
# 示例: bash build-sdk.sh /path/to/immortalwrt-sdk /path/to/luci-app-ipsec-vpnd

set -euo pipefail

SDK_DIR="${1:?usage: build-sdk.sh <sdk-dir> [src-dir]}"
SRC_DIR="${2:-$(cd "$(dirname "$0")/.." && pwd)}"
PKG_NAME="luci-app-ipsec-vpnd"

cd "$SDK_DIR"

echo "==> [1/4] feeds update/install"
# 官方标准是全量 ./scripts/feeds update -a；此处仅拉取 luci feed 加速
# （luci.mk 与 tools/po2lmo 均来自 luci feed，编译本包不需要其他 feed）
./scripts/feeds update luci
./scripts/feeds install -a

echo "==> [2/4] 复制包源码到 package/$PKG_NAME"
rm -rf "package/$PKG_NAME"
cp -r "$SRC_DIR" "package/$PKG_NAME"
rm -rf "package/$PKG_NAME/.git" "package/$PKG_NAME/.github"

echo "==> [3/4] make defconfig"
make defconfig

echo "==> [4/4] make package/$PKG_NAME/compile"
make -j"$(nproc)" "package/$PKG_NAME/compile" V=s

echo "==> 产物列表"
find bin/packages -type f -name "*${PKG_NAME}*"
