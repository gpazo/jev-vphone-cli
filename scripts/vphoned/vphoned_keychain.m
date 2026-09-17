/*
 * vphoned_keychain — Remote keychain enumeration over vsock.
 *
 * Uses both SecItemCopyMatching (for items we're entitled to) and direct
 * sqlite3 access to /var/Keychains/keychain-2.db (for everything else).
 * The sqlite approach bypasses access-group entitlement checks entirely.
 */

#import "vphoned_keychain.h"
#import "vphoned_protocol.h"
#import <Security/Security.h>
#import <sqlite3.h>

// MARK: - Helpers

/// Convert a CFType keychain attribute value to a JSON-safe NSObject.
static id safe_value(id val) {
    if (!val || val == (id)kCFNull) return [NSNull null];
    if ([val isKindOfClass:[NSString class]]) return val;
    if ([val isKindOfClass:[NSNumber class]]) return val;
    if ([val isKindOfClass:[NSDate class]]) {
        return @([(NSDate *)val timeIntervalSince1970]);
    }
    if ([val isKindOfClass:[NSData class]]) {
        NSString *str = [[NSString alloc] initWithData:val encoding:NSUTF8StringEncoding];
        if (str) return str;
        return [(NSData *)val base64EncodedStringWithOptions:0];
    }
    return [val description];
}

// MARK: - SQLite-based keychain reader

static NSString *KEYCHAIN_DB_PATH = @"/var/Keychains/keychain-2.db";

/// Map sqlite table name to our class abbreviation.
static NSDictionary *tableToClass(void) {
    return @{
        @"genp": @"genp",
        @"inet": @"inet",
        @"cert": @"cert",
        @"keys": @"keys",
    };
}

/// Read a text column, returning @"" if NULL.
static NSString *col_text(sqlite3_stmt *stmt, int col) {
    const unsigned char *val = sqlite3_column_text(stmt, col);
    if (!val) return @"";
    return [NSString stringWithUTF8String:(const char *)val];
}

/// Read a blob column as base64 string.
static NSString *col_blob_base64(sqlite3_stmt *stmt, int col) {
    const void *blob = sqlite3_column_blob(stmt, col);
    int size = sqlite3_column_bytes(stmt, col);
    if (!blob || size <= 0) return @"";
    NSData *data = [NSData dataWithBytes:blob length:size];
    // Try UTF-8 first
    NSString *str = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (str) return str;
    return [data base64EncodedStringWithOptions:0];
}

/// Query one table from the keychain DB via sqlite3.
static NSArray *query_db_table(sqlite3 *db, NSString *table, NSString *className, NSMutableArray *diag) {
    // Columns available in genp/inet tables:
    //   rowid, acct, svce, agrp, labl, data, cdat, mdat, desc, icmt, type, crtr, pdmn
    // inet also has: srvr, ptcl, port, path
    NSString *sql;
    BOOL isInet = [table isEqualToString:@"inet"];
    BOOL isCert = [table isEqualToString:@"cert"];
    BOOL isKeys = [table isEqualToString:@"keys"];

    if (isInet) {
        sql = [NSString stringWithFormat:
            @"SELECT rowid, acct, svce, agrp, labl, data, cdat, mdat, pdmn, srvr, ptcl, port, path FROM %@", table];
    } else if (isCert || isKeys) {
        sql = [NSString stringWithFormat:
            @"SELECT rowid, agrp, labl, data, cdat, mdat, pdmn FROM %@", table];
    } else {
        sql = [NSString stringWithFormat:
            @"SELECT rowid, acct, svce, agrp, labl, data, cdat, mdat, pdmn FROM %@", table];
    }

    sqlite3_stmt *stmt = NULL;
    int rc = sqlite3_prepare_v2(db, sql.UTF8String, -1, &stmt, NULL);
    if (rc != SQLITE_OK) {
        [diag addObject:[NSString stringWithFormat:@"%@: sqlite error %d", className, rc]];
        return @[];
    }

    NSMutableArray *output = [NSMutableArray array];
    while (sqlite3_step(stmt) == SQLITE_ROW) {
        NSMutableDictionary *entry = [NSMutableDictionary dictionary];
        entry[@"class"] = className;

        int col = 0;
        int rowid = sqlite3_column_int(stmt, col++);

        if (!isCert && !isKeys) {
            entry[@"account"] = col_text(stmt, col++);
            entry[@"service"] = col_text(stmt, col++);
        }
        entry[@"accessGroup"] = col_text(stmt, col++);
        entry[@"label"] = col_text(stmt, col++);

        // Value data
        const void *blob = sqlite3_column_blob(stmt, col);
        int blobSize = sqlite3_column_bytes(stmt, col);
        if (blob && blobSize > 0) {
            NSData *data = [NSData dataWithBytes:blob length:blobSize];
            NSString *str = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            if (str) {
                entry[@"value"] = str;
                entry[@"valueEncoding"] = @"utf8";
            } else {
                entry[@"value"] = [data base64EncodedStringWithOptions:0];
                entry[@"valueEncoding"] = @"base64";
            }
            entry[@"valueSize"] = @(blobSize);
        }
        col++;

        // Dates (stored as text in sqlite, e.g. "2025-01-15 12:34:56")
        NSString *cdat = col_text(stmt, col++);
        NSString *mdat = col_text(stmt, col++);
        if (cdat.length > 0) entry[@"createdStr"] = cdat;
        if (mdat.length > 0) entry[@"modifiedStr"] = mdat;

        // Protection class (pdmn)
        NSString *pdmn = col_text(stmt, col++);
        if (pdmn.length > 0) entry[@"protection"] = pdmn;

        // inet-specific fields
        if (isInet) {
            NSString *server = col_text(stmt, col++);
            if (server.length > 0) entry[@"server"] = server;
            NSString *protocol = col_text(stmt, col++);
            if (protocol.length > 0) entry[@"protocol"] = protocol;
            int port = sqlite3_column_int(stmt, col++);
            if (port > 0) entry[@"port"] = @(port);
            NSString *path = col_text(stmt, col++);
            if (path.length > 0) entry[@"path"] = path;
        }

        // Use rowid for unique ID generation
        entry[@"_rowid"] = @(rowid);
        [output addObject:entry];
    }

    sqlite3_finalize(stmt);

    NSUInteger count = output.count;
    if (count > 0) {
        [diag addObject:[NSString stringWithFormat:@"%@: %lu rows", className, (unsigned long)count]];
    } else {
        [diag addObject:[NSString stringWithFormat:@"%@: empty", className]];
    }
    return output;
}

/// Read all keychain items directly from the sqlite database.
static NSDictionary *query_keychain_db(NSString *filterClass, NSMutableArray *diag) {
    sqlite3 *db = NULL;
    int rc = sqlite3_open_v2(KEYCHAIN_DB_PATH.UTF8String, &db, SQLITE_OPEN_READONLY, NULL);
    if (rc != SQLITE_OK) {
        [diag addObject:[NSString stringWithFormat:@"db open failed: %d", rc]];
        NSLog(@"vphoned: sqlite3_open(%@) failed: %d", KEYCHAIN_DB_PATH, rc);
        return @{@"items": @[], @"diag": diag};
    }

    [diag addObject:[NSString stringWithFormat:@"opened %@", KEYCHAIN_DB_PATH]];

    NSMutableArray *allItems = [NSMutableArray array];

    struct { NSString *table; NSString *name; } tables[] = {
        { @"genp", @"genp" },
        { @"inet", @"inet" },
        { @"cert", @"cert" },
        { @"keys", @"keys" },
    };

    for (size_t i = 0; i < sizeof(tables) / sizeof(tables[0]); i++) {
        if (filterClass && ![filterClass isEqualToString:tables[i].name]) continue;
        NSArray *items = query_db_table(db, tables[i].table, tables[i].name, diag);
        [allItems addObjectsFromArray:items];
    }

    sqlite3_close(db);
    return @{@"items": allItems};
}

// MARK: - Command Handler

NSDictionary *vp_handle_keychain_command(NSDictionary *msg) {
    id reqId = msg[@"id"];
    NSString *type = msg[@"t"];

    // Add a test keychain item (for debugging)
    if ([type isEqualToString:@"keychain_add"]) {
        NSString *account = msg[@"account"] ?: @"vphone-test";
        NSString *service = msg[@"service"] ?: @"vphone";
        NSString *password = msg[@"password"] ?: @"testpass123";

        NSDictionary *deleteQuery = @{
            (__bridge id)kSecClass:       (__bridge id)kSecClassGenericPassword,
            (__bridge id)kSecAttrAccount:  account,
            (__bridge id)kSecAttrService:  service,
        };
        SecItemDelete((__bridge CFDictionaryRef)deleteQuery);

        NSDictionary *attrs = @{
            (__bridge id)kSecClass:       (__bridge id)kSecClassGenericPassword,
            (__bridge id)kSecAttrAccount:  account,
            (__bridge id)kSecAttrService:  service,
            (__bridge id)kSecAttrLabel:    [NSString stringWithFormat:@"%@ (%@)", service, account],
            (__bridge id)kSecValueData:    [password dataUsingEncoding:NSUTF8StringEncoding],
        };

        OSStatus status = SecItemAdd((__bridge CFDictionaryRef)attrs, NULL);
        NSLog(@"vphoned: keychain_add: account=%@ service=%@ status=%d", account, service, (int)status);

        NSMutableDictionary *resp = vp_make_response(@"keychain_add", reqId);
        resp[@"status"] = @(status);
        resp[@"ok"] = @(status == errSecSuccess);
        if (status != errSecSuccess) {
            resp[@"msg"] = [NSString stringWithFormat:@"SecItemAdd failed: %d", (int)status];
        }
        return resp;
    }

    if ([type isEqualToString:@"keychain_list"]) {
        NSString *filterClass = msg[@"class"];
        NSMutableArray *diag = [NSMutableArray array];

        // Primary: read directly from sqlite DB (bypasses entitlement checks)
        NSDictionary *dbResult = query_keychain_db(filterClass, diag);
        NSArray *dbItems = dbResult[@"items"];

        NSLog(@"vphoned: keychain_list: %lu items (sqlite), diag: %@",
              (unsigned long)dbItems.count, diag);

        NSMutableDictionary *resp = vp_make_response(@"keychain_list", reqId);
        resp[@"items"] = dbItems;
        resp[@"count"] = @(dbItems.count);
        resp[@"diag"] = diag;
        return resp;
    }

    NSMutableDictionary *r = vp_make_response(@"err", reqId);
    r[@"msg"] = [NSString stringWithFormat:@"unknown keychain command: %@", type];
    return r;
}
