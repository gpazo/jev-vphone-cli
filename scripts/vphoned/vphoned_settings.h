/*
 * vphoned_settings — System preferences read/write over vsock.
 *
 * Handles settings_get and settings_set using CFPreferences.
 * No extra frameworks needed — CFPreferences is in CoreFoundation.
 */

#pragma once
#import <Foundation/Foundation.h>

/// Handle a settings command. Returns a response dict.
NSDictionary *vp_handle_settings_command(NSDictionary *msg);
