/*
 * vphoned_settings — System preferences read/write via CFPreferences.
 *
 * Reads and writes preference domains using CFPreferences API.
 * No additional frameworks required.
 */

#import "vphoned_settings.h"
#import "vphoned_protocol.h"

// MARK: - Helpers

/// Map a CFPropertyList value to a JSON-safe representation with type info.
static NSDictionary *serialize_value(id value) {
  if (!value || value == (id)kCFNull) {
    return @{@"value" : [NSNull null], @"type" : @"null"};
  }
  if ([value isKindOfClass:[NSNumber class]]) {
    // Distinguish boolean from number
    if (strcmp([value objCType], @encode(BOOL)) == 0 ||
        strcmp([value objCType], @encode(char)) == 0) {
      return @{@"value" : value, @"type" : @"boolean"};
    }
    // Check for float/double
    if (strcmp([value objCType], @encode(float)) == 0 ||
        strcmp([value objCType], @encode(double)) == 0) {
      return @{@"value" : value, @"type" : @"float"};
    }
    return @{@"value" : value, @"type" : @"integer"};
  }
  if ([value isKindOfClass:[NSString class]]) {
    return @{@"value" : value, @"type" : @"string"};
  }
  if ([value isKindOfClass:[NSData class]]) {
    return @{
      @"value" : [(NSData *)value base64EncodedStringWithOptions:0],
      @"type" : @"data"
    };
  }
  if ([value isKindOfClass:[NSDate class]]) {
    return @{
      @"value" : @([(NSDate *)value timeIntervalSince1970]),
      @"type" : @"date"
    };
  }
  if ([value isKindOfClass:[NSArray class]] ||
      [value isKindOfClass:[NSDictionary class]]) {
    // Try JSON serialization
    if ([NSJSONSerialization isValidJSONObject:value]) {
      return @{@"value" : value, @"type" : @"plist"};
    }
    return @{@"value" : [value description], @"type" : @"plist"};
  }
  return @{@"value" : [value description], @"type" : @"unknown"};
}

/// Deserialize a value from the request based on type hint.
static id deserialize_value(id rawValue, NSString *typeHint) {
  if (!rawValue || rawValue == (id)[NSNull null])
    return nil;

  if ([typeHint isEqualToString:@"boolean"]) {
    return @([rawValue boolValue]);
  }
  if ([typeHint isEqualToString:@"integer"]) {
    return @([rawValue longLongValue]);
  }
  if ([typeHint isEqualToString:@"float"]) {
    return @([rawValue doubleValue]);
  }
  if ([typeHint isEqualToString:@"string"]) {
    return [rawValue description];
  }
  if ([typeHint isEqualToString:@"data"]) {
    if ([rawValue isKindOfClass:[NSString class]]) {
      return [[NSData alloc] initWithBase64EncodedString:rawValue options:0];
    }
  }
  // Default: pass through (JSON types map naturally)
  return rawValue;
}

// MARK: - Command Handler

NSDictionary *vp_handle_settings_command(NSDictionary *msg) {
  NSString *type = msg[@"t"];
  id reqId = msg[@"id"];

  // -- settings_get --
  if ([type isEqualToString:@"settings_get"]) {
    NSString *domain = msg[@"domain"];
    NSString *key = msg[@"key"];

    if (!domain) {
      NSMutableDictionary *r = vp_make_response(@"err", reqId);
      r[@"msg"] = @"missing domain";
      return r;
    }

    if (key && key.length > 0) {
      // Single key
      CFPropertyListRef value = CFPreferencesCopyAppValue(
          (__bridge CFStringRef)key, (__bridge CFStringRef)domain);
      NSMutableDictionary *r = vp_make_response(@"settings_get", reqId);
      if (value) {
        NSDictionary *serialized = serialize_value((__bridge id)value);
        r[@"value"] = serialized[@"value"];
        r[@"type"] = serialized[@"type"];
        CFRelease(value);
      } else {
        r[@"value"] = [NSNull null];
        r[@"type"] = @"null";
      }
      return r;
    } else {
      // All keys in domain
      CFArrayRef keys = CFPreferencesCopyKeyList((__bridge CFStringRef)domain,
                                                 kCFPreferencesCurrentUser,
                                                 kCFPreferencesAnyHost);

      NSMutableDictionary *r = vp_make_response(@"settings_get", reqId);
      if (keys) {
        CFDictionaryRef allValues = CFPreferencesCopyMultiple(
            keys, (__bridge CFStringRef)domain, kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost);
        if (allValues) {
          // Convert to serializable dict
          NSDictionary *dict = (__bridge NSDictionary *)allValues;
          NSMutableDictionary *serialized = [NSMutableDictionary dictionary];
          for (NSString *k in dict) {
            NSDictionary *entry = serialize_value(dict[k]);
            serialized[k] = entry;
          }
          r[@"value"] = serialized;
          r[@"type"] = @"dictionary";
          CFRelease(allValues);
        }
        CFRelease(keys);
      } else {
        r[@"value"] = @{};
        r[@"type"] = @"dictionary";
      }
      return r;
    }
  }

  // -- settings_set --
  if ([type isEqualToString:@"settings_set"]) {
    NSString *domain = msg[@"domain"];
    NSString *key = msg[@"key"];
    id rawValue = msg[@"value"];
    NSString *typeHint = msg[@"type"];

    if (!domain || !key) {
      NSMutableDictionary *r = vp_make_response(@"err", reqId);
      r[@"msg"] = @"missing domain or key";
      return r;
    }

    id value = deserialize_value(rawValue, typeHint);

    CFPreferencesSetAppValue((__bridge CFStringRef)key,
                             (__bridge CFPropertyListRef)value,
                             (__bridge CFStringRef)domain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)domain);

    NSMutableDictionary *r = vp_make_response(@"settings_set", reqId);
    r[@"ok"] = @YES;
    return r;
  }

  NSMutableDictionary *r = vp_make_response(@"err", reqId);
  r[@"msg"] = [NSString stringWithFormat:@"unknown settings command: %@", type];
  return r;
}
