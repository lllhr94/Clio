// The simulator has no iSH kernel (it is built for real iPhones only), so 斗室 says it cannot start there.
// Used only for simulator builds, which exist to take screenshots.

#import "DenKernel.h"

@implementation DenKernel

+ (int)bootRoot:(NSString *)root desk:(nullable NSString *)desk { return -38; }

+ (BOOL)booted { return NO; }

+ (int)run:(NSString *)command
       environment:(nullable NSDictionary<NSString *, NSString *> *)environment
            onLine:(nullable DenLine)onLine
              done:(DenDone)done {
    return [self run:command environment:environment maxOutput:400000 onLine:onLine done:done];
}

+ (int)run:(NSString *)command
       environment:(nullable NSDictionary<NSString *, NSString *> *)environment
         maxOutput:(NSUInteger)maxOutput
            onLine:(nullable DenLine)onLine
              done:(DenDone)done {
    dispatch_async(dispatch_get_main_queue(), ^{ done(-38, @"", @"模拟器里没有斗室。"); });
    return -38;
}

+ (BOOL)kill:(int)pid { return NO; }

@end

@implementation DenTerminal

+ (nullable instancetype)openWithOutput:(void (^)(NSData *data))output exited:(void (^)(void))exited error:(int *)error {
    if (error) { *error = -38; }
    return nil;
}

- (int)pid { return -1; }
- (void)send:(NSData *)data {}
- (void)resizeColumns:(int)columns rows:(int)rows {}
- (void)close {}

@end
