# 移植 ROM 上的 VoWiFi（WiFi 通话）

在一个本来不支持 VoWiFi 的移植 ROM 上，把 WiFi 通话真正跑通 —— **SIP 注册、双向短信、语音通话**，
不改 modem、不需要平台签名。

打包成一个 KernelSU 模块。同时附带完整的移植指南、全部源码补丁、构建流水线和诊断脚本。

*[English version](README.en.md)*

> ### ⚠️ 刷之前请先读这段
>
> **预编译的模块只在一个组合上构建和实测过：**
>
> | | |
> |---|---|
> | 机型 | **Redmi K50 至尊版 / 小米 12T Pro**（`diting`，`22081212C`） |
> | ROM | **酷安 [@江南烟雨断桥殇](https://www.coolapk.com/) 的澎湃 OS4 移植包** |
> | 安卓 | **Android 17（API 37）** |
> | 运营商 | 英国 VOXI（Vodafone 的 MVNO，234-15），境外漫游、走普通 WiFi |
>
> **同机型同 ROM？** 直接刷，应该能用。
>
> **其他情况？** 安装脚本会警告，但仍然允许你装 —— 本模块不动任何分区，随时可以卸载。
> 但请预期它**开箱不能用**，最典型的表现是框架始终不报 `isVowifiEnabled=true`。
> **[PORTING-GUIDE.md](PORTING-GUIDE.md) 就是为这种情况写的** ——
> 它讲清了哪些部分是框架通用机制、哪些必须针对你自己的 ROM 重做
> （最低限度：拿**你自己 ROM 的 `framework.jar`** 重新编译那个 IMS APK）。
>
> 这不是任何官方版本，不提供任何保证，而且你的运营商可能明确禁止这种用法。
> 见[许可与免责](#许可与免责)。

## 快速开始（机型匹配的情况）

1. 在 KernelSU 管理器里刷 `code/module/vowifi-stack-v6.zip`
2. **重启。** 特权权限是在开机扫描软件包时评估的，不重启不可能生效。
3. 在系统设置里打开 WiFi 通话
4. 检查状态：在 KernelSU 管理器里点这个模块的 **Action** 按钮，或者跑
   ```sh
   su -c 'sh /data/local/tmp/phh_status.sh'
   ```

健康的空闲状态大致是：1~2 个 established socket + 1 个 listening，
`SAs` 非零且分属两个 `reqid`，`dangling: 0`，`capabil.: 11`。

`SAs` 是 0 说明隧道根本没建起来。`capabil.` 不是 `11` 说明 IMS 服务没把能力上报给框架 ——
去看 `/data/local/tmp/vowifi_stack_boot.log` 里有没有权限相关的警告。

## 它到底在做什么

有四件事必须同时成立，而且**彼此独立** ——
这类项目里浪费掉的时间，大多来自把其中一件误认成另一件：

| | 要做什么 | 由谁来做 |
|---|---|---|
| 1 | 对运营商的 ePDG 跑 IKEv2 + EAP-AKA，建立 IPsec 隧道 | 移植过来的 AOSP `Iwlan` |
| 2 | 让框架相信 IMS 该走 WLAN 而不是蜂窝 | 一个最小的 `QualifiedNetworksService` |
| 3 | 在那条隧道里说 SIP/MMTEL | 打过补丁的 [phh floss-ims](https://github.com/phhusson/ims) |
| 4 | 让框架把**你的**服务绑定为 MMTEL 提供方 | carrier config 覆盖键 |

**让这件事成立的关键认知**：在高通设备上，这四件事通常都由 modem 掌管，而你伸不进去。
但安卓的电话框架允许一个 carrier app 逐个接管它们 ——
`ImsResolver` 会绑定任意一个包作为 MMTEL 提供方，而 `IwlanDataService` 就是普通的 AOSP Java 代码。
所以整套栈可以搬到应用处理器侧，把 modem 完全排除在外。
**这就是为什么它能在一台 modem 明确拒绝 VoWiFi 的设备上跑起来。**

## 完成度

| | |
|---|---|
| 在真实 ePDG 隧道上的 SIP 注册 | ✅ 已验证，能扛住 P-CSCF 每小时一次的主动断连 |
| 接收短信 | ✅ 已验证 |
| 发送短信 | ✅ 已验证到 `RP-ACK` |
| **拨出通话** | ✅ **已验证** —— 接通、双向 AMR 语音、通话计时正确 |
| **来电** | ⚠️ 让来电必断的那个 bug 已定位并修复，**但修复本身还没用真实来电复测过** |

以上全部是**一台设备、一个运营商**的结果。框架层的机制是通用的，具体数值不是。

## 仓库结构

```
PORTING-GUIDE.md              正文指南：架构、分阶段验收标准，
                              以及真正花掉时间的每一个坑
docs/carrier-voxi-uk.md       一个运营商的具体数值，当作填好的样例看
docs/module-internals.md      模块怎么工作、为什么必须有 service.sh

code/module/                  KernelSU 模块（含预编译 zip）
code/patches/                 对 floss-ims 的全部源码改动，一个补丁文件
code/build/                   构建流水线：aapt2 → javac/kotlinc → d8 → 签名
code/minqns/                  最小 QualifiedNetworksService（源码）
code/diagnostics/             健康检查 / 状态总览 / 看门狗 + 测试脚本
```

`code/patches/floss-ims-local.patch` 里写明了它对应的上游 commit，
并且已验证：对该 commit **零 fuzz** 应用，且应用后与实际编译出工作 APK 的源码逐字节一致。
补丁头部逐条列出了每处改动和原因。

## 想改成适配你自己的设备

从 [PORTING-GUIDE.md](PORTING-GUIDE.md) 开始。哪些东西是设备相关的，简短版：

- **IMS APK 必须拿你自己 ROM 的 `framework.jar` 重新编译。**
  各家 vendor 改过框架签名 —— 澎湃的 `notifyCapabilitiesStatusChanged`
  参数类型就和 AOSP 不一样，而正是这个调用负责告诉框架"这套栈能做 WiFi 通话"。
- **`targetSdk 28` 是有实际作用的**，不是随手写的。
  它是让 `MAX-TARGET-O` 那批隐藏 API 变得可达的原因。
  我在这上面白烧了六个构建版本去写反射，才发现一行打包参数就能替代全部工作。
- **运营商的 ePDG / IMS 数值来自 SIM 卡和 carrier config**，不在这个模块里。
  `docs/carrier-voxi-uk.md` 演示了要去找哪些东西。

另外，在动手移植之前先确认你是否真的需要 ——
如果一个 ROM 的 IMS 栈本身能工作、只是被 carrier config 关掉了，那是个小得多的问题。
指南开头就讲了怎么判断。

## 致谢

- **[phhusson/ims](https://github.com/phhusson/ims)** —— 本项目所依赖的 floss-ims
  MMTEL/SIP 实现。没有它就没有这一切。GPL-2.0。
- **AOSP `packages/services/Iwlan`** —— ePDG / IKEv2 的实现。Apache-2.0。
- **酷安 @江南烟雨断桥殇** —— 本项目所针对的 `diting` 澎湃 OS4 移植包。
- 这里的补丁和整合工作是我做的；每处改动是什么、为什么，见补丁头部。

**这里没有任何新的研究成果。** AOSP Iwlan、floss-ims、carrier config 覆盖机制
都早于这项工作存在。被写下来的是整合过程和那些失败形态。

## 许可与免责

- floss-ims 是 GPL-2.0，`code/patches/` 里的补丁是其衍生物，沿用同一许可。
  为简单起见，我自己写的脚本和模块也一并按 GPL-2.0 提供。
- **刻意没有包含**：签名密钥库、带隐藏 API 的 `android.jar`、
  以及任何从 ROM 里抽出来的 `framework.jar`/dex。
  你本来就需要你自己 ROM 的 framework jar，而重新分发 vendor 的东西不是我该做的事。
- **仓库里不含任何 IMSI、ICCID 或电话号码** —— 补丁注释里出现过的都已替换成占位符。
- **你的运营商可能禁止这种用法。** 我这家的条款写着漫游时使用 WiFi Calling
  "prohibited and not supported"（禁止且不受支持）—— 这同时意味着**计费行为是未定义的**。
  请实测，不要照着资费表推断；`docs/carrier-voxi-uk.md` 里有实测数据，
  包括一处我"合理推断"结果完全错误的例子。
- 不提供任何保证。这改变的是你手机拨打电话的方式，**可能包括紧急呼叫**。
  在依赖它之前请理解这一点。
