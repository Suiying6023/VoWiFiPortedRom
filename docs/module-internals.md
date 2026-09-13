# KernelSU 模块维护说明

v7 将 Iwlan v13、phh v43、MinQns v1 安装为 `system_ext/priv-app`，用于 K50U / HyperOS 移植包 / API 37。
当前验收范围为注册维护与短信通道，接打电话仍有用户报告的失败。

## 组件与来源

| 组件 | 包名 | 职责 |
|---|---|---|
| Iwlan v13 | `com.google.android.iwlan` | ePDG 隧道与 IMS 数据网络 |
| phh v43 | `me.phh.ims` | SIP 注册和短信处理，含实验性语音路径 |
| MinQns v1 | `com.voxi.minqns` | 向框架声明 IMS 使用 IWLAN |

三个 APK 的 SHA-256 记录在源码 `code/module/payload.sha256`，与本次真机运行版本一致。
保持独立 UID 可以区分两类 IPsec SA，并支持分别恢复组件。
phh 补丁基于 `phhusson/ims` 的 `c180bdf`；其权限来自手写 manifest 和 priv-app 白名单。

## 安装与启动

从 KernelSU 管理器安装 ZIP 后重启。特权权限由开机扫描决定。
`customize.sh` 禁用旧 `phhimspriv`、`iwlanpriv` 模块，保留目录供恢复；`imsfix_cn` 继续提供原厂 IMS 组件。

`service.sh` 等待系统启动和 carrier cache 出现，再逐份检查七个覆盖键。
`carrier-config.sh` 同时验证包名、类名、值与唯一性；缺键或错误值会修复，完整正确的缓存保持原样。
每份缓存首次编辑前保存 `.bak.vowifi_stack`；不支持的结构拒绝写入。
当前注入范围是该 ROM 下匹配的 carrier caches，其他双卡组合需要单独验证。

模块为三个包添加 deviceidle 白名单，并恢复 `/data/local/tmp` 下的诊断脚本。
日志位置为 `/data/local/tmp/vowifi_stack_boot.log`。

## 看门狗

模块附带并启动看门狗，每 120 秒检查一次：

- 所有 SIM 均空闲且 WiFi 有地址时，才允许恢复；状态未知同样禁止操作。
- 恢复前重新读取通话状态，避免使用几秒前的快照。
- 注册期限取自当前进程的实际授权事件。重复读取旧日志不会刷新时间戳。
- 暂时丢失监听先复查；每次恢复后至少冷却 900 秒。
- 文件锁限制为一个实例；自身日志限制约 64 KiB。

`phh_last_grant` 保存真实授权事件的 epoch 秒数。看门狗重启且当前日志里没有事件时，
先给当前进程一个观察窗口；之后持续跟踪事件。日志与时间戳不纳入普通清理。
闹钟 dump 包含历史记录，因此 `alarm_refs` 只是线索，不当作正在排队的刷新闹钟数量。

可在模块目录创建 `watchdog.disabled`，下次启动不再启动看门狗，升级时保留这一选择。
此文件不主动停止已经运行的实例。

## 检查与卸载

```sh
su -c 'sh /data/local/tmp/phh_status.sh'
su -c 'sh /data/local/tmp/test_cc_injection.sh'
```

第二条只在临时副本上验证注入、幂等性和缺键修复，不编辑正在使用的缓存。

正常卸载应通过 KernelSU 管理器触发 `uninstall.sh`，以还原配置备份、移除白名单并停止看门狗。
早期备份可能已经包含本模块的值；还原时会去除这些引用，避免卸载后仍绑定已不存在的提供方。
直接删除模块目录会绕过恢复步骤。回滚到旧独立模块时，需要按原来的启用状态恢复它们并重启。

本模块不设置 APN、ePDG 地址或漫游开关。保号以账户的有效活动记录为准，见 [保号与维护](maintenance.md)。
