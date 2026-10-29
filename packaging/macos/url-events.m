#import <Cocoa/Cocoa.h>

static void (*ghui_url_callback)(const char *);

@interface GhuiURLHandler : NSObject
@end
@implementation GhuiURLHandler
- (void)openURL:(NSAppleEventDescriptor *)event reply:(NSAppleEventDescriptor *)reply {
    NSString *target = [[event paramDescriptorForKeyword:keyDirectObject] stringValue];
    if (target && ghui_url_callback) ghui_url_callback(target.UTF8String);
    [NSApp activateIgnoringOtherApps:YES];
    for (NSWindow *window in NSApp.windows) {
        if (window.canBecomeKeyWindow) { [window makeKeyAndOrderFront:nil]; break; }
    }
}
@end

static void ghui_install_url_handler(void (*callback)(const char *)) {
    ghui_url_callback = callback;
    static GhuiURLHandler *handler;
    handler = [GhuiURLHandler new];
    [[NSAppleEventManager sharedAppleEventManager] setEventHandler:handler
        andSelector:@selector(openURL:reply:) forEventClass:kInternetEventClass andEventID:kAEGetURL];
}

static bool ghui_open_browser(const char *target) {
    NSURL *url = [NSURL URLWithString:[NSString stringWithUTF8String:target]];
    if (!url) return false;
    if (![@[@"http", @"https", @"ghui"] containsObject:url.scheme.lowercaseString])
        return [[NSWorkspace sharedWorkspace] openURL:url];
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:
        @"Library/Application Support/ghgui/link-routing.plist"];
    NSDictionary *config = [NSDictionary dictionaryWithContentsOfFile:path];
    NSString *browser = config[[url.scheme.lowercaseString isEqualToString:@"http"] ? @"http" : @"https"];
    NSURL *app = browser ? [[NSWorkspace sharedWorkspace] URLForApplicationWithBundleIdentifier:browser] : nil;
    if (!app) {
        NSURL *current = [[NSWorkspace sharedWorkspace] URLForApplicationToOpenURL:url];
        NSString *bundleID = [NSBundle bundleWithURL:current].bundleIdentifier;
        if (![bundleID isEqualToString:@"io.github.ghui"] && ![bundleID isEqualToString:@"io.github.ghui.links"])
            app = current;
    }
    if (!app) app = [[NSWorkspace sharedWorkspace] URLForApplicationWithBundleIdentifier:@"com.apple.Safari"];
    if (!app) return false;
    [[NSWorkspace sharedWorkspace] openURLs:@[url] withApplicationAtURL:app
        configuration:[NSWorkspaceOpenConfiguration configuration] completionHandler:nil];
    return true;
}
