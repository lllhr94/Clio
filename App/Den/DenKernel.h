// 斗室: a small Linux (Alpine, aarch64) running inside Clio on the iSH ARM64 kernel.
// The kernel is iSH (https://github.com/ish-app/ish) with the ARM64 guest from
// OpenMinis/ish-arm64, both GPL. This bridge is adapted from that project's
// AppDelegate.m and ISHShellExecutor.m.

#import <Foundation/Foundation.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^DenLine)(NSString *line, BOOL isError);
typedef void (^DenDone)(int code, NSString *output, NSString *errorOutput);

@interface DenKernel : NSObject

/// Boots the kernel on a root made by fakefsify (a folder holding data/ and meta.db).
/// `desk` is a host folder shown inside Linux at /root/desk. Returns 0, or a negative Linux error.
+ (int)bootRoot:(NSString *)root desk:(nullable NSString *)desk;

/// Boots the kernel with an optional host DNS directory mounted read-only at /etc/clio-dns
/// and linked from /etc/resolv.conf.
+ (int)bootRoot:(NSString *)root desk:(nullable NSString *)desk dnsDir:(nullable NSString *)dnsDir;

/// Boots the kernel with optional read-only host DNS (/etc/clio-dns) and network helper (/etc/clio-net) directories.
+ (int)bootRoot:(NSString *)root
           desk:(nullable NSString *)desk
         dnsDir:(nullable NSString *)dnsDir
         netDir:(nullable NSString *)netDir;

/// Updates the kernel's per-second and burst fork rate limits (for thermal throttling).
+ (void)setForkRateLimit:(uint32_t)perSecond burst:(uint32_t)burst;

/// Reads current host resolver nameservers via res_ninit/res_getservers.
+ (NSArray<NSString *> *)systemDNSServers;

/// Reads current host resolver search domains via res_ninit/dnsrch.
+ (NSArray<NSString *> *)systemSearchDomains;

/// Non-nil if DNS mount/symlink fallback wrote with an error during boot.
+ (nullable NSString *)lastDNSFallbackError;

/// Human-readable diagnostic summary of AF_UNIX socket prefix and AF_NETLINK stub activation.
+ (NSString *)kernelNetworkStatus;

+ (BOOL)booted;

/// Runs `/bin/sh -c command`. Line callbacks run on the pipe readers and may overlap. Returns the guest pid, or a negative error.
+ (int)run:(NSString *)command
       environment:(nullable NSDictionary<NSString *, NSString *> *)environment
            onLine:(nullable DenLine)onLine
              done:(DenDone)done;

+ (int)run:(NSString *)command
       environment:(nullable NSDictionary<NSString *, NSString *> *)environment
         maxOutput:(NSUInteger)maxOutput
            onLine:(nullable DenLine)onLine
              done:(DenDone)done;

+ (BOOL)kill:(int)pid;

@end

/// 笔砚: an interactive shell on a pseudo-terminal, for a real terminal view.
@interface DenTerminal : NSObject

/// Starts a login shell. Output arrives on the main queue; `exited` fires once when the shell ends.
+ (nullable instancetype)openWithOutput:(void (^)(NSData *data))output exited:(void (^)(void))exited error:(int *)error NS_SWIFT_NAME(open(output:exited:error:));

/// Starts a login shell with extra environment variables merged on top of Den's runtime defaults.
+ (nullable instancetype)openWithEnvironment:(nullable NSDictionary<NSString *, NSString *> *)environment
                                      output:(void (^)(NSData *data))output
                                      exited:(void (^)(void))exited
                                       error:(int *)error NS_SWIFT_NAME(open(environment:output:exited:error:));

@property (nonatomic, readonly) int pid;
- (void)send:(NSData *)data NS_SWIFT_NAME(send(_:));
- (void)resizeColumns:(int)columns rows:(int)rows NS_SWIFT_NAME(resize(columns:rows:));
- (void)close;

@end

NS_ASSUME_NONNULL_END
