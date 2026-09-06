# luci-app-ipsec-vpnd

LuCI support for IPSec VPN Server（IKEv1 with PSK and Xauth），运行于 strongSwan。

## 目录结构

```
├── Makefile                 # luci-app-ipsec-vpnd 本体（LuCI 应用）
├── deps/strongswan/         # vendor 的 strongSwan 6.0.3 包源码（见下）
├── htdocs/ root/ po/        # LuCI 前端 / 系统文件 / 翻译
```

## 为什么自带 deps/strongswan

ImmortalWrt **25.12.0 / 25.12.1 官方软件源未收录 strongswan 包集**（OpenWrt 官方 25.12 源有，
ImmortalWrt 24.10 源也有，唯独 25.12 系列全架构缺失），导致本应用的依赖
`strongswan / strongswan-minimal / strongswan-mod-xauth-generic / strongswan-mod-kernel-libipsec`
在 ImageBuilder / apk 源里无法解析，封装时报「缺少依赖包 strongswan」。

为不依赖外部软件源，将依赖源码随项目一起维护：

- 来源：`immortalwrt/packages` 仓库 `openwrt-25.12` 分支 `net/strongswan`（strongSwan 6.0.3，PKG_RELEASE 2）
- 内容与上游逐文件一致（git blob SHA 校验），含 `Makefile`、`Config.in`、`files/`、`patches/`
- 升级 strongSwan 时整目录替换并同步更新，勿单独改动内部文件

## 编译用法

在 SDK / 完整源码树中，将依赖以「本地包」形式加入构建：

```sh
# 1. 把依赖包链到构建树的 package/ 下（macOS 可用 cp -R 代替 ln -s）
ln -s /path/to/luci-app-ipsec-vpnd/deps/strongswan <buildroot>/package/strongswan

# 2. luci-app-ipsec-vpnd 本体照常放入 luci feed（或 package/）

# 3. menuconfig 启用依赖（Network → VPN）：
#    strongswan / strongswan-minimal / strongswan-mod-xauth-generic /
#    strongswan-mod-kernel-libipsec（OpenWrt 会按 DEPENDS 自动勾选），
#    并保证 kdf/openssl/wolfssl 三个 crypto 后端至少启用一个
make menuconfig

# 4. 编译
make package/strongswan/compile V=s
make package/luci-app-ipsec-vpnd/compile V=s
```

## 交付 ImageBuilder（apk 本地源）

ImageBuilder 只吃软件源，不吃源码。编出 `strongswan` 系列 .apk 后，
与 `luci-app-ipsec-vpnd` 的 .apk 一起放进 `szwjp/luci` store 的 `ipsec-vpnd/` 目录，
再经 `custom-packages.sh` 集成，依赖解析即可通过。
