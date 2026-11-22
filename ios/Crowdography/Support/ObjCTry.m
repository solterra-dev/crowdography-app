#import "ObjCTry.h"

@implementation ObjCTry

+ (BOOL)run:(NS_NOESCAPE void (^)(void))block error:(NSError * __autoreleasing *)error {
    @try {
        block();
        return YES;
    } @catch (NSException *e) {
        if (error) {
            NSString *text = [NSString stringWithFormat:@"%@: %@", e.name, e.reason ?: @"no reason given"];
            *error = [NSError errorWithDomain:@"com.crowdography.exception" code:1 userInfo:@{NSLocalizedDescriptionKey: text}];
        }
        return NO;
    }
}

@end
