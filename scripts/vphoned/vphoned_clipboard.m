/*
 * vphoned_clipboard — Clipboard read/write via UIPasteboard (dlopen).
 *
 * UIPasteboard is loaded at runtime since vphoned is a daemon without UIKit.
 * Uses objc_msgSend for all UIPasteboard interactions.
 */

#import "vphoned_clipboard.h"
#import "vphoned_protocol.h"
#include <dlfcn.h>
#include <objc/message.h>
#include <unistd.h>

static BOOL gClipboardLoaded = NO;
static Class gPasteboardClass = Nil;
// UIImagePNGRepresentation
static NSData *(*pImagePNGRep)(id) = NULL;

BOOL vp_clipboard_load(void) {
  void *h =
      dlopen("/System/Library/Frameworks/UIKit.framework/UIKit", RTLD_LAZY);
  if (!h) {
    NSLog(@"vphoned: dlopen UIKit failed: %s", dlerror());
    return NO;
  }

  gPasteboardClass = NSClassFromString(@"UIPasteboard");
  if (!gPasteboardClass) {
    NSLog(@"vphoned: UIPasteboard class not found");
    return NO;
  }

  pImagePNGRep = dlsym(h, "UIImagePNGRepresentation");
  if (!pImagePNGRep) {
    NSLog(@"vphoned: UIImagePNGRepresentation not found (image support "
          @"disabled)");
    // Non-fatal: text clipboard still works
  }

  gClipboardLoaded = YES;
  NSLog(@"vphoned: clipboard loaded (UIKit)");
  return YES;
}

static id get_general_pasteboard(void) {
  return ((id (*)(Class, SEL))objc_msgSend)(
      gPasteboardClass, sel_registerName("generalPasteboard"));
}

NSDictionary *vp_handle_clipboard_command(int fd, NSDictionary *msg) {
  NSString *type = msg[@"t"];
  id reqId = msg[@"id"];

  if (!gClipboardLoaded) {
    NSMutableDictionary *r = vp_make_response(@"err", reqId);
    r[@"msg"] = @"clipboard not available (UIKit not loaded)";
    return r;
  }

  // -- clipboard_get --
  if ([type isEqualToString:@"clipboard_get"]) {
    id pb = get_general_pasteboard();
    if (!pb) {
      NSMutableDictionary *r = vp_make_response(@"err", reqId);
      r[@"msg"] = @"failed to get general pasteboard";
      return r;
    }

    NSMutableDictionary *r = vp_make_response(@"clipboard_get", reqId);

    // changeCount
    NSInteger changeCount = ((NSInteger (*)(id, SEL))objc_msgSend)(
        pb, sel_registerName("changeCount"));
    r[@"change_count"] = @(changeCount);

    // pasteboardTypes
    NSArray *types = ((id (*)(id, SEL))objc_msgSend)(
        pb, sel_registerName("pasteboardTypes"));
    r[@"types"] = types ?: @[];

    // string
    NSString *str =
        ((id (*)(id, SEL))objc_msgSend)(pb, sel_registerName("string"));
    if (str)
      r[@"text"] = str;

    // image
    id image = ((id (*)(id, SEL))objc_msgSend)(pb, sel_registerName("image"));
    NSData *pngData = nil;
    if (image && pImagePNGRep) {
      pngData = pImagePNGRep(image);
    }

    if (pngData && pngData.length > 0) {
      r[@"has_image"] = @YES;
      r[@"image_size"] = @(pngData.length);

      // Write JSON header, then binary PNG data
      if (!vp_write_message(fd, r))
        return nil;
      vp_write_fully(fd, pngData.bytes, pngData.length);
      return nil; // Already written inline
    } else {
      r[@"has_image"] = @NO;
      return r;
    }
  }

  // -- clipboard_set --
  if ([type isEqualToString:@"clipboard_set"]) {
    id pb = get_general_pasteboard();
    if (!pb) {
      NSMutableDictionary *r = vp_make_response(@"err", reqId);
      r[@"msg"] = @"failed to get general pasteboard";
      return r;
    }

    NSString *setType = msg[@"type"];
    if ([setType isEqualToString:@"image"]) {
      // Image mode: read binary payload
      NSUInteger size = [msg[@"size"] unsignedIntegerValue];
      if (size == 0 || size > 50 * 1024 * 1024) {
        if (size > 0)
          vp_drain(fd, size);
        NSMutableDictionary *r = vp_make_response(@"err", reqId);
        r[@"msg"] = @"invalid image size";
        return r;
      }

      NSMutableData *imgData = [NSMutableData dataWithLength:size];
      if (!vp_read_fully(fd, imgData.mutableBytes, size)) {
        NSMutableDictionary *r = vp_make_response(@"err", reqId);
        r[@"msg"] = @"failed to read image data";
        return r;
      }

      // Create UIImage from PNG data and set on pasteboard
      Class uiImageClass = NSClassFromString(@"UIImage");
      if (uiImageClass) {
        id image = ((id (*)(Class, SEL, id))objc_msgSend)(
            uiImageClass, sel_registerName("imageWithData:"), imgData);
        if (image) {
          ((void (*)(id, SEL, id))objc_msgSend)(
              pb, sel_registerName("setImage:"), image);
        }
      }
    } else {
      // Text mode
      NSString *text = msg[@"text"];
      if (text) {
        ((void (*)(id, SEL, id))objc_msgSend)(
            pb, sel_registerName("setString:"), text);
      }
    }

    NSInteger changeCount = ((NSInteger (*)(id, SEL))objc_msgSend)(
        pb, sel_registerName("changeCount"));
    NSMutableDictionary *r = vp_make_response(@"clipboard_set", reqId);
    r[@"ok"] = @YES;
    r[@"change_count"] = @(changeCount);
    return r;
  }

  NSMutableDictionary *r = vp_make_response(@"err", reqId);
  r[@"msg"] =
      [NSString stringWithFormat:@"unknown clipboard command: %@", type];
  return r;
}
