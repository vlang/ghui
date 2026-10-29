#import <Cocoa/Cocoa.h>

static bool ghui_probe_attachment(NSView *view) {
    if ([view isKindOfClass:[NSTextView class]]) {
        NSTextStorage *storage = [(NSTextView *)view textStorage];
        for (NSUInteger i = 0; i < storage.length; i++) {
            NSTextAttachment *attachment = [storage attribute:NSAttachmentAttributeName
                atIndex:i effectiveRange:NULL];
            if (attachment && attachment.image.size.width == 52 && attachment.image.size.height == 20
                && attachment.bounds.size.width == 52 && attachment.bounds.size.height == 20
                && [[storage attribute:NSLinkAttributeName atIndex:i effectiveRange:NULL]
                    isEqual:@"https://example.com/review"]) return true;
        }
    }
    for (NSView *child in view.subviews) {
        if (ghui_probe_attachment(child)) return true;
    }
    return false;
}

static bool ghui_probe_has_badge(void) {
    for (NSWindow *window in NSApp.windows) {
        if (ghui_probe_attachment(window.contentView)) return true;
    }
    return false;
}
