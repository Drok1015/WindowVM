#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
extern BOOL WVMInstallDisplayHooks(void);
extern BOOL WVMInstallLifecycleHooks(void);
extern NSPanel *WVMCreateSuspendPanel(void);
@interface QemuCocoaAppController : NSObject
- (BOOL)windowShouldClose:(id)sender;
- (NSApplicationTerminateReply)applicationShouldTerminate:(id)sender;
@end
@implementation QemuCocoaAppController
- (BOOL)windowShouldClose:(id)sender { abort(); }
- (NSApplicationTerminateReply)applicationShouldTerminate:(id)sender { abort(); }
@end
@interface QemuCocoaView : NSView
- (void)resizeWindow;
- (void)updateUIInfo;
@end
@implementation QemuCocoaView
- (void)resizeWindow { self.window.contentAspectRatio = NSMakeSize(4,3); }
- (void)updateUIInfo { abort(); } // The adapter must replace the engine's delayed UI notification.
@end
@interface TestWindow : NSWindow
@property CGFloat testScale;
@end
@implementation TestWindow
- (CGFloat)backingScaleFactor { return self.testScale > 0 ? self.testScale : 1; }
@end
@interface TestController : NSObject <NSApplicationDelegate>
@property NSInteger selected;
@property NSInteger selections;
- (void)displayConsole:(NSMenuItem *)item;
@end
@implementation TestController
- (void)displayConsole:(NSMenuItem *)item { self.selected=item.tag; self.selections++; }
@end
static void Run(double seconds) { [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]]; }
static void RunTracking(double seconds) {
  NSDate *end=[NSDate dateWithTimeIntervalSinceNow:seconds];
  while (end.timeIntervalSinceNow>0) [NSRunLoop.currentRunLoop runMode:NSEventTrackingRunLoopMode beforeDate:end];
}
static NSDictionary *Read(NSString *root) {
  NSData *data=[NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:@"display-request.json"]];
  return data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
}
#define Check(x) do { if (!(x)) { fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#x); return 1; } } while(0)
int main(void) { @autoreleasepool {
  NSString *root=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
  [[NSFileManager defaultManager] createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
  setenv("WINDOWVM_STATE_DIR",root.UTF8String,1);
  [NSApplication sharedApplication];
  TestController *controller=[TestController new]; NSApp.delegate=controller;
  Check(WVMInstallDisplayHooks());
  TestWindow *window=[[TestWindow alloc] initWithContentRect:NSMakeRect(0,0,1000,700) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:YES];
  QemuCocoaView *view=[[QemuCocoaView alloc] initWithFrame:NSMakeRect(0,0,1000,700)];
  window.contentView=view;
  [view resizeWindow];
  Check(window.styleMask & NSWindowStyleMaskResizable);
  [view setFrameSize:NSMakeSize(1000,700)]; [view updateUIInfo];
  NSDictionary *first=Read(root); Check([first[@"width"] intValue]==1000); Check([first[@"height"] intValue]==700);
  Run(.15); [view setFrameSize:NSMakeSize(1111,777)]; [view updateUIInfo];
  Run(.15); [view setFrameSize:NSMakeSize(1333,811)]; [view updateUIInfo];
  Check([Read(root)[@"id"] isEqual:first[@"id"]]);
  RunTracking(.56); NSDictionary *last=Read(root);
  Check(![last[@"id"] isEqual:first[@"id"]]);
  Check([last[@"width"] intValue]==1328 && [last[@"height"] intValue]==810);
  // A guest framebuffer update must preserve the freely chosen host geometry.
  NSSize before=window.frame.size; [view resizeWindow]; Check(NSEqualSizes(window.frame.size,before));
  [view updateUIInfo]; Run(.85); Check([Read(root)[@"id"] isEqual:last[@"id"]]);
  [view setFrameSize:NSMakeSize(5000,100)]; [view updateUIInfo];
  Check([Read(root)[@"width"] intValue]==3840 && [Read(root)[@"height"] intValue]==480);
  Run(.85); window.testScale=2;
  [view setFrameSize:NSMakeSize(1280,800)]; [view updateUIInfo];
  Check([Read(root)[@"width"] intValue]==2560 && [Read(root)[@"height"] intValue]==1600);
  Run(.85); window.testScale=1;
  [NSNotificationCenter.defaultCenter postNotificationName:NSWindowDidChangeBackingPropertiesNotification object:window];
  Check([Read(root)[@"width"] intValue]==1280 && [Read(root)[@"height"] intValue]==800);
  [NSData.data writeToFile:[root stringByAppendingPathComponent:@"display-configured"] atomically:YES];
  Run(.6); Check(controller.selections==1 && controller.selected==1);
  Run(.6); Check(controller.selections==1);
  NSPanel *progress = WVMCreateSuspendPanel();
  Check([progress.title isEqual:@"保存并暂停 Windows"]);
  NSTextField *detail = [progress.contentView viewWithTag:100];
  Check([detail.stringValue containsString:@"保存完成后窗口会自动关闭"]);
  Check(!(progress.styleMask & NSWindowStyleMaskClosable));
  Check(WVMInstallLifecycleHooks());
  QemuCocoaAppController *lifecycle = [QemuCocoaAppController new];
  Check(![lifecycle windowShouldClose:window]);
  NSData *requestData = [NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:@"lifecycle-request.json"]];
  NSDictionary *request = [NSJSONSerialization JSONObjectWithData:requestData options:0 error:nil];
  Check([request[@"action"] isEqual:@"suspend"] && [request[@"pid"] intValue] == getpid());
  Check([lifecycle applicationShouldTerminate:NSApp] == NSTerminateCancel);
  Check([[NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:@"lifecycle-request.json"]] isEqual:requestData]);
  [[NSFileManager defaultManager] removeItemAtPath:root error:nil];
  printf("PASS: 800ms leading/trailing throttle during event tracking, latest-size coalescing, independent aspect, no feedback/duplicates, safe bounds, Retina backing pixels and screen changes, GPU console activation, safe close/quit interception, duplicate suppression and non-dismissible save feedback\n");
} return 0; }
