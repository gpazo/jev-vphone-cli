#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <dlfcn.h>

// Read-only feasibility probe, deliberately outside the controller. Retain a
// native target and its ancestry; compare live semantics and display-wide hit
// identity without taking another whole-screen snapshot. No actions are sent.
static id framework;
static void *(*create)(void);
static int32_t (*hitTest)(void *, float, float, void **);
static NSArray *retained;
static NSArray *batch;
static NSMapTable *captureCache;

static void *raw(id element) {
    return ((void *(*)(id, SEL))objc_msgSend)(element, NSSelectorFromString(@"AXUIElement"));
}
static id wrap(void *element) {
    return ((id (*)(id, SEL, void *))objc_msgSend)(NSClassFromString(@"XCAccessibilityElement"),
        NSSelectorFromString(@"elementWithAXUIElement:"), element);
}
static NSArray *chain(id element) {
    NSMutableArray *result = [NSMutableArray array];
    for (NSUInteger depth = 0; element && depth < 32; depth++) {
        NSArray *cached = [captureCache objectForKey:(__bridge id)raw(element)];
        if (cached) { [result addObjectsFromArray:cached]; return result; }
        NSError *error = nil;
        NSDictionary *attrs = ((id (*)(id, SEL, id, id, NSError **))objc_msgSend)(framework,
            NSSelectorFromString(@"attributesForElement:attributes:error:"), element,
            @[@"XC_kAXXCAttributeParent", @"XC_kAXXCAttributeLabel", @"XC_kAXXCAttributeValue",
              @"XC_kAXXCAttributeAutomationType", @"XC_kAXXCAttributeIdentifier",
              @"XC_kAXXCAttributePlaceholderValue", @"XC_kAXXCAttributeElementType",
              @"XC_kAXXCAttributeFrame"], &error);
        if (!attrs || error) return nil;
        NSMutableDictionary *semantics = [attrs mutableCopy];
        [semantics removeObjectForKey:@"XC_kAXXCAttributeParent"];
        [semantics removeObjectForKey:@"XC_kAXXCAttributeFrame"];
        [result addObject:@{@"element":element, @"semantics":semantics,
                           @"frame":attrs[@"XC_kAXXCAttributeFrame"] ?: NSNull.null}];
        if ([attrs[@"XC_kAXXCAttributeAutomationType"] integerValue] == 1) {
            for (NSUInteger i = 0; i < result.count; i++)
                [captureCache setObject:[result subarrayWithRange:NSMakeRange(i, result.count-i)]
                                 forKey:(__bridge id)raw(result[i][@"element"])];
            return result;
        }
        element = attrs[@"XC_kAXXCAttributeParent"];
        if (![element respondsToSelector:NSSelectorFromString(@"AXUIElement")]) return nil;
    }
    return nil;
}
static id hit(double x, double y) {
    void *root = create(), *target = NULL;
    if (!root) return nil;
    int32_t status = hitTest(root, x, y, &target);
    CFRelease(root);
    if (status || !target) { if (target) CFRelease(target); return nil; }
    id element = wrap(target); CFRelease(target); return element;
}
static NSDictionary *run(NSDictionary *request) {
    if ([request[@"op"] isEqual:@"capture-many"]) {
        NSArray *points = request[@"points"];
        if (![points isKindOfClass:NSArray.class] || points.count > 250) return @{@"ok":@NO};
        captureCache = [NSMapTable strongToStrongObjectsMapTable];
        NSMutableArray *entries = [NSMutableArray array], *depths = [NSMutableArray array];
        for (NSDictionary *point in points) {
            NSArray *value = chain(hit([point[@"x"] doubleValue], [point[@"y"] doubleValue]));
            [entries addObject:value ?: @[]]; [depths addObject:@(value.count)];
        }
        batch = entries; captureCache = nil;
        return @{@"ok":@YES, @"depths":depths};
    }
    if ([request[@"op"] isEqual:@"capture"]) {
        retained = chain(hit([request[@"x"] doubleValue], [request[@"y"] doubleValue]));
        NSMutableArray *semantics = [NSMutableArray array];
        for (NSDictionary *entry in retained) [semantics addObject:entry[@"semantics"]];
        return @{@"ok":@(retained != nil), @"chain":semantics};
    }
    if ([request[@"op"] isEqual:@"validate"] && request[@"index"]) {
        NSUInteger i = [request[@"index"] unsignedIntegerValue];
        retained = i < batch.count ? batch[i] : nil;
    }
    if ([request[@"op"] isEqual:@"validate"] && retained.count) {
        NSArray *fresh = chain(retained[0][@"element"]);
        if (fresh.count != retained.count) return @{@"ok":@NO, @"reason":@"ancestry unavailable or changed"};
        for (NSUInteger i = 0; i < retained.count; i++) {
            if (!CFEqual(raw(retained[i][@"element"]), raw(fresh[i][@"element"]))
                || ![retained[i][@"semantics"] isEqual:fresh[i][@"semantics"]])
                return @{@"ok":@NO, @"reason":@"identity or semantics changed"};
        }
        NSDictionary *frame = fresh[0][@"frame"];
        if (![frame isKindOfClass:NSDictionary.class]) return @{@"ok":@NO, @"reason":@"no frame"};
        id current = hit([frame[@"X"] doubleValue] + [frame[@"Width"] doubleValue]/2,
                         [frame[@"Y"] doubleValue] + [frame[@"Height"] doubleValue]/2);
        BOOL same = current && CFEqual(raw(current), raw(retained[0][@"element"]));
        return @{@"ok":@(same), @"reason":same ? @"same reachable native target" : @"covered or replaced"};
    }
    return @{@"ok":@NO, @"reason":@"unknown operation or missing capture"};
}
int main(void) {
    dlopen("/System/Library/PrivateFrameworks/AXRuntime.framework/AXRuntime", RTLD_NOW);
    dlopen("/Developer/Library/PrivateFrameworks/XCTAutomationSupport.framework/XCTAutomationSupport", RTLD_NOW);
    create = dlsym(RTLD_DEFAULT, "AXUIElementCreateSystemWide");
    hitTest = dlsym(RTLD_DEFAULT, "AXUIElementCopyElementAtPosition");
    framework = ((id (*)(id, SEL))objc_msgSend)([NSClassFromString(@"XCTAccessibilityFramework") alloc],
        NSSelectorFromString(@"initForRemoteAccess"));
    if (!create || !hitTest || !framework) return 1;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        char *line = NULL; size_t size = 0;
        while (getline(&line, &size, stdin) > 0) { @autoreleasepool {
            NSDictionary *result;
            @try {
                NSData *data = [[NSString stringWithUTF8String:line] dataUsingEncoding:NSUTF8StringEncoding];
                result = run([NSJSONSerialization JSONObjectWithData:data options:0 error:nil]);
            } @catch (NSException *e) { result = @{@"ok":@NO, @"reason":e.reason ?: @"exception"}; }
            NSData *data = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
            fwrite(data.bytes, 1, data.length, stdout); fputc('\n', stdout); fflush(stdout);
        }}
        free(line); CFRunLoopStop(CFRunLoopGetMain());
    });
    CFRunLoopRun(); return 0;
}
