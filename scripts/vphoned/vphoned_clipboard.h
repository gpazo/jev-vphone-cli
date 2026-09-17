/*
 * vphoned_clipboard — Clipboard (pasteboard) read/write over vsock.
 *
 * Handles clipboard_get and clipboard_set using UIPasteboard via dlopen.
 * Supports text and image (PNG) payloads with inline binary transfer.
 */

#pragma once
#import <Foundation/Foundation.h>

/// Load UIKit symbols for clipboard access. Returns NO on failure.
BOOL vp_clipboard_load(void);

/// Handle a clipboard command. May write binary data inline for images.
/// Returns a response dict, or nil if the response was written inline.
NSDictionary *vp_handle_clipboard_command(int fd, NSDictionary *msg);
