#import <Cocoa/Cocoa.h>

// Accessed on the main thread, including all URL-session completions.
static NSCache *ghui_inline_images;
static NSMutableSet *ghui_pending_images;
static NSMutableSet *ghui_failed_images;

static bool ghui_inline_image_size(const char *source, void (*refresh)(void), double *width, double *height) {
    if (!ghui_inline_images) {
        ghui_inline_images = [NSCache new];
        ghui_inline_images.countLimit = 128;
        ghui_inline_images.totalCostLimit = 64 * 1024 * 1024;
        ghui_pending_images = [NSMutableSet new];
        ghui_failed_images = [NSMutableSet new];
    }
    NSString *key = [NSString stringWithUTF8String:source];
    NSImage *image = [ghui_inline_images objectForKey:key];
    if (image && image.size.width > 0 && image.size.height > 0) {
        *width = image.size.width;
        *height = image.size.height;
        return true;
    }
    if ([ghui_pending_images containsObject:key] || [ghui_failed_images containsObject:key]) return false;

    // Local assets are supported by the UI API; the discussion parser supplies
    // only HTTP(S) destinations for user-provided Markdown images.
    if ([key hasPrefix:@"/"]) {
        image = [[[NSImage alloc] initWithContentsOfFile:key] autorelease];
        if (image && image.size.width > 0 && image.size.height > 0) {
            [ghui_inline_images setObject:image forKey:key];
            *width = image.size.width;
            *height = image.size.height;
            return true;
        }
        [ghui_failed_images addObject:key];
        return false;
    }

    NSURL *url = [NSURL URLWithString:key];
    if (!url || ![@[@"http", @"https"] containsObject:url.scheme.lowercaseString]) return false;
    [ghui_pending_images addObject:key];
    NSURLRequest *request = [NSURLRequest requestWithURL:url
        cachePolicy:NSURLRequestUseProtocolCachePolicy timeoutInterval:15];
    [[[NSURLSession sharedSession] dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSImage *loaded = nil;
                NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]]
                    ? [(NSHTTPURLResponse *)response statusCode] : 0;
                if (!error && status >= 200 && status < 300 && data.length <= 8 * 1024 * 1024) {
                    loaded = [[[NSImage alloc] initWithData:data] autorelease];
                }
                [ghui_pending_images removeObject:key];
                if (loaded && loaded.size.width > 0 && loaded.size.height > 0) {
                    [ghui_inline_images setObject:loaded forKey:key cost:data.length];
                    if (refresh) refresh();
                } else {
                    [ghui_failed_images addObject:key];
                }
            });
        }] resume];
    return false;
}

static void ghui_text_view_add_image(void *view, uint64_t location, const char *source, double width, double height) {
    NSTextView *textView = (NSTextView *)view;
    NSImage *image = [ghui_inline_images objectForKey:[NSString stringWithUTF8String:source]];
    if (!image || location >= textView.textStorage.length) return;
    NSTextAttachment *attachment = [[[NSTextAttachment alloc] init] autorelease];
    attachment.image = image;
    attachment.bounds = NSMakeRect(0, -3, width, height);
    [textView.textStorage addAttribute:NSAttachmentAttributeName value:attachment
        range:NSMakeRange(location, 1)];
}
