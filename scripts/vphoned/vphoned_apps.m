/*
 * vphoned_apps — App lifecycle management via private APIs.
 *
 * Uses LSApplicationWorkspace (CoreServices) and FBSSystemService
 * (FrontBoardServices).
 */

#import "vphoned_apps.h"
#import "vphoned_protocol.h"
#include <dlfcn.h>
#include <objc/message.h>
#include <signal.h>
#include <unistd.h>

// MARK: - Private API Declarations

@interface LSApplicationProxy : NSObject
@property(readonly) NSString *bundleIdentifier;
@property(readonly) NSString *localizedName;
@property(readonly) NSString *shortVersionString;
@property(readonly) NSString *applicationType;
@property(readonly) NSURL *bundleURL;
@property(readonly) NSURL *dataContainerURL;
@end

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (NSArray *)allInstalledApplications;
- (BOOL)openApplicationWithBundleID:(NSString *)bundleID;
@end

// FBSSystemService loaded via dlsym
static Class gFBSSystemServiceClass = Nil;

static BOOL gAppsLoaded = NO;

BOOL vp_apps_load(void) {
  // FrontBoardServices
  void *fbs = dlopen("/System/Library/PrivateFrameworks/"
                     "FrontBoardServices.framework/FrontBoardServices",
                     RTLD_LAZY);
  if (fbs) {
    gFBSSystemServiceClass = NSClassFromString(@"FBSSystemService");
    if (!gFBSSystemServiceClass) {
      NSLog(@"vphoned: FBSSystemService class not found");
    }
  } else {
    NSLog(@"vphoned: dlopen FrontBoardServices failed: %s", dlerror());
  }

  // LSApplicationWorkspace is in CoreServices (already linked)
  Class lsClass = NSClassFromString(@"LSApplicationWorkspace");
  if (!lsClass) {
    NSLog(@"vphoned: LSApplicationWorkspace class not found");
    return NO;
  }

  gAppsLoaded = YES;
  NSLog(@"vphoned: apps loaded (FBS=%s)",
        gFBSSystemServiceClass ? "yes" : "no");
  return YES;
}

// MARK: - Helpers

static pid_t pid_for_app(NSString *bundleID) {
  if (!gFBSSystemServiceClass)
    return 0;
  id service = ((id (*)(Class, SEL))objc_msgSend)(
      gFBSSystemServiceClass, sel_registerName("sharedService"));
  if (!service)
    return 0;
  return ((pid_t (*)(id, SEL, id))objc_msgSend)(
      service, sel_registerName("pidForApplication:"), bundleID);
}

static NSString *state_for_pid(pid_t pid) {
  if (pid > 0)
    return @"running";
  return @"not_running";
}

// MARK: - Command Handler

NSDictionary *vp_handle_apps_command(NSDictionary *msg) {
  NSString *type = msg[@"t"];
  id reqId = msg[@"id"];

  if (!gAppsLoaded) {
    NSMutableDictionary *r = vp_make_response(@"err", reqId);
    r[@"msg"] = @"apps not available";
    return r;
  }

  // -- app_list --
  if ([type isEqualToString:@"app_list"]) {
    LSApplicationWorkspace *ws = [LSApplicationWorkspace defaultWorkspace];
    NSArray *allApps = [ws allInstalledApplications];
    NSString *filter = msg[@"filter"] ?: @"all";

    NSMutableArray *result = [NSMutableArray array];
    for (LSApplicationProxy *proxy in allApps) {
      NSString *appType = proxy.applicationType;
      BOOL isSystem = [appType isEqualToString:@"System"];

      if ([filter isEqualToString:@"user"] && isSystem)
        continue;
      if ([filter isEqualToString:@"system"] && !isSystem)
        continue;

      pid_t pid = pid_for_app(proxy.bundleIdentifier);

      if ([filter isEqualToString:@"running"] && pid <= 0)
        continue;

      [result addObject:@{
        @"bundle_id" : proxy.bundleIdentifier ?: @"",
        @"name" : proxy.localizedName ?: @"",
        @"version" : proxy.shortVersionString ?: @"",
        @"type" : isSystem ? @"system" : @"user",
        @"state" : state_for_pid(pid),
        @"pid" : @(pid > 0 ? pid : 0),
        @"path" : proxy.bundleURL.path ?: @"",
        @"data_container" : proxy.dataContainerURL.path ?: @"",
      }];
    }

    NSMutableDictionary *r = vp_make_response(@"app_list", reqId);
    r[@"apps"] = result;
    return r;
  }

  // -- app_launch --
  if ([type isEqualToString:@"app_launch"]) {
    NSString *bundleID = msg[@"bundle_id"];
    if (!bundleID) {
      NSMutableDictionary *r = vp_make_response(@"err", reqId);
      r[@"msg"] = @"missing bundle_id";
      return r;
    }

    LSApplicationWorkspace *ws = [LSApplicationWorkspace defaultWorkspace];
    NSString *url = msg[@"url"];

    BOOL ok;
    if (url) {
      // Open URL (which will launch the handling app)
      NSURL *nsurl = [NSURL URLWithString:url];
      // Try openURL:withOptions: if available
      SEL openURLSel = sel_registerName("openURL:withOptions:");
      if ([ws respondsToSelector:openURLSel]) {
        ok = ((BOOL (*)(id, SEL, id, id))objc_msgSend)(ws, openURLSel, nsurl,
                                                       nil);
      } else {
        ok = [ws openApplicationWithBundleID:bundleID];
      }
    } else {
      ok = [ws openApplicationWithBundleID:bundleID];
    }

    if (!ok) {
      NSMutableDictionary *r = vp_make_response(@"err", reqId);
      r[@"msg"] = [NSString stringWithFormat:@"failed to launch %@", bundleID];
      return r;
    }

    // Brief wait for app to start
    usleep(500000); // 500ms

    pid_t pid = pid_for_app(bundleID);
    NSMutableDictionary *r = vp_make_response(@"app_launch", reqId);
    r[@"ok"] = @YES;
    r[@"pid"] = @(pid > 0 ? pid : 0);
    return r;
  }

  // -- app_terminate --
  if ([type isEqualToString:@"app_terminate"]) {
    NSString *bundleID = msg[@"bundle_id"];
    if (!bundleID) {
      NSMutableDictionary *r = vp_make_response(@"err", reqId);
      r[@"msg"] = @"missing bundle_id";
      return r;
    }

    if (gFBSSystemServiceClass) {
      id service = ((id (*)(Class, SEL))objc_msgSend)(
          gFBSSystemServiceClass, sel_registerName("sharedService"));
      if (service) {
        // terminateApplication:forReason:andReport:withDescription:
        // reason 5 = user requested, report NO
        ((void (*)(id, SEL, id, int, BOOL, id))objc_msgSend)(
            service,
            sel_registerName(
                "terminateApplication:forReason:andReport:withDescription:"),
            bundleID, 5, NO, @"vphoned terminate request");
      }
    } else {
      // Fallback: kill by PID
      pid_t pid = pid_for_app(bundleID);
      if (pid > 0)
        kill(pid, SIGTERM);
    }

    NSMutableDictionary *r = vp_make_response(@"app_terminate", reqId);
    r[@"ok"] = @YES;
    return r;
  }

  NSMutableDictionary *r = vp_make_response(@"err", reqId);
  r[@"msg"] = [NSString stringWithFormat:@"unknown apps command: %@", type];
  return r;
}
