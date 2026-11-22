#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs a block and turns an Objective-C exception, which would otherwise close the app, into an ordinary error.
/// Apple's camera code reports misuse this way, and Swift cannot catch it on its own.
@interface ObjCTry : NSObject
+ (BOOL)run:(NS_NOESCAPE void (^)(void))block error:(NSError * _Nullable __autoreleasing * _Nullable)error;
@end

NS_ASSUME_NONNULL_END
