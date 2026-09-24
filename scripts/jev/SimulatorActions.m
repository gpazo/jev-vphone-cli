#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <math.h>

NSDictionary *JevSimulatorTargets(NSDictionary *, id, void *(*)(void), int32_t (*)(void *, float, float, void **));
BOOL JevConsumeTarget(NSString *, void *);

// Runtime names are resolved on the guest, rather than assuming private enum
// numbers. This is ordinary accessibility input; it does not write app data.
NSDictionary *JevSimulatorAction(NSDictionary *request) {
    static void *(*create)(void);
    static int32_t (*hitTest)(void *, float, float, void **);
    static NSString *(*actionName)(NSUInteger);
    static NSString *(*attributeName)(NSUInteger);
    static NSArray *(*attributeNumbers)(NSArray *);
    static int32_t (*setAttribute)(void *, uint32_t, const void *);
    static NSString *customIdentifierKey;
    static NSString *customNameKey;
    static id framework;
    static id workspace;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/PrivateFrameworks/AXRuntime.framework/AXRuntime", RTLD_NOW);
        dlopen("/System/Library/PrivateFrameworks/AccessibilityPlatformTranslation.framework/AccessibilityPlatformTranslation", RTLD_NOW);
        dlopen("/Developer/Library/PrivateFrameworks/XCTAutomationSupport.framework/XCTAutomationSupport", RTLD_NOW);
        dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_NOW);
        create = dlsym(RTLD_DEFAULT, "AXUIElementCreateSystemWide");
        hitTest = dlsym(RTLD_DEFAULT, "AXUIElementCopyElementAtPosition");
        actionName = dlsym(RTLD_DEFAULT, "_AXPActionToString");
        attributeName = dlsym(RTLD_DEFAULT, "_AXPAttributeToString");
        attributeNumbers = dlsym(RTLD_DEFAULT, "XCAXAccessibilityAttributesForStringAttributes");
        setAttribute = dlsym(RTLD_DEFAULT, "AXUIElementSetAttributeValue");
        NSString * __unsafe_unretained *identifier = (NSString * __unsafe_unretained *)dlsym(RTLD_DEFAULT, "AXPCustomActionIdentifier");
        NSString * __unsafe_unretained *name = (NSString * __unsafe_unretained *)dlsym(RTLD_DEFAULT, "AXPCustomActionName");
        customIdentifierKey = identifier ? *identifier : nil;
        customNameKey = name ? *name : nil;
        framework = ((id (*)(id, SEL))objc_msgSend)([NSClassFromString(@"XCTAccessibilityFramework") alloc], NSSelectorFromString(@"initForRemoteAccess"));
        workspace = ((id (*)(id, SEL))objc_msgSend)(NSClassFromString(@"LSApplicationWorkspace"), NSSelectorFromString(@"defaultWorkspace"));
    });
    NSDictionary *(^failure)(NSString *) = ^(NSString *message) {
        return @{@"ok": @NO, @"error": message};
    };
    if (!create || !hitTest || !actionName || !framework) return failure(@"Accessibility actions unavailable");
    if ([request[@"action"] isEqual:@"prepare"]) return @{@"ok": @YES};
    if ([request[@"action"] isEqual:@"launch"]) {
        NSString *bundle = request[@"bundleId"];
        SEL selector = NSSelectorFromString(@"openApplicationWithBundleID:");
        if (![bundle isKindOfClass:NSString.class] || !bundle.length || ![workspace respondsToSelector:selector]) return failure(@"Application launch unavailable");
        BOOL opened = ((BOOL (*)(id, SEL, id))objc_msgSend)(workspace, selector, bundle);
        return opened ? @{@"ok": @YES} : failure(@"Application launch rejected");
    }
    if ([@[@"capture-targets", @"validate-target"] containsObject:request[@"action"]])
        return JevSimulatorTargets(request, framework, create, hitTest);
    NSDictionary *names = @{@"press": @"AXPActionPress", @"increment": @"AXPActionIncrement", @"decrement": @"AXPActionDecrement",
        @"scroll-down": @"AXPActionScrollDownByPage", @"scroll-up": @"AXPActionScrollUpByPage"};
    BOOL readCustom = [request[@"action"] isEqual:@"custom-actions"];
    BOOL performCustom = [request[@"action"] isEqual:@"custom"];
    BOOL replaceText = [request[@"action"] isEqual:@"replace-text"];
    NSString *name = readCustom || performCustom ? @"AXPActionPerformCustomAction" : names[request[@"action"]];
    if ((!name && !replaceText) || ![request[@"x"] isKindOfClass:NSNumber.class] || ![request[@"y"] isKindOfClass:NSNumber.class]) return failure(@"Invalid action");
    double x = [request[@"x"] doubleValue], y = [request[@"y"] doubleValue];
    if (!isfinite(x) || !isfinite(y) || x < 0 || y < 0) return failure(@"Invalid point");
    NSUInteger action = 0;
    for (NSUInteger n = 1; n < 100; n++) {
        if ([actionName(n) isEqualToString:name]) { action = n; break; }
    }
    if (!action && !replaceText) return failure(@"Requested action unavailable");
    void *root = create(), *hit = NULL;
    if (!root) return failure(@"No accessibility root");
    int32_t status = hitTest(root, x, y, &hit);
    CFRelease(root);
    if (status || !hit) { if (hit) CFRelease(hit); return failure(@"Target unavailable"); }
    @try {
        if (request[@"expectedToken"] && !JevConsumeTarget(request[@"expectedToken"], hit))
            return failure(@"Target changed since observation");
        id element = ((id (*)(id, SEL, void *))objc_msgSend)(NSClassFromString(@"XCAccessibilityElement"), NSSelectorFromString(@"elementWithAXUIElement:"), hit);
        NSError *error = nil;
        NSDictionary *attrs = ((id (*)(id, SEL, id, id, NSError **))objc_msgSend)(framework,
            NSSelectorFromString(@"attributesForElement:attributes:error:"), element,
            @[@"XC_kAXXCAttributeLabel", @"XC_kAXXCAttributeValue", @"XC_kAXXCAttributeAutomationType", @"XC_kAXXCAttributePlaceholderValue"], &error);
        if (!attrs || error) return failure(@"Cannot check target freshness");
        for (NSString *field in @[@"Label", @"Value", @"AutomationType", @"PlaceholderValue"]) {
            id expected = request[[@"expected" stringByAppendingString:field]];
            if (expected && ![expected isEqual:attrs[[@"XC_kAXXCAttribute" stringByAppendingString:field]]]) return failure(@"Target changed since observation");
        }
        if (replaceText) {
            NSString *text = request[@"text"];
            if (![@[@45, @49, @50, @52] containsObject:attrs[@"XC_kAXXCAttributeAutomationType"]]
                || ![text isKindOfClass:NSString.class] || !attributeNumbers || !setAttribute) return failure(@"Editable target unavailable");
            NSArray *numbers = attributeNumbers(@[@"XC_kAXXCAttributeValue"]);
            if (numbers.count != 1 || ![numbers[0] isKindOfClass:NSNumber.class]) return failure(@"Text replacement unavailable");
            // Resolve once, assert before writing, then verify the very same
            // native element. A keyboard reflow cannot redirect the readback.
            // The value is read, never copied from the request into the reply.
            if (setAttribute(hit, [numbers[0] unsignedIntValue], (__bridge const void *)text))
                return failure(@"Text replacement not acknowledged; inspect before retrying");
            NSDictionary *after = ((id (*)(id, SEL, id, id, NSError **))objc_msgSend)(framework,
                NSSelectorFromString(@"attributesForElement:attributes:error:"), element,
                @[@"XC_kAXXCAttributeValue"], &error);
            if (error || ![after[@"XC_kAXXCAttributeValue"] isEqual:text])
                return failure(@"Text replacement was not observed; inspect before retrying");
            return @{@"ok": @YES, @"value": after[@"XC_kAXXCAttributeValue"]};
        }
        BOOL adjusts = [request[@"action"] isEqualToString:@"increment"] || [request[@"action"] isEqualToString:@"decrement"];
        if (adjusts && [attrs[@"XC_kAXXCAttributeAutomationType"] intValue] != 39) return failure(@"Adjustment requires a picker wheel");
        id translator = ((id (*)(id, SEL))objc_msgSend)(NSClassFromString(@"AXPTranslator"), NSSelectorFromString(@"sharediOSInstance"));
        id translation = ((id (*)(id, SEL, void *))objc_msgSend)(translator, NSSelectorFromString(@"translationObjectFromPlatformElement:"), hit);
        if (!translation) return failure(@"Cannot resolve target");
        id command = ((id (*)(id, SEL, id))objc_msgSend)(NSClassFromString(@"AXPTranslatorRequest"), NSSelectorFromString(@"requestWithTranslation:"), translation);
        if (readCustom || performCustom) {
            if (!attributeName || !customIdentifierKey || !customNameKey) return failure(@"Custom accessibility actions unavailable");
            NSUInteger attribute = 0;
            for (NSUInteger n = 1; n < 180; n++) {
                if ([attributeName(n) isEqual:@"AXPAttributeCustomActions"]) { attribute = n; break; }
            }
            if (!attribute) return failure(@"Custom accessibility actions unavailable");
            [command setValue:@(attribute) forKey:@"attributeType"];
            id answer = ((id (*)(id, SEL, id))objc_msgSend)(translator, NSSelectorFromString(@"processAttributeRequest:"), command);
            id raw = [answer valueForKey:@"resultData"];
            if (raw && ![raw isKindOfClass:NSArray.class]) return failure(@"Invalid custom accessibility actions");
            NSMutableArray *available = [NSMutableArray array];
            NSMutableArray *matching = [NSMutableArray array];
            for (id item in raw) {
                if (![item isKindOfClass:NSDictionary.class]) continue;
                NSString *label = item[customNameKey];
                if (![label isKindOfClass:NSString.class] || !label.length || !item[customIdentifierKey]) continue;
                [available addObject:label];
                if ([label isEqual:request[@"name"]]) [matching addObject:item];
            }
            if (readCustom) return @{@"ok": @YES, @"actions": available};
            if (matching.count != 1) return failure(@"Custom action disappeared or is ambiguous");
            // Re-resolve the identifier from the live element; never replay an
            // opaque identifier from an earlier screen or execute by ordinal.
            [command setValue:@{customIdentifierKey: matching[0][customIdentifierKey]} forKey:@"parameters"];
        }
        [command setValue:@(action) forKey:@"actionType"];
        id response = ((id (*)(id, SEL, id))objc_msgSend)(translator, NSSelectorFromString(@"processActionRequest:"), command);
        if (![[response valueForKey:@"resultData"] boolValue]) return failure(@"Action not acknowledged; do not retry without re-observing");
        return @{@"ok": @YES};
    } @catch (NSException *exception) {
        return failure(@"Accessibility action failed; do not retry without re-observing");
    } @finally { CFRelease(hit); }
}
