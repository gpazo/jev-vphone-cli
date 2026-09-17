/*
 * vphoned_accessibility — Accessibility tree query.
 *
 * Turns the phone's screen into text so a model can reason about it. This
 * is the semantic path: roles, labels, values and frames, including
 * icon-only controls and toggle states that OCR of the framebuffer cannot
 * recover.
 *
 * Approach. vphoned is already a root LaunchDaemon signed as a
 * platform-application, carrying (among others)
 * com.apple.private.security.storage.universalaccess and
 * com.apple.springboard.debugapplications — so the first thing worth trying
 * is an in-process query, not injection into SpringBoard. That follows the
 * pattern established in vphoned_apps.m: dlopen the private framework,
 * resolve by name, and degrade gracefully when something is absent.
 *
 * Because the exact surface available on this firmware is not documented,
 * the `probe` action performs recon and reports what actually resolved.
 * Run it before trusting `tree`, and record the findings in
 * research/jev_accessibility_spike.md.
 */

#import "vphoned_accessibility.h"
#import "vphoned_protocol.h"
#include <dlfcn.h>
#include <objc/message.h>
#import <CoreGraphics/CoreGraphics.h>

// MARK: - Candidate Surfaces

/// Libraries that may carry the accessibility runtime. Probed in order;
/// the first that provides a working element API wins.
static const char *kCandidateLibraries[] = {
    "/usr/lib/libAccessibility.dylib",
    "/System/Library/PrivateFrameworks/AccessibilityUtilities.framework/AccessibilityUtilities",
    "/System/Library/PrivateFrameworks/AXRuntime.framework/AXRuntime",
    "/System/Library/PrivateFrameworks/AccessibilitySharedSupport.framework/AccessibilitySharedSupport",
};
static const size_t kCandidateLibraryCount =
    sizeof(kCandidateLibraries) / sizeof(kCandidateLibraries[0]);

/// Symbols that gate the accessibility server. Nothing returns elements
/// until the server is running, so these are checked first.
static const char *kServerSymbols[] = {
    "_AXSApplicationAccessibilityEnabled",
    "_AXSSetApplicationAccessibilityEnabled",
    "_AXSAutomationEnabled",
    "_AXSSetAutomationEnabled",
};
static const size_t kServerSymbolCount = sizeof(kServerSymbols) / sizeof(kServerSymbols[0]);

/// The cross-process element API, if this firmware exposes it.
static const char *kElementSymbols[] = {
    "AXUIElementCreateApplication",
    "AXUIElementCopyAttributeValue",
    "AXUIElementCopyMultipleAttributeValues",
    "AXUIElementGetPid",
    "AXUIElementCopyElementAtPosition",
};
static const size_t kElementSymbolCount = sizeof(kElementSymbols) / sizeof(kElementSymbols[0]);

/// Objective-C classes worth knowing about, whichever library provides them.
static NSArray<NSString *> *vp_candidate_classes(void) {
  return @[
    @"AXElement", @"AXUIElement", @"AXBackBoardServer", @"AXRuntimeServer",
    @"AXSpringBoardServer", @"AXAccessibilityServer"
  ];
}

// MARK: - Resolved State

static BOOL gLoaded = NO;
static void *gHandles[sizeof(kCandidateLibraries) / sizeof(kCandidateLibraries[0])] = {0};

typedef void *AXElementRef;
typedef AXElementRef (*AXCreateApplication_fn)(pid_t);
typedef int32_t (*AXCopyAttributeValue_fn)(AXElementRef, CFStringRef, CFTypeRef *);
typedef BOOL (*AXBoolGetter_fn)(void);
typedef void (*AXBoolSetter_fn)(BOOL);

static AXCreateApplication_fn gCreateApplication = NULL;
static AXCopyAttributeValue_fn gCopyAttributeValue = NULL;
static AXBoolGetter_fn gAXEnabled = NULL;
static AXBoolSetter_fn gSetAXEnabled = NULL;

/// dlopen every candidate and resolve whatever is present. Safe to call
/// repeatedly; does its work once.
BOOL vp_accessibility_load(void) {
  if (gLoaded) {
    return gCreateApplication != NULL;
  }
  gLoaded = YES;

  for (size_t i = 0; i < kCandidateLibraryCount; i++) {
    gHandles[i] = dlopen(kCandidateLibraries[i], RTLD_LAZY);
    if (!gHandles[i]) {
      continue;
    }

    if (!gCreateApplication) {
      gCreateApplication =
          (AXCreateApplication_fn)dlsym(gHandles[i], "AXUIElementCreateApplication");
    }
    if (!gCopyAttributeValue) {
      gCopyAttributeValue =
          (AXCopyAttributeValue_fn)dlsym(gHandles[i], "AXUIElementCopyAttributeValue");
    }
    if (!gAXEnabled) {
      gAXEnabled = (AXBoolGetter_fn)dlsym(gHandles[i], "_AXSApplicationAccessibilityEnabled");
    }
    if (!gSetAXEnabled) {
      gSetAXEnabled =
          (AXBoolSetter_fn)dlsym(gHandles[i], "_AXSSetApplicationAccessibilityEnabled");
    }
  }

  NSLog(@"vphoned: accessibility loaded (create=%s copy=%s enabled=%s)",
        gCreateApplication ? "yes" : "no", gCopyAttributeValue ? "yes" : "no",
        gAXEnabled ? "yes" : "no");

  return gCreateApplication != NULL;
}

// MARK: - Probe

/// Recon. Reports exactly what this firmware exposes, so the tree walk can
/// be built against what is actually there rather than what is assumed.
static NSDictionary *vp_accessibility_probe(id reqId) {
  vp_accessibility_load();

  NSMutableDictionary *libraries = [NSMutableDictionary dictionary];
  for (size_t i = 0; i < kCandidateLibraryCount; i++) {
    NSString *path = @(kCandidateLibraries[i]);
    NSMutableDictionary *entry = [NSMutableDictionary dictionary];
    entry[@"exists"] = @([[NSFileManager defaultManager] fileExistsAtPath:path]);
    entry[@"loaded"] = @(gHandles[i] != NULL);

    if (gHandles[i]) {
      NSMutableArray *server = [NSMutableArray array];
      for (size_t s = 0; s < kServerSymbolCount; s++) {
        if (dlsym(gHandles[i], kServerSymbols[s])) {
          [server addObject:@(kServerSymbols[s])];
        }
      }
      NSMutableArray *element = [NSMutableArray array];
      for (size_t s = 0; s < kElementSymbolCount; s++) {
        if (dlsym(gHandles[i], kElementSymbols[s])) {
          [element addObject:@(kElementSymbols[s])];
        }
      }
      if (server.count) entry[@"server_symbols"] = server;
      if (element.count) entry[@"element_symbols"] = element;
    }

    libraries[path] = entry;
  }

  NSMutableArray *classes = [NSMutableArray array];
  for (NSString *name in vp_candidate_classes()) {
    if (NSClassFromString(name)) {
      [classes addObject:name];
    }
  }

  NSMutableDictionary *r = vp_make_response(@"ok", reqId);
  r[@"libraries"] = libraries;
  r[@"classes"] = classes;
  r[@"accessibility_enabled"] = gAXEnabled ? @(gAXEnabled()) : [NSNull null];
  r[@"can_create_element"] = @(gCreateApplication != NULL);
  r[@"can_read_attribute"] = @(gCopyAttributeValue != NULL);
  return r;
}

// MARK: - Server Enable

/// Nothing returns elements while the accessibility server is off, and it
/// is off by default. vphoned holds user-preference-write, so it can turn
/// the server on itself rather than requiring a trip through Settings.
static NSDictionary *vp_accessibility_enable(id reqId) {
  vp_accessibility_load();

  if (!gSetAXEnabled) {
    NSMutableDictionary *r = vp_make_response(@"err", reqId);
    r[@"msg"] = @"_AXSSetApplicationAccessibilityEnabled not available — run `probe` first";
    return r;
  }

  gSetAXEnabled(YES);

  NSMutableDictionary *r = vp_make_response(@"ok", reqId);
  r[@"enabled"] = gAXEnabled ? @(gAXEnabled()) : @YES;
  return r;
}

// MARK: - Tree Walk

/// Attribute names to try for each field. iOS and macOS disagree on some of
/// these, and the set varies by firmware, so each field tries several and
/// takes the first that answers.
static NSArray<NSString *> *vp_attribute_candidates(NSString *field) {
  static NSDictionary *table = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    table = @{
      @"label" : @[ @"AXLabel", @"AXTitle", @"AXDescription", @"AXName" ],
      @"value" : @[ @"AXValue", @"AXValueDescription" ],
      @"role" : @[ @"AXRole", @"AXTraits", @"AXSubrole" ],
      @"frame" : @[ @"AXFrame", @"AXPosition", @"AXSize" ],
      @"children" : @[ @"AXChildren", @"AXVisibleChildren" ],
    };
  });
  return table[field] ?: @[];
}

static id vp_copy_attribute(AXElementRef element, NSString *name) {
  if (!gCopyAttributeValue || !element) {
    return nil;
  }
  CFTypeRef out = NULL;
  int32_t err = gCopyAttributeValue(element, (__bridge CFStringRef)name, &out);
  if (err != 0 || out == NULL) {
    return nil;
  }
  return (__bridge_transfer id)out;
}

static id vp_first_attribute(AXElementRef element, NSString *field) {
  for (NSString *name in vp_attribute_candidates(field)) {
    id value = vp_copy_attribute(element, name);
    if (value) {
      return value;
    }
  }
  return nil;
}

/// Depth-first serialization of one element and its children.
static NSDictionary *vp_serialize_element(AXElementRef element, NSInteger depth,
                                          NSInteger maxDepth) {
  if (!element || (maxDepth >= 0 && depth > maxDepth)) {
    return nil;
  }

  NSMutableDictionary *node = [NSMutableDictionary dictionary];

  id label = vp_first_attribute(element, @"label");
  if ([label isKindOfClass:[NSString class]] && [label length]) {
    node[@"label"] = label;
  }

  id value = vp_first_attribute(element, @"value");
  if (value && ![value isKindOfClass:[NSNull class]]) {
    node[@"value"] = [value isKindOfClass:[NSString class]] ? value : [value description];
  }

  id role = vp_first_attribute(element, @"role");
  if (role) {
    node[@"role"] = [role isKindOfClass:[NSString class]] ? role : [role description];
  }

  // `CGRectValue` lives in a UIKit category on NSValue; vphoned links
  // Foundation only, so unbox by size instead. The attribute may also come
  // back already decomposed into four numbers.
  id frame = vp_first_attribute(element, @"frame");
  if ([frame isKindOfClass:[NSValue class]]) {
    // Literal rather than CGRectZero: that constant would pull in the
    // CoreGraphics framework, which this daemon does not link.
    CGRect rect = {{0, 0}, {0, 0}};
    [(NSValue *)frame getValue:&rect size:sizeof(rect)];
    node[@"frame"] = @[ @(rect.origin.x), @(rect.origin.y), @(rect.size.width), @(rect.size.height) ];
  } else if ([frame isKindOfClass:[NSArray class]] && [(NSArray *)frame count] == 4) {
    node[@"frame"] = frame;
  }

  id children = vp_first_attribute(element, @"children");
  if ([children isKindOfClass:[NSArray class]]) {
    NSMutableArray *serialized = [NSMutableArray array];
    for (id child in (NSArray *)children) {
      NSDictionary *sub =
          vp_serialize_element((__bridge AXElementRef)child, depth + 1, maxDepth);
      if (sub) {
        [serialized addObject:sub];
      }
    }
    if (serialized.count) {
      node[@"children"] = serialized;
    }
  }

  return node.count ? node : nil;
}

// MARK: - Command

NSDictionary *vp_handle_accessibility_command(NSDictionary *msg) {
  id reqId = msg[@"id"];
  NSString *action = msg[@"action"] ?: @"tree";

  if ([action isEqualToString:@"probe"]) {
    return vp_accessibility_probe(reqId);
  }
  if ([action isEqualToString:@"enable"]) {
    return vp_accessibility_enable(reqId);
  }

  if (!vp_accessibility_load()) {
    NSMutableDictionary *r = vp_make_response(@"err", reqId);
    r[@"msg"] = @"accessibility element API not available on this firmware — "
                @"run {\"t\":\"accessibility_tree\",\"action\":\"probe\"} to see what is";
    return r;
  }

  // The caller may target a specific process; otherwise the frontmost app
  // is the one worth describing.
  pid_t pid = (pid_t)[msg[@"pid"] intValue];
  if (pid <= 0) {
    NSMutableDictionary *r = vp_make_response(@"err", reqId);
    r[@"msg"] = @"accessibility_tree requires a pid (use the apps command to find the frontmost)";
    return r;
  }

  AXElementRef app = gCreateApplication(pid);
  if (!app) {
    NSMutableDictionary *r = vp_make_response(@"err", reqId);
    r[@"msg"] = [NSString stringWithFormat:@"could not create accessibility element for pid %d", pid];
    return r;
  }

  NSInteger maxDepth = msg[@"depth"] ? [msg[@"depth"] integerValue] : -1;
  NSDictionary *tree = vp_serialize_element(app, 0, maxDepth);
  CFRelease(app);

  if (!tree) {
    NSMutableDictionary *r = vp_make_response(@"err", reqId);
    r[@"msg"] = @"accessibility element returned no attributes — the accessibility "
                @"server may be off; try {\"action\":\"enable\"}";
    return r;
  }

  NSMutableDictionary *r = vp_make_response(@"ok", reqId);
  r[@"tree"] = tree;
  r[@"pid"] = @(pid);
  return r;
}
