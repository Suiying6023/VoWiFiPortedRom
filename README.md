# 移植 ROM 上的 VoWiFi

尝试在不支持 VoWiFi 的移植 ROM 上跑通 WiFi 通话：SIP 注册、双向短信、语音通话。
本项目不改 modem，不需要平台签名，目前打包为 KernelSU 模块。

## 适用范围

预编译模块只在此情况下构建和实测过：

| | |
|---|---|
| 机型 | Redmi K50 至尊版 / 小米 12T Pro（`diting`） |
| ROM | 酷安 @江南烟雨断桥殇 的澎湃 OS4 移植包 |
| 安卓 | Android 17（API 37） |
| 运营商 | 英国 VOXI（Vodafone MVNO，234-15），境外漫游 |

若不一致，安装脚本会给出警告，但不会阻止安装。模块不改动任何分区、可随时卸载，
尝试的代价很低；只是没有把握可以工作，最常见的表现是框架始终不报
`isVowifiEnabled=true`。这种情况建议先读 [PORTING-GUIDE.md](PORTING-GUIDE.md)，
其中区分了哪些属于安卓框架层的通用机制、哪些需要针对具体 ROM 重做。

## 安装

刷入 `code/module/vowifi-stack-v6.zip`，**重启**，然后在系统设置中打开 WiFi 通话。

重启不可省略：特权权限是在开机扫描软件包时评估的，不重启不会生效。

查看状态可以点 KernelSU 管理器里模块的 Action 按钮，或者执行：

```sh
su -c 'sh /data/local/tmp/phh_status.sh'
```

健康的空闲状态大致为：1~2 个 established socket 加 1 个 listening，`SAs` 非零且分属
两个 `reqid`，`dangling: 0`，`capabil.: 11`。

`SAs=0` 说明隧道未建立。`capabil.` 不是 `11` 说明 IMS 服务没有把能力上报给框架，
可查看 `/data/local/tmp/vowifi_stack_boot.log` 中有无权限相关的警告。

## 原理

四件事必须同时成立，而且彼此独立：

| | | |
|---|---|---|
| 1 | 对 ePDG 跑 IKEv2 + EAP-AKA 建 IPsec 隧道 | 移植的 AOSP `Iwlan` |
| 2 | 让框架相信 IMS 走 WLAN 而非蜂窝 | 最小 `QualifiedNetworksService` |
| 3 | 在隧道里说 SIP/MMTEL | 打过补丁的 [phh floss-ims](https://github.com/phhusson/ims) |
| 4 | 把上面这些绑定为 MMTEL 提供方 | carrier config 覆盖键 |

高通平台上这四件事通常都由 modem 掌管，外部难以介入，移植 ROM 往往就卡在这里。

安卓的电话框架留有余地：carrier app 可以逐个接管这些职责。`ImsResolver`
允许绑定任意一个包作为 MMTEL 提供方，`IwlanDataService` 也只是普通的 AOSP Java 代码。
整套栈因此可以搬到应用处理器侧运行，把 modem 绕开 ——
这也是 modem 本身拒绝 VoWiFi 的机器仍能跑通的原因。

## 完成度

| | |
|---|---|
| SIP 注册（真实 ePDG 隧道上） | ✅ 可承受 P-CSCF 每小时一次的主动断连 |
| 收 / 发短信 | ✅ 发送已确认到 `RP-ACK` |
| 拨出通话 | ✅ 接通、双向 AMR 语音、通话计时正确 |
| 来电 | ⚠️ 致命 bug 已定位并修复，但尚未用真实来电复测 |

样本仅一台设备、一张 SIM 卡。框架层的机制可以照搬，具体数值不能。

## 结构

```
PORTING-GUIDE.md       正文：架构、分阶段验收标准，以及真正耗费时间的那些坑
docs/                  运营商的具体数值（可作样例参考）、模块实现细节
code/patches/          对 floss-ims 的全部源码改动，合为一个补丁
code/module/           KernelSU 模块（含预编译 zip）
code/build/            构建流水线：aapt2 → javac/kotlinc → d8 → 签名
code/minqns/           最小 QualifiedNetworksService 源码
code/diagnostics/      健康检查 / 状态总览 / 看门狗 / 测试脚本
```

补丁标注了对应的上游 commit，可零 fuzz 应用，且应用后与编译出可用 APK 的源码逐字节
一致。每处改动的内容与原因都列在补丁头部。

## 迁移到其他设备需要改动的部分

- **IMS APK 需用目标 ROM 的 `framework.jar` 重新编译。**
  各家 vendor 都改过框架，澎湃的 `notifyCapabilitiesStatusChanged` 参数类型即与 AOSP
  不同，而这个调用正是负责向框架声明"本栈支持 WiFi 通话"的环节。
- **`targetSdk 28` 有实际作用**，`MAX-TARGET-O` 那批隐藏 API 依赖它才可达。
  这一行参数省掉了六个版本的反射尝试。
- **ePDG 与 IMS 的相关地址来自 SIM 卡和 carrier config**，模块中并不包含。

动手之前建议先确认是否确有必要：如果 ROM 自带的 IMS 栈本身可用、仅被 carrier config
关闭，那只是覆盖几个键的小改动。判断方法见指南开头。

