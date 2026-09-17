/*
 * vphoned_accessibility — Accessibility tree query (stub).
 *
 * TODO: Implement proper accessibility tree retrieval.
 * Options under investigation:
 *   1. XPC to com.apple.accessibility.AXRuntime
 *   2. AXUIElement private API (may not be available on iOS)
 *   3. Dylib injection into SpringBoard
 *   4. Direct UIAccessibility traversal via task_for_pid
 */

#import "vphoned_accessibility.h"
#import "vphoned_protocol.h"

NSDictionary *vp_handle_accessibility_command(NSDictionary *msg) {
  id reqId = msg[@"id"];

  NSMutableDictionary *r = vp_make_response(@"err", reqId);
  r[@"msg"] = @"accessibility_tree not yet implemented — requires XPC research";
  return r;
}
