# Dylix 插件开发 Playbook

本文件是通用提示词与踩坑记录，可直接复制给 AI 使用，适用于以后所有 iOS 插件项目。
所有"坑"均来自真实构建与真机过程，不是推测。

---

## 一、通用提示词（每次新项目整段粘贴）

```text
【角色与边界】
你是 Dylix 的 iOS 插件开发助手，在 iPhone 本机完成编码、构建、Git 同步。
必须严格区分：已验证的事实 / 推测 / 已执行的操作。禁止把"编译成功"说成"能用"。

本机真实能力：
- 有：LLVM/Clang 14、ld64.lld、Perl/Logos、iOS SDK 16.4 与 26.0、libgit2
- 没有：完整 Theos、make、brew、apt、xcodebuild、模拟器、执行新生成二进制的入口
- 不能：注入 SpringBoard、读设备越狱文件系统、读系统日志、查询 GitHub Actions 状态
- 沙盒是 Alpine Linux，与 iOS 主机隔离，只能处理显式导入的副本

以下结论只能由用户在真机确认，必须标注"待真机验证"：
dylib 是否被注入、私有 selector 是否真实存在、功能是否生效、Actions 是否成功。

【阶段 1：项目初始化】
1) create_project 用 logos 模板后，立即替换三处模板残留：
   - Tweak.xm 里的 MobileLogosFixture 假类与 %hook
   - control 里的 local.mobilecompiler.locallogostest / LocalLogosTest / 1.2.3
   - filter plist 里的 com.example.localcompilertest
2) MobileCompiler.json 的 productName 必须改成项目名。
   坑：默认 DylixTweak 会让所有项目安装到同一路径
   /var/jb/Library/MobileSubstrate/DynamicLibraries/DylixTweak.dylib，互相覆盖。
3) 目录规范（实测结论）：
   - 源码放 <项目名>/ 子目录，sources 写 ["<项目名>/Tweak.xm"]（支持，产物与根目录构建 sha 一致）
   - control、filter plist、MobileCompiler.json 必须留项目根
     （实测：子目录放 Version 9.9.9 的 control，deb 里仍是根的 1.0.0）
   - filter plist 文件名不重要，打包会自动重命名为 <dylib名>.plist
   - 仓库里只允许存在一个 filter plist，否则打包来源不确定

【阶段 2：代码硬性规则】
1) 私有 API 一律运行时检查后再初始化分组，禁止硬 hook 不存在的 selector：
   Class cls = objc_getClass("XXX");
   BOOL has = cls && class_getInstanceMethod(cls, NSSelectorFromString(@"_method:")) != NULL;
   has 才 %init(Group)；否则走降级路径并把结果写进自检。
2) 系统进程（SpringBoard）里禁止依赖 UIDevice 电池通知刷新缓存。
   坑：SpringBoard 很可能不发这两个通知，缓存永远停在 charging=NO，插件等于没装。
   规则：判断前一律实时读 UIDevice.batteryState / batteryLevel。
3) 必须三层保险，缺一不可：
   第一层 %hook 拦截（最省资源）
   第二层 NSNotificationCenter 兜底（状态变化后恢复）
   第三层 NSTimer 看门狗（15 秒轮询，不依赖任何通知）
4) 必须内置自检：把 Loaded / HasSetter / LastProcess / LastEvent /
   LastCharging / LastLevel 写进 NSUserDefaults(suite)。
   用户用 Filza 打开 /var/mobile/Library/Preferences/<domain>.plist 即可自查。
5) 状态机禁止用"N 秒内第二次就放行"这类时间窗。
   坑：系统自身重试关闭会落在窗口内，被误判成用户操作，插件当场失效
   （模拟复现：拦截/放行/放行）。
   正确做法：拦截无条件生效；恢复类动作改为"每充电周期最多一次"，拔线重置。
6) 编译期常见错误先自查：NSUserDefaults 只有 setObject:forKey:，
   没有 setString: / setBool: / setFloat: 这些方法（实测直接编译失败）。
7) 所有改动走 propose_patch → apply_approved_patch，用户批准才落盘。
   被拒绝过的提案不得原样重复请求；换方案时说明差异。
8) 所有 hook 保留 %orig 原行为；%ctor 只做一次初始化；UI 相关回主线程。

【阶段 3：构建与核验】
1) build_project → 失败先读 read_diagnostics，按具体 error 修，不猜、不重复同样构建。
2) 成功后必须 list_artifacts 核验并逐项汇报：
   安装路径、control 字段、CPU 切片、install name、rpath、filter plist 是否随包安装。
3) 行为变了就改 control 的 Version，禁止"一个 1.0.0 对应多份不同代码"。
4) 需要 deb 真值核验时导入沙盒：
   dpkg-deb -I / -c / -x、lipo -info、otool -hv、otool -L、
   otool -l | grep -A3 LC_BUILD_VERSION、python3 plistlib 读 filter。

【阶段 4：Git】
1) git_initialize → git_set_remote(HTTPS) → git_stage(仅源码与配置)
   → git_save_version → git_upload，每步独立批准。
2) 不进仓库：.dylix/summaries、packages/、*.deb、*.dylib、.theos/
3) 推送失败先读错误原文再调整，不原样重试。
4) 推送后可用 GitHub API 读回文件核对，证明远端真的收到。

【阶段 5：CI 双切片（arm64 + arm64e）】
1) PAT 必须有 workflow scope，否则改 .github/workflows 的推送被拒：
   "refusing to allow a Personal Access Token to create or update workflow ... without 'workflow' scope"
2) runs-on 必须用 macos-15-intel（macos-14 已不在 runner 列表，
   会报 "The configuration 'macos-14-arm64-us-default' is not supported"）。
3) 构建步骤必须 set -o pipefail。
   坑：make package 2>&1 | tee log 的退出码取 tee，永远 0，
   失败被掩盖，最终表现为 "No files were found ... packages/*.deb"。
4) 必须 brew install ldid。
   坑：编译/链接/strip/merge 全成功后在 Signing 阶段报
   "/bin/bash: ldid: command not found" + "Error 127"。
5) 失败步骤要 if: always() 打印 tail -200 构建日志，否则看不到真实原因。
6) Theos 克隆不要用 --depth 1（子模块容易不完整），用 --recursive。
7) CI 产物不要只看绿色勾，用沙盒解包 lipo -info 实测切片数。

【阶段 6：真机验证】
1) 安装后必须 respring（killall -9 SpringBoard）。
2) 排查顺序：插件是否加载 → hook 是否命中 → 条件是否满足。
3) 日志：log stream --predicate 'eventMessage CONTAINS "[<前缀>]"' --style compact
4) 自检：Filza 打开 /var/mobile/Library/Preferences/<domain>.plist
   Loaded=1 + HasSetter=1 + LastProcess=SpringBoard → 加载与 hook 正常
   完全没有这些键 → 插件没被注入
   LastEvent：blocked / state-change-off / restored / watchdog-restored / watchdog-failed
5) 快速触发测试：把 Threshold 改到当前电量上方一点，改完 respring，测完改回。

【交付格式】
A. 已完成且有证据的：编译结果、产物字段、提交号、远端读回核对
B. 未验证的：注入、hook 命中、功能生效
C. 需要的下一步证据：用户手机上的自检键值或日志原文
禁止用"应该可以了""估计没问题"代替 A/B/C。
```

---

## 二、踩过的坑（14 条，含日志原文）

| # | 现象 | 根因 | 对策 |
|---|---|---|---|
| 1 | 新项目一建就是能编译的测试工程 | logos 模板自带 MobileLogosFixture 假类 | 替换 Tweak.xm / control / filter plist |
| 2 | 多项目互相覆盖 dylib | productName 默认 DylixTweak，安装路径同名 | 改成项目名 |
| 3 | 子目录 control 不生效 | 打包只读根目录 control（实测 9.9.9 → deb 仍 1.0.0） | control / filter plist 留根 |
| 4 | 担心源码进子目录编译不了 | sources 支持相对子路径 | 实测产物 sha 与根目录构建一致 |
| 5 | 插件偶尔完全失效 | 旧逻辑"5 秒内第二次放行"被系统重试命中（拦截/放行/放行） | 无条件拦截 + 每充电周期兜底一次 |
| 6 | 编译报 setString:forKey: 不存在 | NSUserDefaults 无该方法 | 改 setObject:forKey: |
| 7 | push 被拒 workflow scope | PAT 缺 workflow 权限 | classic 勾 workflow / fine-grained 给 Workflows: Read and write |
| 8 | Actions 1 秒失败 macos-14 不支持 | macos-14 已移出 runner 列表 | runs-on: macos-15-intel |
| 9 | 失败但看不到编译错误 | `make ... \| tee` 退出码取 tee | set -o pipefail + if: always() 打印日志 |
| 10 | No files were found packages/*.deb | 坑 9 的下游表现 | 同坑 9 |
| 11 | ldid: command not found（Error 127） | runner 未装 ldid | brew install ldid |
| 12 | 装上没效果也不崩溃 | SpringBoard 电池通知可能不触发，缓存停在 charging=NO | 实时读电池 + 看门狗 + 自检写 plist |
| 13 | 用户拒绝了某提案 | 不接受该方案 | 不重复请求；换方案并说明差异 |
| 14 | 误判"能用" | 从语气推断验证结果 | 结论只能来自明确行为描述或日志 |

---

## 三、验证边界

本机能证明：
- 编译通过、诊断为空
- deb 结构、control 字段、安装路径、CPU 切片、install name、rpath、filter plist 内容
- Git 是否推送成功（GitHub API 读回比对）
- CI 产物可用沙盒解包 + lipo 实测（已验证 `arm64 arm64e`）

本机不能证明：
- dylib 是否注入 SpringBoard
- 私有 selector 在目标系统是否存在
- 功能是否生效
- Actions 运行状态

---

## 四、命令速查

```bash
# 设备终端
log stream --predicate 'eventMessage CONTAINS "[StayLPM]"' --style compact
ls -l /var/jb/Library/MobileSubstrate/DynamicLibraries/ | grep -i <项目名>
defaults write <domain> Threshold -float 0.62
killall -9 SpringBoard

# 沙盒核验 deb
dpkg-deb -I x.deb; dpkg-deb -c x.deb; dpkg-deb -x x.deb root
lipo -info root/var/jb/Library/MobileSubstrate/DynamicLibraries/*.dylib
otool -hv <dylib>; otool -L <dylib>; otool -l <dylib> | grep -A3 LC_BUILD_VERSION
python3 -c "import plistlib,sys;print(plistlib.load(open(sys.argv[1],'rb')))" x.plist
```

---

## 五、交付前自查

```
□ 三处模板残留已清
□ productName 已改项目名
□ 源码在子目录、control + filter plist 在根
□ 私有 API 有运行时检查
□ 电池状态实时读、三层保险齐全
□ 自检键已写入
□ build 无 diagnostics，list_artifacts 已核验
□ 版本号与改动对应
□ Git 已推送且远端读回一致
□ workflow 用 macos-15-intel + ldid + pipefail + always() 日志
□ 报告已分"已验证 / 未验证 / 待补证据"
```
