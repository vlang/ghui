#import <Cocoa/Cocoa.h>
#import <CoreServices/CoreServices.h>

static NSString *const routerID = @"io.github.ghui.links";

static NSString *configPath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:
        @"Library/Application Support/ghgui/link-routing.plist"];
}

static NSString *defaultHandler(NSString *scheme) {
    NSURL *url = [NSURL URLWithString:[scheme stringByAppendingString:@"://example.com"]];
    NSURL *app = [[NSWorkspace sharedWorkspace] URLForApplicationToOpenURL:url];
    return app ? [NSBundle bundleWithURL:app].bundleIdentifier : nil;
}

static BOOL setHandler(NSString *scheme, NSString *bundleID) {
    if ([defaultHandler(scheme) isEqualToString:bundleID]) return YES;
    NSURL *app = [bundleID isEqualToString:routerID] ? [NSBundle mainBundle].bundleURL
        : [[NSWorkspace sharedWorkspace] URLForApplicationWithBundleIdentifier:bundleID];
    if (!app) return NO;
    __block BOOL finished = NO;
    __block NSError *failure = nil;
    [[NSWorkspace sharedWorkspace] setDefaultApplicationAtURL:app toOpenURLsWithScheme:scheme
        completionHandler:^(NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{ failure = error; finished = YES; });
        }];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:45];
    while (!finished && deadline.timeIntervalSinceNow > 0)
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    if (!finished || failure || ![defaultHandler(scheme) isEqualToString:bundleID]) {
        fprintf(stderr, "Could not set the %s link handler: %s\n", scheme.UTF8String,
            failure ? failure.localizedDescription.UTF8String : "macOS confirmation is required.");
        return NO;
    }
    return YES;
}

static BOOL canOpen(NSURL *url, NSDictionary *config) {
    if (![@[@"http", @"https", @"ghui"] containsObject:url.scheme.lowercaseString]
        || ![@[@"github.com", @"www.github.com"] containsObject:url.host.lowercaseString]) return NO;
    NSTask *probe = [NSTask new];
    probe.executableURL = [NSURL fileURLWithPath:[config[@"app"] stringByAppendingPathComponent:@"Contents/MacOS/ghui"]];
    probe.arguments = @[@"--can-open", url.absoluteString];
    probe.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    probe.standardError = [NSFileHandle fileHandleWithNullDevice];
    NSError *error;
    if (![probe launchAndReturnError:&error]) return NO;
    [probe waitUntilExit];
    return probe.terminationStatus == 0;
}

static NSURL *destination(NSURL *url, NSDictionary *config) {
    if (canOpen(url, config)) return [NSURL fileURLWithPath:config[@"app"]];
    NSString *scheme = [url.scheme.lowercaseString isEqualToString:@"http"] ? @"http" : @"https";
    NSString *browser = config[scheme];
    if ([browser isEqualToString:routerID] || [browser isEqualToString:@"io.github.ghui"]) browser = nil;
    NSURL *app = browser ? [[NSWorkspace sharedWorkspace] URLForApplicationWithBundleIdentifier:browser] : nil;
    return app ?: [[NSWorkspace sharedWorkspace] URLForApplicationWithBundleIdentifier:@"com.apple.Safari"];
}

@interface GhuiLinkRouter : NSObject <NSApplicationDelegate>
@end
@implementation GhuiLinkRouter
- (void)application:(NSApplication *)application openURLs:(NSArray<NSURL *> *)urls {
    NSDictionary *config = [NSDictionary dictionaryWithContentsOfFile:configPath()];
    for (NSURL *url in urls) {
        NSURL *app = destination(url, config);
        if (!app) { NSLog(@"No application available for %@", url); continue; }
        [[NSWorkspace sharedWorkspace] openURLs:@[url] withApplicationAtURL:app
            configuration:[NSWorkspaceOpenConfiguration configuration]
            completionHandler:^(NSRunningApplication *running, NSError *error) {
                if (error) NSLog(@"Could not open %@: %@", url, error);
            }];
    }
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSDictionary *saved = [NSDictionary dictionaryWithContentsOfFile:configPath()];
        if (argc == 3 && strcmp(argv[1], "--install") == 0) {
            NSString *appPath = [[NSString stringWithUTF8String:argv[2]] stringByStandardizingPath];
            NSURL *app = [NSURL fileURLWithPath:appPath];
            if (![[NSFileManager defaultManager] isExecutableFileAtPath:
                [appPath stringByAppendingPathComponent:@"Contents/MacOS/ghui"]]) {
                fprintf(stderr, "Github.app is missing its ghui executable.\n"); return 1;
            }
            NSMutableDictionary *config = saved ? [saved mutableCopy] : [NSMutableDictionary new];
            for (NSString *scheme in @[@"http", @"https"]) {
                NSString *current = defaultHandler(scheme);
                if (current && ![current isEqualToString:routerID]) config[scheme] = current;
                if (!config[scheme]) config[scheme] = @"com.apple.Safari";
            }
            config[@"app"] = appPath;
            NSError *error;
            if (![[NSFileManager defaultManager] createDirectoryAtPath:[configPath() stringByDeletingLastPathComponent]
                withIntermediateDirectories:YES attributes:nil error:&error]
                || ![config writeToFile:configPath() atomically:YES]) {
                fprintf(stderr, "Could not save link routing configuration.\n"); return 1;
            }
            NSURL *router = [NSBundle mainBundle].bundleURL;
            if (LSRegisterURL((__bridge CFURLRef)app, true) || LSRegisterURL((__bridge CFURLRef)router, true)) {
                fprintf(stderr, "Could not register the applications with Launch Services.\n"); return 1;
            }
            BOOL http = setHandler(@"http", routerID);
            BOOL https = http && setHandler(@"https", routerID);
            if (!https) {
                // Keep the original browser usable if macOS refuses the change.
                for (NSString *scheme in @[@"http", @"https"])
                    if ([defaultHandler(scheme) isEqualToString:routerID]) setHandler(scheme, config[scheme]);
                fprintf(stderr, "Select Github Links in System Settings > Desktop & Dock > Default web browser.\n");
                return 1;
            }
            printf("GitHub links now open in ghui. Other links use %s.\n", [config[@"https"] UTF8String]);
            return 0;
        }
        if (argc == 2 && strcmp(argv[1], "--uninstall") == 0) {
            BOOL success = YES;
            for (NSString *scheme in @[@"http", @"https"])
                if ([defaultHandler(scheme) isEqualToString:routerID])
                    success = setHandler(scheme, saved[scheme] ?: @"com.apple.Safari") && success;
            return success ? 0 : 1;
        }
        if (argc == 2 && strcmp(argv[1], "--status") == 0) {
            for (NSString *scheme in @[@"http", @"https"])
                printf("%s: %s\n", scheme.UTF8String, defaultHandler(scheme).UTF8String);
            printf("ghui: %s\n", [saved[@"app"] UTF8String]);
            return 0;
        }
        if (argc == 3 && strcmp(argv[1], "--test-route") == 0) {
            NSURL *url = [NSURL URLWithString:[NSString stringWithUTF8String:argv[2]]];
            NSURL *app = url ? destination(url, saved) : nil;
            if (!app) return 1;
            puts(app.path.UTF8String);
            return 0;
        }
        NSApplication *application = [NSApplication sharedApplication];
        GhuiLinkRouter *delegate = [GhuiLinkRouter new];
        application.delegate = delegate;
        [application setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [application run];
    }
    return 0;
}
