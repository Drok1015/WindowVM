// WindowVM's Cocoa adapter for the pinned Homebrew QEMU 11.1.3 engine.
// The QEMU view owns rendering/input; this adapter owns geometry and sends
// resolution requests to the authenticated Windows guest bridge.
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>
#import <unistd.h>

static const NSTimeInterval ResizeInterval = 0.8;
static CFTimeInterval lastSent = -INFINITY;
static NSSize lastSize;
static __weak NSView *pendingView;
static BOOL scheduled;
static NSString *session;
static NSUInteger sequence;
static char configuredWindow;

static NSString *StateDirectory(void) {
  const char *value = getenv("WINDOWVM_STATE_DIR");
  return value ? [NSString stringWithUTF8String:value] : nil;
}

static NSSize TargetSize(NSView *view) {
  NSSize size = view.frame.size;
  // Render one guest pixel per backing pixel. Windows display scaling keeps
  // text readable without magnifying a low-resolution framebuffer.
  CGFloat scale = MAX(1, view.window.backingScaleFactor);
  size.width *= scale; size.height *= scale;
  return NSMakeSize(MAX(640, MIN(3840, floor(size.width / 8) * 8)),
                    MAX(480, MIN(2160, floor(size.height / 2) * 2)));
}

static void Publish(NSView *view) {
  if (!view.window || !StateDirectory()) return;
  NSSize size = TargetSize(view);
  if (NSEqualSizes(size, lastSize)) return;
  if (!session) session = NSUUID.UUID.UUIDString;
  NSDictionary *request = @{@"id": [NSString stringWithFormat:@"%@:%lu", session, (unsigned long)++sequence],
                            @"width": @((NSInteger)size.width), @"height": @((NSInteger)size.height),
                            @"intervalMs": @800};
  NSError *error;
  NSData *data = [NSJSONSerialization dataWithJSONObject:request options:0 error:&error];
  NSString *path = [StateDirectory() stringByAppendingPathComponent:@"display-request.json"];
  if (data && [data writeToFile:path options:NSDataWritingAtomic error:&error]) {
    lastSize = size;
    lastSent = CACurrentMediaTime();
    [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions:@0600} ofItemAtPath:path error:nil];
  } else {
    NSLog(@"WindowVM display request failed: %@", error);
  }
}

static void ThrottledUIInfo(NSView *view, SEL selector) {
  if (!NSThread.isMainThread) {
    dispatch_async(dispatch_get_main_queue(), ^{ ThrottledUIInfo(view, selector); });
    return;
  }
  pendingView = view;
  NSTimeInterval remaining = ResizeInterval - (CACurrentMediaTime() - lastSent);
  if (remaining <= 0) {
    Publish(view);
    return;
  }
  if (scheduled) return;
  scheduled = YES;
  NSTimer *timer = [NSTimer timerWithTimeInterval:remaining repeats:NO block:^(NSTimer *timer) {
    scheduled = NO;
    // Read the current frame at execution time: this is a trailing throttle,
    // not a debounce. Continuous drags still publish every 800ms.
    NSView *latest = pendingView;
    if (latest) ThrottledUIInfo(latest, selector);
  }];
  // AppKit tracks a live window resize in a separate run-loop mode. Common
  // modes keep the throttle firing throughout the drag, not only on release.
  [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
}

static void ResizeWindow(NSView *view, SEL selector) {
  NSWindow *window = view.window;
  if (!window) return;
  window.styleMask |= NSWindowStyleMaskResizable;
  window.contentMinSize = NSMakeSize(640, 480);
  window.contentResizeIncrements = NSMakeSize(1, 1); // Clears the fixed aspect constraint.
  view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  if (!objc_getAssociatedObject(window, &configuredWindow)) {
    objc_setAssociatedObject(window, &configuredWindow, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSRect available = (window.screen ?: NSScreen.mainScreen).visibleFrame;
    [window setContentSize:NSMakeSize(MIN(1280, available.size.width - 80), MIN(800, available.size.height - 100))];
    [window center];
    __weak NSView *weakView = view;
    id observer = [NSNotificationCenter.defaultCenter addObserverForName:NSWindowDidChangeBackingPropertiesNotification object:window queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
      NSView *current = weakView;
      if (current) ThrottledUIInfo(current, NSSelectorFromString(@"updateUIInfo"));
    }];
    objc_setAssociatedObject(window, @selector(backingScaleFactor), observer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) {
      NSView *current = weakView;
      if (!current.window) { [timer invalidate]; return; }
      NSString *ready = [StateDirectory() stringByAppendingPathComponent:@"display-configured"];
      if ([[NSFileManager defaultManager] fileExistsAtPath:ready]) {
        SEL select = NSSelectorFromString(@"displayConsole:");
        id controller = NSApp.delegate;
        if ([controller respondsToSelector:select]) {
          NSMenuItem *item = [NSMenuItem new]; item.tag = 1; // ramfb=0, VirtIO GPU=1.
          IMP action = [controller methodForSelector:select];
          ((void (*)(id, SEL, id))action)(controller, select, item);
        }
        [timer invalidate];
      }
    }];
  }
  // Never resize the host window in response to a new guest framebuffer.
  // That would turn resolution acknowledgements into a geometry feedback loop.
}

// Closing the native Engine window asks the manager to save; it never invokes
// QEMU's original destructive UI termination path. QMP quit remains available.
static BOOL suspendRequested;
NSPanel *WVMCreateSuspendPanel(void) {
  NSPanel *panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 480, 146)
    styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
  panel.title = @"保存并暂停 Windows";
  NSProgressIndicator *spinner = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(24, 85, 24, 24)];
  spinner.style = NSProgressIndicatorStyleSpinning;
  [spinner startAnimation:nil];
  [panel.contentView addSubview:spinner];
  NSTextField *heading = [NSTextField labelWithString:@"正在保存 Windows 内存与设备状态…"];
  heading.frame = NSMakeRect(62, 88, 394, 24);
  heading.font = [NSFont boldSystemFontOfSize:14];
  [panel.contentView addSubview:heading];
  NSTextField *detail = [NSTextField wrappingLabelWithString:@"正在连接管理应用…\n保存完成后窗口会自动关闭，请勿强制退出。"];
  detail.frame = NSMakeRect(24, 20, 432, 54);
  detail.tag = 100;
  [panel.contentView addSubview:detail];
  return panel;
}

static void RequestSuspend(NSWindow *requestedWindow) {
  if (suspendRequested || !StateDirectory()) return;
  NSString *identifier = NSUUID.UUID.UUIDString;
  NSDictionary *request = @{@"id": identifier, @"pid": @(getpid()), @"action": @"suspend"};
  NSString *path = [StateDirectory() stringByAppendingPathComponent:@"lifecycle-request.json"];
  NSError *error = nil;
  NSData *data = [NSJSONSerialization dataWithJSONObject:request options:0 error:&error];
  if (![data writeToFile:path options:NSDataWritingAtomic error:&error]) {
    NSAlert *alert = [NSAlert new]; alert.messageText = @"无法请求暂停";
    alert.informativeText = error.localizedDescription ?: @"窗口已保留，请在 WindowVM 中重试。";
    [alert runModal]; return;
  }
  [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions:@0600} ofItemAtPath:path error:nil];
  suspendRequested = YES;
  NSWindow *window = requestedWindow ?: NSApp.mainWindow ?: NSApp.keyWindow;
  NSString *title = window.title;
  NSPanel *progress = nil;
  if (window.visible) {
    progress = WVMCreateSuspendPanel();
    [window beginSheet:progress completionHandler:nil];
  }
  window.title = @"WindowVM · 正在保存运行状态…";
  NSDate *started = NSDate.date;
  __block BOOL accepted = NO;
  NSTimer *timer = [NSTimer timerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *timer) {
    NSData *reply = [NSData dataWithContentsOfFile:[StateDirectory() stringByAppendingPathComponent:@"lifecycle-response.json"]];
    NSDictionary *response = reply ? [NSJSONSerialization JSONObjectWithData:reply options:0 error:nil] : nil;
    BOOL matches = [response[@"id"] isEqual:identifier];
    if (matches && [response[@"status"] isEqual:@"saving"]) accepted = YES;
    BOOL failed = matches && [response[@"status"] isEqual:@"error"];
    NSInteger elapsed = (NSInteger)-started.timeIntervalSinceNow;
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:
      [StateDirectory() stringByAppendingPathComponent:@"suspend.bin"] error:nil];
    double gib = [attributes[NSFileSize] doubleValue] / (1024.0 * 1024 * 1024);
    NSString *state = accepted ? [NSString stringWithFormat:@"已写入 %.1f GB · 已用时 %ld 秒", gib, (long)elapsed] : @"正在连接管理应用…";
    NSTextField *detail = [progress.contentView viewWithTag:100];
    detail.stringValue = [state stringByAppendingString:@"\n保存完成后窗口会自动关闭，请勿强制退出。"];
    window.title = [NSString stringWithFormat:@"WindowVM · 正在保存 · %ld 秒", (long)elapsed];
    if (failed || (!accepted && -started.timeIntervalSinceNow > 8)) {
      [timer invalidate]; suspendRequested = NO; window.title = title;
      if (progress) { [window endSheet:progress]; [progress orderOut:nil]; }
      NSAlert *alert = [NSAlert new]; alert.messageText = @"Windows 尚未暂停";
      alert.informativeText = failed ? response[@"error"] : @"WindowVM 管理应用没有响应。窗口已保留，请打开管理应用后重试；不要强制退出 Engine。";
      [alert runModal];
    }
  }];
  [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
}
static BOOL SuspendOnClose(id self, SEL selector, id sender) {
  RequestSuspend([sender isKindOfClass:NSWindow.class] ? sender : nil); return NO;
}
static NSApplicationTerminateReply SuspendOnQuit(id self, SEL selector, id sender) {
  RequestSuspend(nil); return NSTerminateCancel;
}

BOOL WVMInstallLifecycleHooks(void) {
  Class controller = NSClassFromString(@"QemuCocoaAppController");
  Method close = class_getInstanceMethod(controller, @selector(windowShouldClose:));
  Method quit = class_getInstanceMethod(controller, @selector(applicationShouldTerminate:));
  if (!close || !quit || method_getNumberOfArguments(close) != 3 || method_getNumberOfArguments(quit) != 3) return NO;
  method_setImplementation(close, (IMP)SuspendOnClose);
  method_setImplementation(quit, (IMP)SuspendOnQuit);
  return YES;
}

BOOL WVMInstallDisplayHooks(void) {
  Class viewClass = NSClassFromString(@"QemuCocoaView");
  Method resize = class_getInstanceMethod(viewClass, NSSelectorFromString(@"resizeWindow"));
  Method info = class_getInstanceMethod(viewClass, NSSelectorFromString(@"updateUIInfo"));
  if (!resize || !info || method_getNumberOfArguments(resize) != 2 || method_getNumberOfArguments(info) != 2) return NO;
  method_setImplementation(resize, (IMP)ResizeWindow);
  method_setImplementation(info, (IMP)ThrottledUIInfo);
  return YES;
}

#ifndef WINDOWVM_DISPLAY_TEST
__attribute__((constructor)) static void Install(void) {
  @autoreleasepool {
    if (!StateDirectory()) return; // Headless tools and explicit standalone launches.
    if (!WVMInstallDisplayHooks() || !WVMInstallLifecycleHooks()) {
      fprintf(stderr, "WindowVM: incompatible QEMU Cocoa display adapter; rebuild with the pinned engine.\n");
      exit(78);
    }
  }
}
#endif
