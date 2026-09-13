# 移植 ROM 上的 VoWiFi

为 Redmi K50 至尊版的 HyperOS 移植 ROM 提供 VoWiFi 注册与短信通道，打包为一个 KernelSU 模块。

当前维护目标是**收短信、按期产生有效账户活动以保号，以及可以恢复部署**。
2026-09-13 用户反馈接打电话仍失败，语音保留为已知限制。

## 适用范围

仅验证过 `diting`、酷安 @江南烟雨断桥殇 的澎湃 OS4 移植包、Android 17 / API 37、英国 VOXI。
其他 ROM 需要按 [移植指南](PORTING-GUIDE.md) 重新适配；模块会改变 IMS 提供方，可能影响通话和短信。

## 安装与检查

下载 [Release 模块](https://github.com/Suiying6023/VoWiFiPortedRom/releases/latest)，在 KernelSU 中安装后重启。
v7 包含手机实际使用的 **Iwlan v13、phh v43 和 MinQns v1**，以及三个组件的权限白名单。

在模块的 Action 中查看状态，或运行：

```sh
su -c 'sh /data/local/tmp/phh_status.sh'
```

健康空闲状态应有至少一个 established socket、一个监听 socket、分属两个 UID 的 IPsec SA、
`dangling=0`、近期注册授权和一个看门狗。无 WiFi 时显示 `WAIT`。
这些指标说明本地注册链路正常；**短信投递、实际扣费与保号期限要分别核实**。

## 保号

取消 VOXI 包月后仍可按标准资费使用充值余额。其正式条款把充值、购买套餐或收费外发活动都计为有效使用。
建议按 **150 天**留出余量；用收费短信时核对实际扣费，通道不可用时可在账户网页充值。
具体依据、操作记录和恢复方法见 [保号与维护](docs/maintenance.md)。

## 构建与结构

从仓库中的预编译组件生成安装包，只需 Python：

```sh
python code/build/package_module.py
python -m unittest discover -s code/tests -v
```

输出为 `code/module/vowifi-stack-v7.zip`。打包前验证载荷 SHA-256，ZIP 内附完整校验清单。
脚本、诊断工具、三个 APK 和权限文件分别保存在 `code/module/`、`code/diagnostics/`；
生成的 ZIP 不重复存入 Git，发布到 Release。

phh 的源码补丁与构建参考见 `code/patches/`、`code/build/`，最小 QNS 源码见 `code/minqns/`。
重新编译 APK 仍需目标 ROM 的框架文件与本地 Android 工具链；与上述打包步骤不同。

部署细节见 [模块说明](docs/module-internals.md)，移植过程见 [PORTING-GUIDE.md](PORTING-GUIDE.md)。
项目脚本及 phh 衍生补丁按 GPL-2.0 发布，见 [LICENSE](LICENSE)。
