// 斗室: a small Linux (Alpine, aarch64) running inside Clio on the iSH ARM64 kernel.
// The kernel is iSH (https://github.com/ish-app/ish) with the ARM64 guest from
// OpenMinis/ish-arm64, both GPL. This bridge is adapted from that project's
// AppDelegate.m and ISHShellExecutor.m.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^DenLine)(NSString *line, BOOL isError);
typedef void (^DenDone)(int code, NSString *output, NSString *errorOutput);

@interface DenKernel : NSObject

/// Boots the kernel on a root made by fakefsify (a folder holding data/ and meta.db).
/// `desk` is a host folder shown inside Linux at /root/desk. Returns 0, or a negative Linux error.
+ (int)bootRoot:(NSString *)root desk:(nullable NSString *)desk;

+ (BOOL)booted;

/// Runs `/bin/sh -c command`. Lines arrive on the main queue as they are printed. Returns the guest pid, or a negative error.
+ (int)run:(NSString *)command
       environment:(nullable NSDictionary<NSString *, NSString *> *)environment
            onLine:(nullable DenLine)onLine
              done:(DenDone)done;

+ (BOOL)kill:(int)pid;

@end

/// 笔砚: an interactive shell on a pseudo-terminal, for a real terminal view.
@interface DenTerminal : NSObject

/// Starts a login shell. Output arrives on the main queue; `exited` fires once when the shell ends.
+ (nullable instancetype)openWithOutput:(void (^)(NSData *data))output exited:(void (^)(void))exited error:(int *)error NS_SWIFT_NAME(open(output:exited:error:));

@property (nonatomic, readonly) int pid;
- (void)send:(NSData *)data NS_SWIFT_NAME(send(_:));
- (void)resizeColumns:(int)columns rows:(int)rows NS_SWIFT_NAME(resize(columns:rows:));
- (void)close;

@end

NS_ASSUME_NONNULL_END
