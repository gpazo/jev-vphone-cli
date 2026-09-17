/*
 * vphoned_apps — App lifecycle management over vsock.
 *
 * Handles app_list, app_launch, app_terminate, app_foreground using
 * private APIs: LSApplicationWorkspace, FBSSystemService, SpringBoardServices.
 */

#pragma once
#import <Foundation/Foundation.h>

/// Load private framework symbols for app management. Returns NO on failure.
BOOL vp_apps_load(void);

/// Handle an app command. Returns a response dict.
NSDictionary *vp_handle_apps_command(NSDictionary *msg);
