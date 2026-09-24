#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <dlfcn.h>

// Experimental, observation-scoped native references. No mutation is performed
// here. The ordinary input helper consumes a reference only after another live
// ancestry and display-wide hit check. A new capture invalidates every old token.
static id framework;
static void *(*create)(void);
static int32_t (*hitTest)(void *, float, float, void **);
static NSString *generation;
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
        if ([attrs[@"XC_kAXXCAttributeAutomationType"] intValue] == 75 && ![attrs[@"XC_kAXXCAttributeLabel"] length]) {
            NSDictionary *children = ((id (*)(id, SEL, id, id, NSError **))objc_msgSend)(framework,
                NSSelectorFromString(@"attributesForElement:attributes:error:"), element, @[@"XC_kAXXCAttributeChildren"], &error);
            NSArray *items = children[@"XC_kAXXCAttributeChildren"];
            if (error || ![items isKindOfClass:NSArray.class] || items.count > 32) return nil;
            NSMutableArray *labels = [NSMutableArray array];
            for (id child in items) {
                NSDictionary *a = ((id (*)(id, SEL, id, id, NSError **))objc_msgSend)(framework,
                    NSSelectorFromString(@"attributesForElement:attributes:error:"), child,
                    @[@"XC_kAXXCAttributeLabel", @"XC_kAXXCAttributeAutomationType"], &error);
                if (!a || error) return nil;
                if ([a[@"XC_kAXXCAttributeAutomationType"] intValue] == 48 && [a[@"XC_kAXXCAttributeLabel"] length] && labels.count < 3)
                    [labels addObject:a[@"XC_kAXXCAttributeLabel"]];
            }
            semantics[@"cellContext"] = [labels componentsJoinedByString:@" / "];
        }
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

static NSString *context(NSArray *entries) {
    NSMutableArray *labels = [NSMutableArray array];
    for (NSInteger i = entries.count-2; i > 0; i--) {
        NSDictionary *a = entries[i][@"semantics"];
        NSString *label = a[@"cellContext"] ?: a[@"XC_kAXXCAttributeLabel"];
        if ([a[@"XC_kAXXCAttributeAutomationType"] intValue] == 19) label = @"Keyboard";
        if (label.length && ![labels.lastObject isEqual:label]) {
            [labels addObject:[label substringToIndex:MIN(label.length, 160)]];
            if (labels.count > 2) [labels removeObjectAtIndex:0];
        }
    }
    if ([entries[0][@"semantics"][@"XC_kAXXCAttributeElementType"] isEqual:@"UIAccessibilityBackButtonElement"])
        [labels addObject:@"Back navigation"];
    return [labels componentsJoinedByString:@" > "];
}
static NSArray *resolve(NSString *token) {
    if (![token isKindOfClass:NSString.class]) return nil;
    NSArray *parts = [token componentsSeparatedByString:@":"];
    if (parts.count != 2 || ![parts[0] isEqual:generation]) return nil;
    NSUInteger i = [parts[1] integerValue];
    if (![[NSString stringWithFormat:@"%lu", (unsigned long)i] isEqual:parts[1]]) return nil;
    return i < batch.count ? batch[i] : nil;
}
static NSArray *validate(NSArray *old) {
    if (!old.count) return nil;
    NSArray *fresh = chain(old[0][@"element"]);
    if (fresh.count != old.count) return nil;
    for (NSUInteger i = 0; i < old.count; i++) {
        if (!CFEqual(raw(old[i][@"element"]), raw(fresh[i][@"element"]))
            || ![old[i][@"semantics"] isEqual:fresh[i][@"semantics"]]) return nil;
    }
    NSDictionary *f = fresh[0][@"frame"];
    if (![f isKindOfClass:NSDictionary.class] || [f[@"Width"] doubleValue] <= 0 || [f[@"Height"] doubleValue] <= 0) return nil;
    id current = hit([f[@"X"] doubleValue] + [f[@"Width"] doubleValue]/2,
                     [f[@"Y"] doubleValue] + [f[@"Height"] doubleValue]/2);
    return current && CFEqual(raw(current), raw(old[0][@"element"])) ? fresh : nil;
}
// Called immediately before ordinary input, after its fresh display-wide hit.
BOOL JevConsumeTarget(NSString *token, void *target) {
    NSArray *old = resolve(token);
    NSArray *fresh = validate(old);
    BOOL same = fresh && CFEqual(raw(fresh[0][@"element"]), target);
    // A mutation decision cannot use a native reference twice, even on failure.
    batch = nil; generation = nil;
    return same;
}
NSDictionary *JevSimulatorTargets(NSDictionary *request, id reader,
    void *(*makeRoot)(void), int32_t (*findHit)(void *, float, float, void **)) {
    framework = reader; create = makeRoot; hitTest = findHit;
    @try {
        if ([request[@"action"] isEqual:@"capture-targets"]) {
            batch = nil; generation = nil;
            NSArray *points = request[@"points"];
            if (![points isKindOfClass:NSArray.class] || points.count > 250) return @{@"ok":@NO};
            generation = NSUUID.UUID.UUIDString;
            captureCache = [NSMapTable strongToStrongObjectsMapTable];
            NSMutableArray *entries = [NSMutableArray array], *results = [NSMutableArray array];
            for (NSDictionary *point in points) {
                NSArray *value = chain(hit([point[@"x"] doubleValue], [point[@"y"] doubleValue]));
                NSMutableDictionary *reply = [NSMutableDictionary dictionary];
                if (value.count) {
                    NSMutableDictionary *attrs = [value[0][@"semantics"] mutableCopy];
                    [attrs removeObjectForKey:@"cellContext"];
                    reply[@"tree"] = attrs;
                    BOOL local = YES;
                    for (NSDictionary *entry in value) {
                        NSString *type = entry[@"semantics"][@"XC_kAXXCAttributeElementType"];
                        if ([type isEqual:@"AXRemoteElement"] || [type isEqual:@"WebAccessibilityObjectWrapper"]) local = NO;
                    }
                    if (local) {
                        reply[@"token"] = [NSString stringWithFormat:@"%@:%lu", generation, (unsigned long)entries.count];
                        reply[@"context"] = context(value);
                        reply[@"app"] = value.lastObject[@"semantics"][@"XC_kAXXCAttributeLabel"] ?: @"";
                    }
                }
                [entries addObject:value ?: @[]]; [results addObject:reply];
            }
            batch = entries; captureCache = nil;
            return @{@"ok":@YES, @"targets":results};
        }
        if ([request[@"action"] isEqual:@"validate-target"]) {
            NSArray *fresh = validate(resolve(request[@"token"]));
            return fresh ? @{@"ok":@YES, @"frame":fresh[0][@"frame"]}
                         : @{@"ok":@NO, @"error":@"Native target changed or is unavailable"};
        }
    } @catch (NSException *exception) {
        batch = nil; generation = nil; captureCache = nil;
    }
    return @{@"ok":@NO, @"error":@"Native target references unavailable"};
}
