// ScaleFix - experimental. Overrides MobileGestalt "main-screen-scale" so UIKit lays the UI
// out for a larger point size on a low-resolution canvas (e.g. 960px / 2.4615 = ~390pt).
// Safety: crash-loop guard + on-screen confirmation with 15 s countdown that auto-reverts.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <substrate.h>
#import <dlfcn.h>
#import <spawn.h>
#include <string.h>
#include <unistd.h>
#include <math.h>

extern char **environ;
static CFStringRef const kDomain = CFSTR("com.scalefix");
static float gScale = 2.4615f;   // 960 / 2.4615 = 390 pt

#pragma mark - prefs helpers

static CFTypeRef readPref(CFStringRef key) {
    CFTypeRef v = CFPreferencesCopyAppValue(key, kDomain);
    if (!v) v = CFPreferencesCopyValue(key, kDomain, CFSTR("mobile"), kCFPreferencesAnyHost);
    return v; // caller releases
}
static float prefFloat(CFStringRef key, float def) {
    float out = def;
    CFTypeRef v = readPref(key);
    if (v) {
        if (CFGetTypeID(v) == CFNumberGetTypeID()) CFNumberGetValue((CFNumberRef)v, kCFNumberFloatType, &out);
        CFRelease(v);
    }
    return out;
}
static BOOL prefBool(CFStringRef key, BOOL def) {
    BOOL out = def;
    CFTypeRef v = readPref(key);
    if (v) {
        if (CFGetTypeID(v) == CFBooleanGetTypeID()) out = CFBooleanGetValue((CFBooleanRef)v);
        else if (CFGetTypeID(v) == CFNumberGetTypeID()) { int i = 0; CFNumberGetValue((CFNumberRef)v, kCFNumberIntType, &i); out = i != 0; }
        CFRelease(v);
    }
    return out;
}
static void setPrefBool(CFStringRef key, BOOL b) {
    CFPreferencesSetAppValue(key, b ? kCFBooleanTrue : kCFBooleanFalse, kDomain);
    CFPreferencesAppSynchronize(kDomain);
}
static void setPrefFloat(CFStringRef key, float f) {
    CFNumberRef n = CFNumberCreate(NULL, kCFNumberFloatType, &f);
    CFPreferencesSetAppValue(key, n, kDomain);
    CFRelease(n);
    CFPreferencesAppSynchronize(kDomain);
}
static void setPrefInt(CFStringRef key, int i) {
    CFNumberRef n = CFNumberCreate(NULL, kCFNumberIntType, &i);
    CFPreferencesSetAppValue(key, n, kDomain);
    CFRelease(n);
    CFPreferencesAppSynchronize(kDomain);
}

#pragma mark - MobileGestalt hooks

static CFTypeRef (*orig_MGCopyAnswer)(CFStringRef, CFDictionaryRef);
static float (*orig_MGGetFloat32Answer)(CFStringRef, float);

static BOOL isScaleKey(CFStringRef key) {
    return key && CFStringCompare(key, CFSTR("main-screen-scale"), 0) == kCFCompareEqualTo;
}
static CFTypeRef my_MGCopyAnswer(CFStringRef key, CFDictionaryRef opts) {
    if (isScaleKey(key)) { float f = gScale; return CFNumberCreate(NULL, kCFNumberFloat32Type, &f); }
    return orig_MGCopyAnswer(key, opts);
}
static float my_MGGetFloat32Answer(CFStringRef key, float def) {
    if (isScaleKey(key)) return gScale;
    return orig_MGGetFloat32Answer(key, def);
}

#pragma mark - revert + confirmation (SpringBoard only)

static void restartBackboardd(void) {
    pid_t pid;
    char *argv[] = { "killall", "backboardd", NULL };
    posix_spawn(&pid, "/var/jb/usr/bin/killall", NULL, NULL, argv, environ);
}
static void revertNow(void) {
    setPrefBool(CFSTR("disabled"), YES);
    restartBackboardd();
}

static UIWindow *sWindow;

static void showConfirm(void) {
    sWindow = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    sWindow.windowLevel = UIWindowLevelAlert + 1000;
    sWindow.rootViewController = [UIViewController new];
    [sWindow makeKeyAndVisible];

    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"ScaleFix"
        message:@"Keep this UI scale? Reverting in 15 s"
        preferredStyle:UIAlertControllerStyleAlert];
    __block int left = 15;
    __block NSTimer *timer = nil;
    [a addAction:[UIAlertAction actionWithTitle:@"Keep" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        [timer invalidate];
        setPrefFloat(CFSTR("confirmedScale"), gScale);
        sWindow.hidden = YES; sWindow = nil;
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Revert now" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
        [timer invalidate];
        revertNow();
    }]];
    [sWindow.rootViewController presentViewController:a animated:YES completion:nil];
    timer = [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *t) {
        left--;
        if (left <= 0) { [t invalidate]; revertNow(); return; }
        a.message = [NSString stringWithFormat:@"Keep this UI scale? Reverting in %d s", left];
    }];
}

// Crash-loop guard: if SpringBoard did not stay up 20 s twice in a row, disable ourselves.
static BOOL guardAllows(void) {
    BOOL started = prefBool(CFSTR("started"), NO), stable = prefBool(CFSTR("stable"), YES);
    float fails = prefFloat(CFSTR("fails"), 0);
    fails = (started && !stable) ? fails + 1 : 0;
    if (fails >= 2) {
        setPrefBool(CFSTR("disabled"), YES);
        setPrefInt(CFSTR("fails"), 0); setPrefBool(CFSTR("started"), NO); setPrefBool(CFSTR("stable"), YES);
        return NO;
    }
    setPrefInt(CFSTR("fails"), (int)fails); setPrefBool(CFSTR("started"), YES); setPrefBool(CFSTR("stable"), NO);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        setPrefBool(CFSTR("stable"), YES); setPrefInt(CFSTR("fails"), 0);
    });
    return YES;
}

#pragma mark - init

__attribute__((constructor)) static void scalefix_init(void) {
    @autoreleasepool {
        const char *prog = getprogname();
        BOOL isSB = prog && strcmp(prog, "SpringBoard") == 0;

        if (prefBool(CFSTR("disabled"), NO)) return;
        if (isSB && !guardAllows()) return;

        float s = prefFloat(CFSTR("scale"), gScale);
        if (s >= 1.5f && s <= 3.5f) gScale = s;

        void *h = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_LAZY);
        void *a = dlsym(h ? h : RTLD_DEFAULT, "MGCopyAnswer");
        void *b = dlsym(h ? h : RTLD_DEFAULT, "MGGetFloat32Answer");
        if (a) MSHookFunction(a, (void *)my_MGCopyAnswer, (void **)&orig_MGCopyAnswer);
        if (b) MSHookFunction(b, (void *)my_MGGetFloat32Answer, (void **)&orig_MGGetFloat32Answer);

        if (isSB) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                if (fabsf(prefFloat(CFSTR("confirmedScale"), 0) - gScale) > 0.001f) showConfirm();
            });
        }
    }
}
