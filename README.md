# StayLowPowerMode

iOS 15+（Dopamine / 无根越狱）插件：充电到 80% 时，系统不再自动关闭「低电量模式」。

## 安装

构建产物：`StayLowPowerMode_1.0.0_iphoneos-arm64.deb`

用 Sileo / Filza 安装后，**注销（respring）** 一次让 SpringBoard 加载插件。

安装路径（无根）：

- `/var/jb/Library/MobileSubstrate/DynamicLibraries/StayLowPowerMode.dylib`
- `/var/jb/Library/MobileSubstrate/DynamicLibraries/StayLowPowerMode.plist`（过滤：仅 `com.apple.springboard`）

## 行为

1. 充电中且电量达到阈值（默认 80%）时，拦截系统关闭低电量模式的调用，低电量模式保持开启。
2. 兜底：若低电量模式仍被系统关闭（电量在阈值 ±6% 内），插件会把它重新打开。
3. 出口：拔掉充电线，或到「设置 → 电池」关闭低电量模式（该操作在 Preferences 进程，不在拦截范围）；拔线后插件自动恢复干预。
4. 兜底恢复每个充电周期最多执行一次：既挡住系统的重复关闭，也避免你手动关闭后被反复打开。

## 配置（可选）

偏好域：`com.dylix.staylowpowermode`

| 键 | 类型 | 默认 | 说明 |
| --- | --- | --- | --- |
| `Enabled` | bool | `true` | 总开关 |
| `Threshold` | float | `0.8` | 干预阈值（0~1） |
| `LogVerbose` | bool | `false` | 启动时枚举系统内 LowPower 相关类与方法，用于排查 |

终端示例：

```sh
defaults write com.dylix.staylowpowermode Threshold -float 0.85
```

改完注销生效。

## 排查

日志前缀 `[StayLPM]`，查看方式（任选其一）：

```sh
log stream --predicate 'eventMessage CONTAINS "[StayLPM]"'
```

或 Filza 查看 `/var/mobile/Library/Logs/`、Syslog。

正常加载会打印一行「加载 v1.0.0」和「已挂载 _setLowPowerModeEnabled: 拦截」。
若打印「未找到 _setLowPowerModeEnabled:」，说明该版本系统换了实现，把 `LogVerbose` 设为 `true` 后重装并回传日志，即可定位新的 Hook 点。

## 已知限制

- 编译通过不等于真机注入成功；本插件尚未在真机验证。
- 拦截点 `-[NSProcessInfo _setLowPowerModeEnabled:]` 为私有 API，不同系统版本可能变化，兜底逻辑用于覆盖这种偏差。
