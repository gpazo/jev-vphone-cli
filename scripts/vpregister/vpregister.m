// vpregister — register JB app bundles on iOS 27 via the containerized
// LaunchServices API (the modern replacement for the deprecated, gutted
// -[LSApplicationWorkspace registerApplicationDictionary:] that uicache -a
// uses). Requires the lsd clientIsEntitledForEmbeddedRegistrationOperations
// gate patch (cfw_patch_lsd_embedded_reg). Usage: vpregister [app.app ...]
// (no args = scan /var/jb/Applications/*.app).
#import <Foundation/Foundation.h>
#import <dlfcn.h>
@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (BOOL)registerContainerizedApplicationWithInfoDictionaries:(NSArray *)infos
                                              operationUUID:(NSUUID *)uuid
                                             requestContext:(id)context
                                               saveObserver:(id)observer
                                          registrationError:(NSError **)error;
@end
static BOOL regapp(LSApplicationWorkspace *ws, NSString *path) {
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Info.plist"]];
    NSString *bid = info[@"CFBundleIdentifier"];
    if (bid.length == 0) return NO;
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"Path"] = path; d[@"CFBundleIdentifier"] = bid; d[@"CodeInfoIdentifier"] = bid;
    d[@"ApplicationType"] = @"System"; d[@"CompatibilityState"] = @0;
    d[@"SignerIdentity"] = @"Apple iPhone OS Application Signing";
    d[@"SignerOrganization"] = @"Apple Inc."; d[@"IsAdHocSigned"] = @YES;
    d[@"SignatureVersion"] = @132352; d[@"IsDeletable"] = @YES;
    NSError *err = nil;
    [ws registerContainerizedApplicationWithInfoDictionaries:@[d] operationUUID:[NSUUID UUID]
         requestContext:nil saveObserver:nil registrationError:&err];
    if (err) fprintf(stderr, "  err: %s\n", err.description.UTF8String);
    return err == nil;
}
int main(int argc, char **argv) {
    @autoreleasepool {
        dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_NOW);
        LSApplicationWorkspace *ws = [LSApplicationWorkspace defaultWorkspace];
        NSMutableArray *paths = [NSMutableArray array];
        if (argc > 1) { for (int i = 1; i < argc; i++) [paths addObject:@(argv[i])]; }
        else {
            NSString *dir = @"/var/jb/Applications";
            for (NSString *n in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil])
                if ([n hasSuffix:@".app"]) [paths addObject:[dir stringByAppendingPathComponent:n]];
        }
        int ok = 0, fail = 0;
        for (NSString *p in paths) { BOOL r = regapp(ws, p); printf("%-4s %s\n", r ? "OK" : "FAIL", p.UTF8String); r ? ok++ : fail++; }
        printf("registered %d, failed %d\n", ok, fail);
        return fail ? 1 : 0;
    }
}
