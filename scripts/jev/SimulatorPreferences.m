#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/message.h>

NSDictionary *JevSimulatorAction(NSDictionary *request);

// Keep preferences and native input warm. Arrays read preferences; dictionaries
// perform one bounded accessibility action with a fresh target assertion.
static void serve(void) {
    char *line = NULL;
    size_t capacity = 0;
    while (getline(&line, &capacity, stdin) > 0) {
        @autoreleasepool {
            NSError *error = nil;
            NSData *data = [[NSString stringWithUTF8String:line] dataUsingEncoding:NSUTF8StringEncoding];
            id request = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
            NSMutableDictionary *result = [NSMutableDictionary dictionary];
            if ([request isKindOfClass:NSDictionary.class] && [request[@"operation"] isEqual:@"read-data"]) {
                NSURL *container = [NSURL fileURLWithPath:request[@"container"]];
                SEL selector = NSSelectorFromString(@"_initWithSuiteName:container:");
                if (![NSUserDefaults instancesRespondToSelector:selector]) {
                    result[@"ok"] = @NO;
                } else {
                    NSUserDefaults *defaults = ((id (*)(id, SEL, id, id))objc_msgSend)([NSUserDefaults alloc], selector, request[@"domain"], container);
                    result[@"ok"] = @([defaults synchronize]);
                    id value = [defaults objectForKey:request[@"key"]];
                    if ([value isKindOfClass:NSData.class]) result[@"data"] = [value base64EncodedStringWithOptions:0];
                    else if (value) result[@"ok"] = @NO;
                }
            } else if ([request isKindOfClass:NSDictionary.class]) {
                [result addEntriesFromDictionary:JevSimulatorAction(request)];
            } else if ([request isKindOfClass:NSArray.class]) for (id domain in request) {
                if (![domain isKindOfClass:NSString.class]) continue;
                CFStringRef app = [domain isEqualToString:@"NSGlobalDomain"]
                    ? kCFPreferencesAnyApplication : (__bridge CFStringRef)domain;
                // A failed synchronization is unknown, never an empty domain.
                if (!CFPreferencesSynchronize(app, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)) continue;
                NSDictionary *values = CFBridgingRelease(CFPreferencesCopyMultiple(
                    NULL, app, kCFPreferencesCurrentUser, kCFPreferencesAnyHost));
                NSMutableDictionary *scalars = [NSMutableDictionary dictionary];
                for (NSString *key in values) {
                    id value = values[key];
                    if ([value isKindOfClass:NSString.class] || [value isKindOfClass:NSNumber.class]) {
                        NSString *text = [value description];
                        if (text.length < 60) scalars[key] = text;
                    }
                }
                result[domain] = scalars;
            }
            NSData *response = [NSJSONSerialization dataWithJSONObject:result options:0 error:&error];
            if (!response) break;
            fwrite(response.bytes, 1, response.length, stdout);
            fputc('\n', stdout);
            fflush(stdout);
        }
    }
    free(line);
}

int main(void) {
    // The AX runtime needs the main run loop while making cross-process calls.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        serve();
        CFRunLoopStop(CFRunLoopGetMain());
    });
    CFRunLoopRun();
    return 0;
}
