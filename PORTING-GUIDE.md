# 在移植 ROM 上跑通 VoWiFi（WiFi 通话）

这是一份实战记录，外加能工作的代码：在一台 ROM 本身不支持的手机上，把 WiFi 通话
—— **SIP 注册、双向短信、语音通话** —— 真正跑起来。

参考设备：Redmi K50 至尊版，跑澎湃 OS4 移植包（Android 17），英国 VOXI eSIM，
人在英国境外。但**难的部分和这个组合没什么关系**，本文的组织方式就是让你能分清
哪些是通用的、哪些是我这台机器特有的。

*[English version](PORTING-GUIDE.en.md)*

## 先读这段：你真的需要这一整套吗

在动手移植任何东西之前，先试便宜的做法：

1. **你 ROM 自带的 IMS 栈是不是仅仅被 carrier config 关掉了？**
   查 `dumpsys carrier_config` 里的 `carrier_volte_available_bool`、
   `carrier_wfc_ims_available_bool`、`carrier_wfc_supports_wifi_only_bool`。
   如果你的 ROM 有能工作的 IMS 服务，只是 carrier config 说不行，那覆盖几个键就是全部工作。
   **那是个完全不同、而且小得多的问题**，不需要本文。
2. **你的 ROM 里是不是一个真正的 `ims.apk`？**
   很多移植 ROM 塞的是精简版，运行时会明确拒绝 IWLAN 语音。
   用 `dexdump`/`jadx` 打开它，grep `VOICE_OVER_WIFI`。
   如果这个字符串根本不存在，那不管你怎么配，ROM 的 IMS 永远不会提供 WiFi 通话。
3. **有没有 modem 侧的开关？** 有些设备有工程菜单或 MBN 配置能开。
   在决定走移植这条路之前，值得先花十分钟。

只有当 **ROM 的 IMS 栈做不到 WiFi 通话、而且没法让它做到**时，你才需要本文 ——
此时答案就是把那些部件换掉。

## 架构，以及唯一真正关键的那个认知

有四件事必须成立，而且**彼此独立**。这类项目里浪费掉的时间，
大多来自把其中一件误认成另一件。

```
1. 隧道    要有东西对运营商的 ePDG 跑 IKEv2/EAP-AKA
           并建立 IPsec 隧道                        -> AOSP Iwlan
2. 路由    框架必须相信 IMS 该走 WLAN 而不是蜂窝     -> QualifiedNetworksService
3. 信令    要有东西在那条隧道里说 SIP/MMTEL          -> phh floss-ims
4. 身份    框架必须把你的服务绑定为 MMTEL 提供方      -> carrier config 覆盖
```

**整个项目最决定性的认知**：在高通设备上，这四件事通常都由 modem 掌管，而你伸不进去。
但安卓的电话框架允许一个 **carrier app** 逐个接管它们 ——
`ImsResolver` 会绑定任意一个包作为 MMTEL 提供方，而 `IwlanDataService` 就是普通的 AOSP Java。
所以你把整套栈搬到应用处理器，把 modem 排除在外。
**这就是为什么它能在一台 modem 拒绝 VoWiFi 的设备上工作。**

### 硬判据

这个项目里几乎每一条日志都会在某个时刻骗你。**下面这几条不会：**

```sh
ip xfrm state      # 非空 = IPsec SA 真的存在
ip xfrm policy     # 内核真的会往那里路由
ip -s xfrm state   # 双向计数非零 = 它真的在被使用
```

`dumpsys` 会在整套东西完全不工作时，愉快地报告 `isVowifiEnabled=true`；
radio 日志也会为一个已经死掉的栈打出看起来充满希望的消息。
**相信 `ip xfrm` 和报文计数，其他一切只当线索。**

**`ip xfrm state` 里的 `reqid` 就是归属的 uid。** 三个组件保持独立包的情况下，
它是你唯一能判断某个 SA 属于隧道（Iwlan）还是属于 SIP 的 sec-agree（你的 IMS 服务）的手段 ——
这是这里最有用的判据，也是**不该把它们合并成一个 APK 的理由**。

## 分阶段顺序与验收标准

按顺序做。每一阶段都有一个明确通过或不通过的测试 —— 不接受"看起来对"。

| # | 阶段 | 完成的标志 |
|---|---|---|
| 1 | 移植 AOSP Iwlan，装成 priv-app | 打开 WiFi 通话后 `ip xfrm state` 非空 |
| 2 | QualifiedNetworksService 为 IMS 上报 IWLAN | 日志出现 `onQualifiedNetworkTypesChanged ... networks = [IWLAN]` |
| 3 | 你的 IMS 服务被绑定为 MMTEL | 你服务的 `createMmTelFeature` 被调用 |
| 4 | 能力上报到框架 | `isVowifiEnabled=true` **且** `ImsPhoneCallTracker` 也认 |
| 5 | SIP REGISTER 成功 | `200 OK`，且 `ip -s xfrm state` 显示双向 ESP |
| 6 | 短信 | 收得到；发出去能拿到 `RP-ACK` |
| 7 | 语音 | INVITE 拿到 `200 OK` + RTP 双向流动 |

某一阶段没过，修的地方**几乎从不在后面的阶段**。回退到前一阶段。

## 真正花掉时间的地方 —— 动手前先读

### 部署：特权权限是开机扫描时决定的

你的 IMS 服务需要 `CONNECTIVITY_USE_RESTRICTED_NETWORKS`
（IMS 是受限能力，没有它 `requestNetwork` 会被**静默**拒绝），
外加 `READ_PRIVILEGED_PHONE_STATE` 和 `MODIFY_PHONE_STATE`。
Iwlan 需要 `MANAGE_IPSEC_TUNNELS`。

这些是特权权限：只授予位于 `priv-app` **且有对应白名单 XML** 的应用，
而且是在开机扫描软件包时评估的。由此带来的几个后果，每一个都花掉我一轮调试：

- **装在 `/data/app` 永远拿不到这些权限。** 你需要一个 `priv-app` 底座。
- **在 `priv-app` 底座之上做同签名的 `/data/app` 更新是可以的**，
  这样能免重启迭代代码 —— 但**权限集来自底座的 manifest**，
  所以加一个权限就意味着更新底座并重启。
- **软件包管理器按目录缓存已解析的 manifest。** 原地换 APK 是不够的 ——
  重启之后它仍然报旧的 `targetSdk` 和旧的权限。**要改容器目录名**来强制重扫。
- **SELinux 标签有影响。** 标签是 `adb_data_file` 的 APK 在开机时被静默忽略。
  要 `chcon u:object_r:system_file:s0`。

### 隐藏 API：先看能不能降 targetSdk，再考虑写反射

我为了访问一个 `MAX-TARGET-O` 成员，烧掉六个构建版本写越来越复杂的反射，
包括尝试通过 `VMRuntime` 自我豁免（那个本身也被拦）。
真正的解法是**一行打包参数：targetSdk 28**。API 29 以下，黑名单只是警告，不是墙。

**先看 targetSdk。它是一行，而且胜过五轮反射工程。**

### vendor 的框架签名和 AOSP 不一样

澎湃的 `notifyCapabilitiesStatusChanged` 参数类型和 AOSP 的不同。
拿**你 ROM 实际的 `framework.jar`** 编译，不要拿 SDK，
并且预期需要一个小的 Java shim 才能在不触发黑名单的前提下访问 protected 成员。
**不要假设 AOSP 源码和你 vendor 的二进制一致。**

### carrier config 覆盖在运行时缓存里，不是文件

那些把框架重定向到你组件的键，位于
`/data/user_de/0/com.android.phone/files/carrierconfig-<ICCID>-<mccmnc>.xml`，
而且平台**会重建它**。所以你没法把它们作为文件 overlay 发出去 ——
需要一个开机脚本重新注入。见 `code/module/service.sh`。

它们是**「包名 + 类名」成对**出现的。只注入一半，框架会静默地继续指向原厂组件，
表现出来就恰好是"我改了但没生效"：

```
carrier_data_service_wlan_{package,class}_override_string      -> Iwlan
carrier_network_service_wlan_{package,class}_override_string   -> Iwlan
carrier_qualified_networks_service_{package,class}_override_*  -> 你的 QNS
config_ims_mmtel_package_override_string                       -> 你的 IMS 服务
```

## 你会遇到的客户端 bug

`phh/floss-ims` 是我知道的唯一自由的 MMTEL 实现，而且它能工作 ——
但它是针对某个特定运营商写的，并且**假设进程的存活时间恰好等于一次连接的存活时间**。
`code/patches/` 里的所有东西都是从这个假设里长出来的。
补丁头部逐条列了每个修复；下面这几条值得在动手前就知道，
因为它们是**bug 的类别**，不是一次性的个案：

**注册死了但进程还活着。** 主 socket 的读循环丢弃了"这个 socket 结束了"这个返回值，
于是当 P-CSCF 关闭连接时（我这里是每小时一次），读线程就在 100% CPU 上空转。
进程活着、不崩、日志还在刷 —— 而注册已经不工作了。
**加重连是解法，但接着看下一条。**

**给一段从不重连的代码加上重连，会唤醒一整个家族的 bug。**
原作者可以合理地不释放资源、把对象缓存在字段里、在失败路径直接 `return` ——
因为进程生命周期**就是**连接生命周期。一旦你重连，这些分别变成：
泄漏的 IPsec SA（sec-agree SA 不带 lifetime，内核永远不回收）、
协程在服务错误代次的对象、每次失败尝试漏掉一整轮资源。
**加重连时，把「连接」和「进程」两个生命周期分开画一遍，逐个字段问：重连之后它还对吗？**

**长生命周期线程不能读会被重新赋值的字段。**
一个活过了自己那次连接的 `while (true) { serverSocket.accept() }` 循环，
会开始服务**新的**监听 socket，并和新的读线程抢同一批消息。
要把对象捕获成局部变量并加代次门禁。
这个竞态不报错 —— 它只是偶发丢消息，而丢掉的可能是一通来电。

**裸线程：未捕获的异常会杀掉整个进程。**
我给媒体线程加资源清理时引入了一个崩溃，因为 try 没有覆盖主循环**之前**的那段循环。
崩溃比它替换掉的泄漏严重得多 —— 泄漏只是浪费内存，崩溃直接掉注册。
**要覆盖整个线程体。**

**协议里带方向性的字段是陷阱。** RFC 3312 在 SDP 里的 `local`/`remote`
是站在**发送方**视角说的，所以在对端发给你的消息里，`local` 指的是**它们**。
照字面理解让我们在网络等着我们确认时什么都没做，通话以 `580 Precondition Failure` 失败。

**永远不要拿对端的报文改两行再发回去应答。**
SDP 里含连接地址和端口 —— 回敬它等于**把对端的地址当成自己的广告出去**。
我们因此吃了 `403 Forbidden`。

**同一个文件里，正确和错误的写法并排放着。**
出向 SDP 的构造用的是正确的 `o=- 1 2 IN IP4 ...`；
来电那处是 `o=<imsi> 1 2 ...` —— 五个字段，而 RFC 4566 要求六个。
每一通来电都被网络以 `Reason: ...text="Invalid SDP"` 取消。
**审查一处协议构造时，把同文件里所有同类构造并排 diff 一遍。**

**留意没人负责重置的状态。** 在我们让每条拆除路径都设置一个"已停止"标志之后，
新的**拨出**通话开始时却没人清它（来电路径一直会清）。
下一通的编码线程看到标志已经是 true，就跳过了开麦：接通了，但只有单向语音。
**「重启后第一通正常、第二通异常」这个特征，几乎总是意味着跨调用残留的状态没清。**

## 监控：判据比看起来难写

`code/diagnostics/` 里是我的脚本。背后的教训是通用的：

**"进程在跑"什么都证明不了。** 注册死了进程照样活着。
要同时查几件互相独立的事：自己进程的 established socket 数、
它的**监听** socket、CPU tick、日志增长速率、刷新闹钟是否在册、以及悬空的 IPsec 策略。

**监控必须能区分"故障"和"正忙"。**
我用"日志增长 > 300 行/3 秒"来检测那个空转循环 ——
但一通正常的语音通话也会打出约 100 行/秒，于是看门狗 force-stop 了一个
已经接通 3 分 35 秒、工作正常的通话。
**在定阈值之前，先问这个指标在系统最忙的健康状态下读数是多少。**
更好的做法是**降低被监控程序的噪声**（整条流打一行，而不是每个包一行），
而不是调高阈值。

**自动恢复要有否决权。** 看门狗现在拒绝在通话进行时 force-stop：
它能检测到的任何故障，都不值得掉一通电话。
**让补救手段的破坏性与故障严重性成比例。**

**监控脚本里写死的标识符都是定时炸弹**：uid（`u0a268` 重装就变）、
端口字面量（临时端口会变）、对端 IP（会轮换）。
它们失效时不会报错 —— 只会永远返回 0，看起来像"这一项一直正常"。
要推导出来：uid 从 `/proc/<pid>` 拿，socket 用 `ss -tnp | grep "pid=$PID,"` 数。

**判泄漏要看悬空引用，不要比总数。** 总数会因为正常原因波动
（双栈策略、重连时重建的 socket）。我拿总数当泄漏追了两轮，还发了一个多余的版本。
真正的判据是"有没有某条策略的 SPI 找不到活着的 SA"：

```sh
comm -13 <(ip xfrm state  | grep -oE 'spi 0x[0-9a-f]+' | sort -u) \
         <(ip xfrm policy | grep -oE 'spi 0x[0-9a-f]+' | sort -u)
```

**另外：用 `grep -c` 计数之前，先确认一个单位占几行。**
数的是匹配**行数**而不是策略条数，给了我一个错误的数字，
而这个数字又支撑了一个错误的结论。

**当两轮改动都没让数字发生任何变化时，该质疑的是诊断，不是修复。**

## 部署：一个 KernelSU 模块

`code/module/` 里是一个模块，它安装三个包及其白名单，并在每次开机重新注入 carrier config。
`uninstall.sh` 从备份还原 carrier config —— **这一步不是可选的**：
直接删掉模块只会卸掉那些 APK 的挂载，
但会留下框架指向已不存在的包，可能让手机**完全没有可用的 IMS**。

我考虑过把三个包合并成一个 APK。技术上没问题
（它们都不依赖 `Build.VERSION`、`PendingIntent` mutability 或带类型的前台服务，
所以可以共用 targetSdk 28），但我选择不做：
独立的 uid 正是 `reqid` 能把 IPsec SA 归属到具体组件的原因，
而且保持独立还能单独开关做 A/B 对照。
**一个模块已经解决了"一步部署"，不需要放弃这些。**

## 工作环境的坑

- `adb shell "su -c '...'"` **会吃掉 `$`、`^` 和嵌套引号。**
  这造成过：一个静默为空的 CPU 读数、一个返回 0 的 `grep -c "^src"`
  （让我以为隧道掉了）、以及一个把文件写到 `/` 的 `cp`。
  **凡是逻辑里含这些字符的，一律写成设备端脚本推上去跑，宿主端只读它的输出。**
- `pgrep -f foo.sh` 通过 `adb shell` 调用时**会匹配到执行它的那条命令**，
  因为包装命令的命令行里就含这个模式。
  要锚定解释器：`ps -A -o ARGS | grep -c "^sh /path/foo.sh"`。
- `stat /proc/<pid>` **不是**进程启动时间（那是 inode 的 mtime）。
  用 `/proc/<pid>/stat` 的第 22 个字段：`age = uptime - starttime/100`。
- 替换一个正在运行的守护进程之后，**要确认旧的真的死了**。
  改文件不影响一个已经把代码载入内存的进程，而 `pkill -f` 可能漏掉。
  我曾经有两个看门狗在互相打架。
- 重新生成补丁前先清掉 `.orig`/`.rej`，否则 `diff -ruN` 会把它们当新文件写进去。
  或者用 `-x '*.orig'`。
- **先读对端给出的原因，再去猜。**
  `Reason: ...text="Invalid SDP"` 和 `404 Not Found` 各自直接指出了一个 bug。
  "刚打出去就断"这类模糊症状，协议报文里往往有精确答案。

## 这里有什么

```
code/patches/floss-ims-local.patch   全部源码改动，对应写明的上游 commit
code/build/                          构建流水线（aapt2 -> javac/kotlinc -> d8 -> 签名）
code/build/AndroidManifest.xml       手写 manifest：targetSdk 28 + RECORD_AUDIO
code/module/                         KernelSU 模块：三个包 + 开机注入配置
code/minqns/                         最小 QualifiedNetworksService（源码）
code/diagnostics/                    健康 / 状态 / 看门狗 + 测试脚本
docs/carrier-voxi-uk.md              我这家运营商的具体数值，当填好的样例看
```

`code/patches/floss-ims-local.patch` 写明了它对应的上游 commit，
并已验证零 fuzz 应用、且与实际编译出工作 APK 的源码逐字节一致。
补丁头部列出了每处改动是什么、为什么。

**刻意没有包含**：签名密钥库、带隐藏 API 的 `android.jar`、
以及任何从 ROM 抽出来的 `framework.jar`/dex。
你本来就需要你自己 ROM 的 framework jar，而重新分发 vendor 的不是我该做的事。

## 诚实的适用范围

- 语音通话：**拨出已验证可用**（接通、双向 AMR 语音、通话计时正确）。
  **来电已审查并修复，但还没做端到端验证** ——
  让它失败的那个 bug 是从一次真实的失败来电里找到并修掉的，但修复本身没再用来电测过。
- 这里的一切都是**一台设备、一个运营商**。框架机制是通用的，具体数值不是。
- **这里没有任何新的研究成果。** AOSP Iwlan、phh 的 floss-ims、
  carrier config 覆盖机制都早于这项工作。被写下来的是整合过程和那些失败形态。
- 你的运营商可能禁止这种用法。我这家的条款写着漫游时使用 WiFi Calling
  "prohibited and not supported"，这同时意味着**计费行为是未定义的** ——
  请实测，不要照资费表推断。
