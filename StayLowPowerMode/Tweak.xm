// StayLowPowerMode
// 目标：iOS 15+（Dopamine / rootless）充电到 80% 时不再自动关闭低电量模式
// 主拦截：SpringBoard 内 -[NSProcessInfo _setLowPowerModeEnabled:NO]
// 兜底：低电量模式被关闭后，若仍在充电且电量在阈值附近，则重新开启（每个充电周期最多一次）

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <stdlib.h>
#import <string.h>

#define SLPM_LOG(fmt, ...) NSLog(@"[StayLPM] " fmt, ##__VA_ARGS__)

// 偏好域：/var/mobile/Library/Preferences/com.dylix.staylowpowermode.plist
//   Enabled   (BOOL,   默认 YES)  总开关
//   Threshold (double, 默认 0.8)  阈值，0.8 = 80%
//   LogVerbose(BOOL,   默认 NO)   打印 SpringBoard 内 LowPower 候选类方法
static NSString *const kSLPMPrefsDomain = @"com.dylix.staylowpowermode";

static NSUserDefaults *SLPMDefaults(void) {
    static NSUserDefaults *defaults = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        defaults = [[NSUserDefaults alloc] initWithSuiteName:kSLPMPrefsDomain];
    });
    return defaults;
}

static BOOL SLPMFlag(NSString *key, BOOL fallback) {
    id value = [SLPMDefaults() objectForKey:key];
    return value ? [value boolValue] : fallback;
}

static double SLPMNumber(NSString *key, double fallback) {
    id value = [SLPMDefaults() objectForKey:key];
    return value ? [value doubleValue] : fallback;
}

static BOOL gRestoredThisCharge = NO;   // 本次充电周期内已兜底恢复过一次
static BOOL gLastKnownLowPower = NO;

static volatile BOOL gCachedCharging = NO;
static volatile float gCachedLevel = -1.0f;

// 直接实时读电池：SpringBoard 里 UIDevice 的电池通知不一定触发，
// 依赖缓存会让判定永远停在初始值（charging=NO），插件就等于没装。
static void SLPMReadBattery(BOOL *charging, float *level) {
    UIDevice *device = [UIDevice currentDevice];
    if (!device.isBatteryMonitoringEnabled) {
        device.batteryMonitoringEnabled = YES;
    }
    UIDeviceBatteryState state = device.batteryState;
    *charging = (state == UIDeviceBatteryStateCharging || state == UIDeviceBatteryStateFull);
    *level = device.batteryLevel;
    gCachedCharging = *charging;
    gCachedLevel = *level;
}

// 兼容旧调用点：构造期与电池通知里刷新一次
static void SLPMRefreshBatteryCache(void) {
    BOOL charging = NO;
    float level = -1.0f;
    SLPMReadBattery(&charging, &level);
}

// 自检：把运行状态写进偏好域，可用 Filza 打开
// /var/mobile/Library/Preferences/com.dylix.staylowpowermode.plist
// 关注键：Loaded / HasSetter / LastEvent / LastCharging / LastLevel / LastProcess
static void SLPMRecordState(NSString *event) {
    BOOL charging = NO;
    float level = -1.0f;
    SLPMReadBattery(&charging, &level);
    NSUserDefaults *defaults = SLPMDefaults();
    [defaults setBool:YES forKey:@"Loaded"];
    [defaults setObject:event forKey:@"LastEvent"];
    [defaults setObject:[NSDate date] forKey:@"LastEventDate"];
    [defaults setBool:charging forKey:@"LastCharging"];
    [defaults setFloat:level forKey:@"LastLevel"];
    [defaults setBool:[NSProcessInfo processInfo].isLowPowerModeEnabled forKey:@"LastLowPower"];
    [defaults synchronize];
}

// 开关开启 + 正在充电 + 电量达到阈值（电量未知时按“已满足”处理）
static BOOL SLPMChargingAtOrAboveThreshold(void) {
    if (!SLPMFlag(@"Enabled", YES)) return NO;
    BOOL charging = NO;
    float level = -1.0f;
    SLPMReadBattery(&charging, &level);
    if (!charging) return NO;
    double threshold = SLPMNumber(@"Threshold", 0.8);
    if (level > 0.001f && (double)level + 0.0005 < threshold) return NO;
    return YES;
}

// 返回 YES 表示丢弃这次“关闭”请求
// 充电且达到阈值期间一律拦截；不再按“短时间内第二次”放行，
// 因为系统自身重试关闭也会落在时间窗内，会被误判成用户操作。
// 用户出口：拔线，或在「设置 → 电池」关闭（该进程不在注入范围）。
static BOOL SLPMShouldBlockDisable(void) {
    return SLPMChargingAtOrAboveThreshold();
}

@interface NSProcessInfo (StayLowPowerPrivate)
- (void)_setLowPowerModeEnabled:(BOOL)enabled;
@end

static BOOL SLPMForceEnable(void) {
    NSProcessInfo *info = [NSProcessInfo processInfo];
    if ([info respondsToSelector:NSSelectorFromString(@"_setLowPowerModeEnabled:")]) {
        [info _setLowPowerModeEnabled:YES];
        if (info.isLowPowerModeEnabled) return YES;
    }
    // 备用路径：PowerUI 的 PMLowPowerMode（1 = 低电量模式）
    Class powerModeClass = objc_getClass("PMLowPowerMode");
    SEL setter = NSSelectorFromString(@"setPowerMode:fromSource:");
    if (powerModeClass && [powerModeClass respondsToSelector:setter]) {
        ((void (*)(id, SEL, int, id))objc_msgSend)(powerModeClass, setter, 1, @"StayLowPowerMode");
        return YES;
    }
    return NO;
}

static void SLPMHandleLowPowerStateChange(void) {
    BOOL enabled = [NSProcessInfo processInfo].isLowPowerModeEnabled;
    BOOL wasEnabled = gLastKnownLowPower;
    gLastKnownLowPower = enabled;
    SLPMRecordState(enabled ? @"state-change-on" : @"state-change-off");

    if (enabled) {
        gRestoredThisCharge = NO;   // 手动重新开启：恢复兜底能力
        return;
    }
    if (!wasEnabled) return;
    if (!SLPMChargingAtOrAboveThreshold()) return;

    // 自动关闭只发生在跨过阈值那一刻，远离阈值视为用户手动关闭
    double threshold = SLPMNumber(@"Threshold", 0.8);
    BOOL charging = NO;
    float level = -1.0f;
    SLPMReadBattery(&charging, &level);
    if (level > 0.001f && ((double)level < threshold - 0.06 || (double)level > threshold + 0.06)) {
        SLPM_LOG(@"低电量模式被关闭，但电量 %.0f%% 不在阈值附近，不干预", level * 100.0f);
        return;
    }

    // 每个充电周期最多恢复一次：既挡住系统重复关闭，也给用户留出手动关闭的出口
    if (gRestoredThisCharge) {
        SLPM_LOG(@"本次充电已恢复过一次，不再重复干预");
        return;
    }

    if (SLPMForceEnable()) {
        gRestoredThisCharge = YES;
        SLPMRecordState(@"restored");
        SLPM_LOG(@"低电量模式已被系统关闭，已兜底重新开启（电量 %.0f%%）", level * 100.0f);
    } else {
        SLPMRecordState(@"restore-failed");
        SLPM_LOG(@"兜底失败：当前进程没有 _setLowPowerModeEnabled:");
    }
}

static void SLPMDumpCandidates(void) {
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;
    Class *classes = (Class *)malloc(sizeof(Class) * (size_t)count);
    if (!classes) return;
    count = objc_getClassList(classes, count);
    for (int i = 0; i < count; i++) {
        const char *name = class_getName(classes[i]);
        if (!name || !strstr(name, "LowPower")) continue;
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(classes[i], &methodCount);
        for (unsigned int j = 0; j < methodCount; j++) {
            SLPM_LOG(@"候选 %s -> %s", name, sel_getName(method_getName(methods[j])));
        }
        if (methods) free(methods);
    }
    free(classes);
}

static void SLPMInstallObservers(void) {
    gLastKnownLowPower = [NSProcessInfo processInfo].isLowPowerModeEnabled;
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];

    [center addObserverForName:NSProcessInfoPowerStateDidChangeNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) {
        SLPMHandleLowPowerStateChange();
    }];

    void (^batteryBlock)(NSNotification *) = ^(NSNotification *note) {
        SLPMRefreshBatteryCache();
        BOOL charging = gCachedCharging;
        if (!charging) {
            gRestoredThisCharge = NO;   // 拔线：重置本次充电周期的兜底计数
        }
    };

    [center addObserverForName:UIDeviceBatteryStateDidChangeNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:batteryBlock];
    [center addObserverForName:UIDeviceBatteryLevelDidChangeNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:batteryBlock];
}

// 看门狗：即使 hook 与电池通知都没命中，也每 15 秒检查一次
static void SLPMWatchdogTick(void) {
    NSProcessInfo *info = [NSProcessInfo processInfo];
    BOOL enabled = info.isLowPowerModeEnabled;
    gLastKnownLowPower = enabled;
    if (enabled) {
        gRestoredThisCharge = NO;
        return;
    }
    if (!SLPMChargingAtOrAboveThreshold()) return;
    if (gRestoredThisCharge) return;

    BOOL charging = NO;
    float level = -1.0f;
    SLPMReadBattery(&charging, &level);
    if (SLPMForceEnable()) {
        gRestoredThisCharge = YES;
        SLPMRecordState(@"watchdog-restored");
        SLPM_LOG(@"看门狗：低电量模式被关闭，已重新开启（电量 %.0f%%）", level * 100.0f);
    } else {
        SLPMRecordState(@"watchdog-failed");
    }
}

static void SLPMStartWatchdog(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSTimer scheduledTimerWithTimeInterval:15.0 repeats:YES block:^(NSTimer *timer) {
            SLPMWatchdogTick();
        }];
    });
}

%group SLPMPrivate

%hook NSProcessInfo

- (void)_setLowPowerModeEnabled:(BOOL)enabled {
    if (enabled) {
        gRestoredThisCharge = NO;
        %orig;
        return;
    }

    if (SLPMShouldBlockDisable()) {
        BOOL charging = NO;
        float level = -1.0f;
        SLPMReadBattery(&charging, &level);
        SLPMRecordState(@"blocked");
        SLPM_LOG(@"已拦截低电量模式自动关闭（充电中，电量 %.0f%%）", level * 100.0f);
        return;
    }

    %orig;
}

%end

%end

%ctor {
    @autoreleasepool {
        BOOL enabled = SLPMFlag(@"Enabled", YES);
        SLPM_LOG(@"已加载（开关 %@，阈值 %.0f%%）", enabled ? @"开" : @"关", SLPMNumber(@"Threshold", 0.8) * 100.0);

        if ([NSThread isMainThread]) {
            SLPMRefreshBatteryCache();
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                SLPMRefreshBatteryCache();
            });
        }

        Class processInfo = objc_getClass("NSProcessInfo");
        BOOL hasPrivateSetter = processInfo != NULL &&
            class_getInstanceMethod(processInfo, NSSelectorFromString(@"_setLowPowerModeEnabled:")) != NULL;

        if (hasPrivateSetter) {
            %init(SLPMPrivate);
            SLPM_LOG(@"已挂载 _setLowPowerModeEnabled: 拦截");
        } else {
            SLPM_LOG(@"未找到 _setLowPowerModeEnabled:，仅启用兜底恢复");
        }

        [SLPMDefaults() setBool:YES forKey:@"Loaded"];
        [SLPMDefaults() setBool:hasPrivateSetter forKey:@"HasSetter"];
        [SLPMDefaults() setObject:[[NSProcessInfo processInfo] processName] forKey:@"LastProcess"];
        [SLPMDefaults() synchronize];

        SLPMInstallObservers();
        SLPMStartWatchdog();

        if (SLPMFlag(@"LogVerbose", NO)) {
            SLPMDumpCandidates();
        }
    }
}
