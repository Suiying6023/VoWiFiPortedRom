# 在移植 ROM 上跑通 VoWiFi（WiFi 通话）

一份实战记录，附带可用的代码：在 ROM 本身不支持的手机上，把 WiFi 通话
—— **SIP 注册、双向短信、语音通话** —— 真正跑通。

参考设备：Redmi K50 至尊版，澎湃 OS4 移植包（Android 17），英国 VOXI eSIM，
使用地在英国境外。不过**困难的部分与这个具体组合关系不大**，
本文按「通用机制」与「本机特有」分开组织，便于区分取舍。

## 先读这段：是否真的需要这一整套

在动手移植之前，先尝试成本更低的做法：

1. **ROM 自带的 IMS 栈是否只是被 carrier config 关掉了？**
   查 `dumpsys carrier_config` 里的 `carrier_volte_available_bool`、
   `carrier_wfc_ims_available_bool`、`carrier_wfc_supports_wifi_only_bool`。
   如果 ROM 自带的 IMS 服务本身可用，只是 carrier config 不允许，覆盖几个键便是全部工作量。
   **这属于另一类、且小得多的问题**，无需本文。
2. **ROM 里的 `ims.apk` 是否为完整版本？**
   很多移植 ROM 塞的是精简版，运行时会明确拒绝 IWLAN 语音。
   用 `dexdump`/`jadx` 打开后 grep `VOICE_OVER_WIFI`。
   若该字符串完全不存在，则无论如何配置，ROM 自带的 IMS 都不会提供 WiFi 通话。
3. **是否存在 modem 侧的开关？** 部分设备可通过工程菜单或 MBN 配置开启。
   在决定走移植路线前，值得先花十分钟确认。

只有在 **ROM 的 IMS 栈无法支持 WiFi 通话、且无从使其支持**时，才需要本文所述方案 ——
此时的思路是把相关部件整体替换。

## 架构，以及唯一真正关键的那个认知

有四件事必须同时成立，而且**彼此独立**。这类工作中浪费掉的时间，
多数源于把其中一件误认作另一件。

```
1. 隧道    要有东西对运营商的 ePDG 跑 IKEv2/EAP-AKA
           并建立 IPsec 隧道                        -> AOSP Iwlan
2. 路由    框架必须相信 IMS 该走 WLAN 而不是蜂窝     -> QualifiedNetworksService
3. 信令    要有东西在那条隧道里说 SIP/MMTEL          -> phh floss-ims
4. 身份    框架必须把自有服务绑定为 MMTEL 提供方      -> carrier config 覆盖
```

**整个项目最决定性的认知**：高通设备上这四件事通常由 modem 掌管，外部难以介入。
而安卓的电话框架允许 **carrier app** 逐个接管它们 ——
`ImsResolver` 会绑定任意一个包作为 MMTEL 提供方，而 `IwlanDataService` 就是普通的 AOSP Java。
因此可以把整套栈搬到应用处理器侧，将 modem 排除在外。
**这正是它能在 modem 拒绝 VoWiFi 的设备上工作的原因。**

### 硬判据

这个项目里几乎每一条日志都会在某个环节产生误导，**以下几条不会**：

```sh
ip xfrm state      # 非空 = IPsec SA 真的存在
ip xfrm policy     # 内核真的会往那里路由
ip -s xfrm state   # 双向计数非零 = 它真的在被使用
```

整套机制完全不工作时，`dumpsys` 依然会报告 `isVowifiEnabled=true`；
radio 日志也会为一个已经失效的栈打出看似正常的消息。
**以 `ip xfrm` 与报文计数为准，其余一切仅作线索。**

**`ip xfrm state` 中的 `reqid` 即归属的 uid。** 三个组件保持独立包时，
它是判断某条 SA 属于隧道（Iwlan）还是 SIP 的 sec-agree（IMS 服务）的唯一手段 ——
这是全项目最有用的判据，也是**不宜把三者合并为单个 APK 的理由**。

## 分阶段顺序与验收标准

按顺序进行。每个阶段都有明确通过或不通过的判定，不接受「看起来正常」。

| # | 阶段 | 完成的标志 |
|---|---|---|
| 1 | 移植 AOSP Iwlan，装成 priv-app | 打开 WiFi 通话后 `ip xfrm state` 非空 |
| 2 | QualifiedNetworksService 为 IMS 上报 IWLAN | 日志出现 `onQualifiedNetworkTypesChanged ... networks = [IWLAN]` |
| 3 | 自有 IMS 服务被绑定为 MMTEL | 该服务的 `createMmTelFeature` 被调用 |
| 4 | 能力上报到框架 | `isVowifiEnabled=true` **且** `ImsPhoneCallTracker` 也认 |
| 5 | SIP REGISTER 成功 | `200 OK`，且 `ip -s xfrm state` 显示双向 ESP |
| 6 | 短信 | 收得到；发出去能拿到 `RP-ACK` |
| 7 | 语音 | INVITE 拿到 `200 OK` + RTP 双向流动 |

某一阶段未通过时，问题**几乎从不在后续阶段**，应回退排查前一阶段。

## 真正耗费时间的环节 —— 动手前建议先读

### 部署：特权权限是开机扫描时决定的

IMS 服务需要 `CONNECTIVITY_USE_RESTRICTED_NETWORKS`
（IMS 属于受限能力，缺少它时 `requestNetwork` 会被**静默**拒绝），
以及 `READ_PRIVILEGED_PHONE_STATE` 和 `MODIFY_PHONE_STATE`。
Iwlan 需要 `MANAGE_IPSEC_TUNNELS`。

这些属于特权权限：仅授予位于 `priv-app` **且具备对应白名单 XML** 的应用，
并且在开机扫描软件包时评估。由此产生的几个后果，每一个都消耗了一轮调试：

- **安装在 `/data/app` 永远拿不到这些权限**，必须有一个 `priv-app` 底座。
- **在 `priv-app` 底座之上做同签名的 `/data/app` 更新是可行的**，
  可以免重启迭代代码 —— 但**权限集取自底座的 manifest**，
  因此新增一项权限就意味着更新底座并重启。
- **软件包管理器按目录缓存已解析的 manifest。** 原地替换 APK 并不够 ——
  重启后仍会报旧的 `targetSdk` 与旧权限，需**修改容器目录名**强制重新扫描。
- **SELinux 标签会产生影响。** 标签为 `adb_data_file` 的 APK 在开机时被静默忽略，
  需执行 `chcon u:object_r:system_file:s0`。

### 隐藏 API：先看能不能降 targetSdk，再考虑写反射

为访问一个 `MAX-TARGET-O` 成员，曾连续六个构建版本编写愈发复杂的反射，
包括尝试经 `VMRuntime` 自我豁免（该调用本身同样被拦截）。
真正的解法是**一行打包参数：targetSdk 28** —— API 29 以下，黑名单仅是警告，而非屏障。

**优先检查 targetSdk：一行参数，胜过数轮反射工程。**

### vendor 的框架签名和 AOSP 不一样

澎湃的 `notifyCapabilitiesStatusChanged` 参数类型与 AOSP 不同。
应使用**目标 ROM 实际的 `framework.jar`** 编译，而非 SDK，
并预期需要一个小的 Java shim，才能在不触发黑名单的前提下访问 protected 成员。
**不要假设 AOSP 源码与 vendor 的二进制一致。**

### carrier config 覆盖在运行时缓存里，不是文件

把框架重定向到自有组件的那些键，位于
`/data/user_de/0/com.android.phone/files/carrierconfig-<ICCID>-<mccmnc>.xml`，
而平台**会重建该文件**。因此无法以文件 overlay 的形式分发 ——
需要开机脚本重新注入，见 `code/module/service.sh`。

这些键是**「包名 + 类名」成对**出现的。只注入其中一半，框架会静默地继续指向原厂组件，
表现恰好就是「改了但没生效」：

```
carrier_data_service_wlan_{package,class}_override_string      -> Iwlan
carrier_network_service_wlan_{package,class}_override_string   -> Iwlan
carrier_qualified_networks_service_{package,class}_override_*  -> 自有 QNS
config_ims_mmtel_package_override_string                       -> 自有 IMS 服务
```

## 可能遇到的客户端 bug

`phh/floss-ims` 是目前已知唯一的自由 MMTEL 实现，确实可用 ——
但它针对特定运营商编写，并且**假设进程的存活时间恰好等于一次连接的存活时间**。
`code/patches/` 中的改动几乎都源于这个假设。
补丁头部逐条列出了每项修复；以下几条值得在动手前了解，
因为它们属于**bug 的类别**，而非一次性个案：

**注册失效而进程仍存活。** 主 socket 的读循环丢弃了「该 socket 已结束」这一返回值，
于是 P-CSCF 关闭连接时（本例为每小时一次），读线程在 100% CPU 上空转。
进程存活、不崩溃、日志持续输出 —— 而注册已经失效。
**增加重连是解法，但请继续看下一条。**

**为从不重连的代码加上重连，会唤醒一整类 bug。**
原作者可以合理地不释放资源、把对象缓存在字段中、在失败路径直接 `return` ——
因为进程生命周期**就等于**连接生命周期。一旦引入重连，这三点分别变成：
泄漏的 IPsec SA（sec-agree SA 不带 lifetime，内核不会回收）、
协程服务于错误代次的对象、以及每次失败尝试泄漏一整轮资源。
**引入重连时，宜把「连接」与「进程」两条生命周期分开梳理，逐个字段确认重连后是否仍然成立。**

**长生命周期线程不应读取会被重新赋值的字段。**
一个存活时间超过自身连接的 `while (true) { serverSocket.accept() }` 循环，
会开始服务**新的**监听 socket，并与新的读线程争抢同一批消息。
应把对象捕获为局部变量并加代次门禁。
这类竞态不会报错，只是偶发丢消息 —— 而丢掉的可能正是一通来电。

**裸线程中未捕获的异常会终止整个进程。**
为媒体线程添加资源清理时曾因此引入崩溃，原因是 try 未覆盖主循环**之前**的那段循环。
崩溃远比它所替代的泄漏严重 —— 泄漏只是占用内存，崩溃会直接导致注册中断。
**try 应覆盖整个线程体。**

**协议中带方向性的字段是陷阱。** RFC 3312 在 SDP 中的 `local`/`remote`
以**发送方**视角表述，因此在对端发来的消息里，`local` 指的是**对端**。
按字面理解会导致在网络等待确认时毫无动作，通话最终以 `580 Precondition Failure` 失败。

**不要拿对端的报文改动两行再发回作为应答。**
SDP 中含连接地址与端口 —— 原样回敬相当于**把对端的地址当作自己的对外声明**，
本项目曾因此收到 `403 Forbidden`。

**同一文件中，正确与错误的写法并排存在。**
出向 SDP 的构造使用了正确的 `o=- 1 2 IN IP4 ...`；
而来电处为 `o=<imsi> 1 2 ...` —— 只有五个字段，RFC 4566 要求六个。
结果每一通来电都被网络以 `Reason: ...text="Invalid SDP"` 取消。
**审查某处协议构造时，宜把同文件内所有同类构造并排比对一遍。**

**留意无人负责重置的状态。** 在每条拆除路径都设置「已停止」标志之后，
新的**拨出**通话开始时却没有任何环节清除它（来电路径一直会清）。
下一通的编码线程见到标志已为 true，便跳过了开麦：通话接通，但只有单向语音。
**「重启后第一通正常、第二通异常」这一特征，几乎总是意味着跨调用的残留状态未清除。**

## 监控：判据比看起来难写

`code/diagnostics/` 中是本项目使用的脚本，其背后的经验是通用的：

**"进程在跑"什么都证明不了。** 注册死了进程照样活着。
要同时查几件互相独立的事：自己进程的 established socket 数、
它的**监听** socket、CPU tick、日志增长速率、刷新闹钟是否在册、以及悬空的 IPsec 策略。

**监控必须能区分"故障"和"正忙"。**
本项目曾以「日志增长 > 300 行/3 秒」检测空转循环 ——
但一通正常的语音通话同样会输出约 100 行/秒，于是看门狗 force-stop 了一通
已接通 3 分 35 秒、运行正常的通话。
**设定阈值之前，应先确认该指标在系统最繁忙的健康状态下的读数。**
更根本的做法是**降低被监控程序的噪声**（整条流输出一行，而非每包一行），
而不是调高阈值。

**自动恢复需要有否决机制。** 看门狗现已拒绝在通话进行期间 force-stop：
它所能检测到的任何故障，都不值得中断一通电话。
**补救手段的破坏性应与故障严重程度相称。**

**监控脚本里写死的标识符都是定时炸弹**：uid（`u0a268` 重装就变）、
端口字面量（临时端口会变）、对端 IP（会轮换）。
它们失效时不会报错 —— 只会永远返回 0，看起来像"这一项一直正常"。
要推导出来：uid 从 `/proc/<pid>` 拿，socket 用 `ss -tnp | grep "pid=$PID,"` 数。

**判定泄漏应看悬空引用，而非比较总数。** 总数会因正常原因波动
（双栈策略、重连时重建的 socket）。本项目曾据总数误判泄漏、追查两轮，并因此多发了一个版本。
真正的判据是「是否存在某条策略的 SPI 找不到对应的活跃 SA」：

```sh
comm -13 <(ip xfrm state  | grep -oE 'spi 0x[0-9a-f]+' | sort -u) \
         <(ip xfrm policy | grep -oE 'spi 0x[0-9a-f]+' | sort -u)
```

**另外，用 `grep -c` 计数前应先确认一个单位占几行。**
统计的是匹配**行数**而非策略条数，由此得到的错误数字，
又进一步支撑了一个错误的结论。

**若两轮改动都未使数字产生任何变化，应质疑的是诊断，而不是修复方案。**

## 部署：一个 KernelSU 模块

`code/module/` 里是一个模块，它安装三个包及其白名单，并在每次开机重新注入 carrier config。
`uninstall.sh` 会从备份还原 carrier config —— **这一步不可省略**：
直接删除模块只会卸掉那些 APK 的挂载，
却会留下框架指向已不存在的包，可能导致手机**完全没有可用的 IMS**。

曾评估过把三个包合并为单个 APK。技术上可行
（三者均不依赖 `Build.VERSION`、`PendingIntent` mutability 或带类型的前台服务，
可以共用 targetSdk 28），但最终没有采用：
独立的 uid 正是 `reqid` 能把 IPsec SA 归属到具体组件的前提，
且保持独立还便于单独开关做 A/B 对照。
**单个模块已经解决了「一步部署」的问题，无须为此放弃上述优势。**

## 工作环境的坑

- `adb shell "su -c '...'"` **会吞掉 `$`、`^` 与嵌套引号。**
  由此产生过：静默为空的 CPU 读数、返回 0 的 `grep -c "^src"`
  （一度误判隧道已断）、以及把文件写到 `/` 的 `cp`。
  **凡逻辑中含这些字符的，一律写成设备端脚本推送执行，宿主端只读取其输出。**
- `pgrep -f foo.sh` 经 `adb shell` 调用时**会匹配到执行它的那条命令本身**，
  因为包装命令的命令行中就含该模式。
  应锚定解释器：`ps -A -o ARGS | grep -c "^sh /path/foo.sh"`。
- `stat /proc/<pid>` **不是**进程启动时间（那是 inode 的 mtime）。
  用 `/proc/<pid>/stat` 的第 22 个字段：`age = uptime - starttime/100`。
- 替换正在运行的守护进程后，**须确认旧进程确已退出**。
  修改文件不影响已把代码载入内存的进程，而 `pkill -f` 也可能遗漏。
  本项目曾出现两个看门狗同时运行、相互干扰的情况。
- 重新生成补丁前应先清除 `.orig`/`.rej`，否则 `diff -ruN` 会将其当作新文件写入，
  或直接使用 `-x '*.orig'`。
- **先读对端给出的原因，再作推测。**
  `Reason: ...text="Invalid SDP"` 与 `404 Not Found` 各自直接指向了一个 bug。
  「刚拨出就断开」这类模糊症状，协议报文中往往已有精确答案。

## 这里有什么

```
code/patches/floss-ims-local.patch   全部源码改动，对应写明的上游 commit
code/build/                          构建流水线（aapt2 -> javac/kotlinc -> d8 -> 签名）
code/build/AndroidManifest.xml       手写 manifest：targetSdk 28 + RECORD_AUDIO
code/module/                         KernelSU 模块：三个包 + 开机注入配置
code/minqns/                         最小 QualifiedNetworksService（源码）
code/diagnostics/                    健康 / 状态 / 看门狗 + 测试脚本
docs/carrier-voxi-uk.md              运营商的具体数值，可作填好的样例参考
```

`code/patches/floss-ims-local.patch` 写明了它对应的上游 commit，
并已验证零 fuzz 应用、且与实际编译出工作 APK 的源码逐字节一致。
补丁头部列出了每处改动是什么、为什么。

**刻意没有包含**：签名密钥库、带隐藏 API 的 `android.jar`、
以及任何从 ROM 抽出来的 `framework.jar`/dex。
适配时本就需要目标 ROM 自身的 framework jar，而转发 vendor 的文件并不合适。

## 诚实的适用范围

- 语音通话：**拨出已验证可用**（接通、双向 AMR 语音、通话计时正确）。
  **来电已审查并修复，但尚未完成端到端验证** ——
  导致其失败的 bug 是从一次真实的失败来电中定位并修复的，但修复本身没有再用来电复测。
- 此处结论均基于**一台设备、一个运营商**。框架机制通用，具体数值不通用。
- AOSP Iwlan、phh 的 floss-ims 以及 carrier config 覆盖机制均早于本项目存在，
  此处记录的是整合过程与其中的失败形态。
- 运营商可能禁止这种用法。VOXI 的条款写明漫游时使用 WiFi Calling 属于
  "prohibited and not supported"，这同时意味着**计费行为未定义** ——
  应以实测为准，不要照资费表推断。
