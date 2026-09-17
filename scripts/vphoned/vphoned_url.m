/*
 * vphoned_url — URL opening via LSApplicationWorkspace.
 *
 * Uses LSApplicationWorkspace (CoreServices) to open URLs.
 * Does not require UIKit — works from daemon context.
 */

#import "vphoned_url.h"
#import "vphoned_protocol.h"
#include <objc/message.h>

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (BOOL)openURL:(NSURL *)url withOptions:(NSDictionary *)options;
- (BOOL)openSensitiveURL:(NSURL *)url withOptions:(NSDictionary *)options;
@end

NSDictionary *vp_handle_url_command(NSDictionary *msg) {
  id reqId = msg[@"id"];
  NSString *urlStr = msg[@"url"];

  if (!urlStr) {
    NSMutableDictionary *r = vp_make_response(@"err", reqId);
    r[@"msg"] = @"missing url";
    return r;
  }

  NSURL *url = [NSURL URLWithString:urlStr];
  if (!url) {
    NSMutableDictionary *r = vp_make_response(@"err", reqId);
    r[@"msg"] = [NSString stringWithFormat:@"invalid url: %@", urlStr];
    return r;
  }

  LSApplicationWorkspace *ws = [LSApplicationWorkspace defaultWorkspace];
  BOOL ok = NO;

  // Try openURL:withOptions: first
  SEL openURLSel = sel_registerName("openURL:withOptions:");
  if ([ws respondsToSelector:openURLSel]) {
    ok = ((BOOL (*)(id, SEL, id, id))objc_msgSend)(ws, openURLSel, url, nil);
  }

  if (!ok) {
    // Fallback: try openSensitiveURL:withOptions: (requires entitlement)
    SEL sensitiveSel = sel_registerName("openSensitiveURL:withOptions:");
    if ([ws respondsToSelector:sensitiveSel]) {
      ok =
          ((BOOL (*)(id, SEL, id, id))objc_msgSend)(ws, sensitiveSel, url, nil);
    }
  }

  NSMutableDictionary *r = vp_make_response(@"open_url", reqId);
  r[@"ok"] = @(ok);
  if (!ok) {
    r[@"msg"] = [NSString stringWithFormat:@"failed to open url: %@", urlStr];
  }
  return r;
}
