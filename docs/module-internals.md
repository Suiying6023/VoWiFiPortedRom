# VoWiFi 栈 —— KernelSU 模块

一次刷入部署整套 WiFi 通话栈：**注册、双向短信、语音通话**，
已在 Redmi K50 至尊版（澎湃 OS 移植包 / Android 17，英国 VOXI eSIM）上全部实测可用。

## 模块内容，以及为什么是三个包而不是一个

| 包 | 职责 | uid / `reqid` |
|---|---|---|
| `com.google.android.iwlan` | AOSP Iwlan —— 建立 ePDG IPsec 隧道 | 隧道 SA |
| `me.phh.ims` | phh floss-ims —— SIP、MMTEL、短信、语音媒体 | sec-agree 传输 SA |
| `com.voxi.minqns` | 最小 QualifiedNetworksService —— 告诉框架"IMS 走 IWLAN" | — |

把三者合并为单个 APK 技术上可行（已核查：任何地方都不依赖
`Build.VERSION`、`PendingIntent` 可变性或带类型的前台服务，可以共用 targetSdk 28），
但**刻意没有这么做**。独立的 uid 正是 `ip xfrm state` 的 `reqid`
字段能区分隧道 SA 与传输 SA 的前提，而这是本项目最有用的单项诊断依据。
保持独立还便于单独开关做 A/B 测试。一个模块已经解决了"一步部署"的问题，
无须为此放弃上述优势。

## 安装

在 KernelSU 管理器中刷入，然后**重启** —— 特权权限是开机扫描软件包时
从 priv-app manifest 评估的，重启之前不会生效。

开机后查看发生了什么：

```sh
su -c 'sh /data/local/tmp/phh_status.sh'      # 一屏看完整个栈的状态
cat /data/local/tmp/vowifi_stack_boot.log     # service.sh 这次开机做了什么
```

健康的空闲状态：1~2 个 established socket、1 个 listening、
`SAs: 6` 分属两个 `reqid`、`dangling: 0`、`capabil.: 11`。

## carrier config 为什么不是文件 overlay

三个 APK 和两份 privapp 白名单是普通的 `system/` overlay。
那七条 **carrier config 覆盖键不是** —— 它们位于
`/data/user_de/0/com.android.phone/files` 下 `com.android.phone` 的运行时缓存中，
文件名里含 SIM 卡的 ICCID，而且平台会重建该文件。因此 `service.sh`
等开机完成后再等 30 秒，每次开机重新注入。文件名通过 glob 推导而非硬编码 ICCID，
保留一份 `.bak.vowifi_stack` 备份，键已存在时跳过写入，
自身编辑结果看起来不对时拒绝提交。

这些键以**（包名, 类名）成对**出现 —— 只注入一半，框架会静默地继续指向原厂组件，
表现恰好就是"模块没起作用"。

## 卸载

`uninstall.sh` 从备份还原 carrier config。这一步很重要：
直接删除模块只是卸掉了 APK 的挂载，框架却仍指向已不存在的包，
可能导致手机**完全没有可用的 IMS**。

## 本模块不做什么

- 不配置运营商的 ePDG 地址、APN 或 IMS APN —— 这些来自 SIM 卡和
  carrier config，因运营商而异。
- 不默认启用看门狗。只有你亲手把 `/data/local/tmp/phh_watchdog.sh` 放过去，
  `service.sh` 才会启动它 —— 因为该脚本可以 force-stop IMS 服务，
  这不是模块应该替人做的决定。
- 不碰 `data_roaming`。值得知道的一点：隧道是在 `data_roaming1=1` 时建立的，
  但**在它为 0 时持续运行正常**（已实测），所以不必开着漫游数据产生费用。

## 计费实测而非推断

- 呼叫 `191`（Vodafone/VOXI 客服）：**免费**，已确认。
- 漫游状态发短信：**收费**。一条 £0.24 —— 不从套餐的"无限英国短信"里扣，那是英国境内限定。
- 收短信：免费。
- Vodafone 自己的条款写明漫游时使用 Wi-Fi Calling 属于 "prohibited and not supported"，
  所以这是运营商未定义的路径。不要假定套餐额度适用；依赖之前先实测。

## 构建来源

`floss-ims-local.patch` 基于 `github.com/phhusson/ims` 的 commit `c180bdf`
（注意仓库名是 `phhusson/ims`，不是 `phhusson/floss-ims`）。这里的 phh APK 为 v39。
语音通话需要 `targetSdk 28`（为了 MAX-TARGET-O 那批隐藏 API）**和**
`RECORD_AUDIO` 权限 —— 两者都来自构建流水线中手写的 manifest，不来自补丁。
