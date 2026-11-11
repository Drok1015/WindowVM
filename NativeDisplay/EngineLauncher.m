#import <AppKit/AppKit.h>
#import <unistd.h>
int main(int argc, char **argv) {
  @autoreleasepool {
    NSURL *bundle = NSBundle.mainBundle.bundleURL;
    if (argc == 1 && !getenv("WINDOWVM_STATE_DIR")) {
      // A Dock/Finder launch must re-enter the manager, which owns saved state.
      NSURL *manager = bundle.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent;
      return [NSWorkspace.sharedWorkspace openURL:manager] ? 0 : 1;
    }
    NSString *engine = [bundle.path stringByAppendingPathComponent:@"Contents/MacOS/QEMU"];
    const char *adapter = getenv("WINDOWVM_DISPLAY_LIBRARY");
    if (adapter) setenv("DYLD_INSERT_LIBRARIES", adapter, 1);
    argv[0] = (char *)engine.fileSystemRepresentation;
    execv(argv[0], argv);
    perror("WindowVM Engine");
    return 1;
  }
}
