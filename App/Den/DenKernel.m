// 斗室's bridge to the iSH kernel. Adapted from iSH's app/AppDelegate.m and
// app/ISHShellExecutor.m (ish-app/ish, OpenMinis/ish-arm64; GPL).

#import "DenKernel.h"
#include <resolv.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <fcntl.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/un.h>
#include <unistd.h>
#import <mach/mach.h>
#import <os/proc.h>

#include "kernel/init.h"
#include "kernel/calls.h"
#include "kernel/task.h"
#include "kernel/fs.h"
#include "kernel/mm.h"
#include "fs/dev.h"
#include "fs/devices.h"
#include "fs/fd.h"
#include "fs/path.h"
#include "fs/tty.h"
#include "fs/real.h"
#include "fs/sock.h"
#include "debug.h"

// From fs/fake.h, which is marked internal to the kernel.
int fakefs_bind_mount(const char *linux_path, const char *host_path, bool read_only);
void fakefs_set_rootfs_data_path(const char *abs_host_path);

static NSString *const DenExited = @"DenProcessExited";
static BOOL denBooted = NO;
static NSString *denDNSFallbackError = nil;
static NSString *denKernelNetStatus = @"not-booted";

// MARK: Exit and death

static void den_exit(struct task *task, int code) {
    // Only init and its direct children matter; called with pids_lock held.
    if (task->parent != NULL && task->parent->parent != NULL)
        return;
    pid_t pid = task->pid;
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:DenExited object:nil userInfo:@{@"pid": @(pid), @"code": @(code)}];
    });
}

static void den_die(const char *message) {
    NSLog(@"斗室 kernel died: %s", message);
}

static void den_discard_unstarted_task(struct task *task) {
    if (task == NULL)
        return;
    if (task->mm != NULL) {
        lock(&task->general_lock);
        struct mm *mm = task->mm;
        task->mm = NULL;
        task->mem = NULL;
        unlock(&task->general_lock);
        mm_release(mm);
    }
    if (task->files != NULL) {
        fdtable_release(task->files);
        task->files = NULL;
    }
    if (task->fs != NULL) {
        fs_info_release(task->fs);
        task->fs = NULL;
    }
    if (task->futex_pipe[0] != -1) {
        close(task->futex_pipe[0]);
        task->futex_pipe[0] = -1;
    }
    if (task->futex_pipe[1] != -1) {
        close(task->futex_pipe[1]);
        task->futex_pipe[1] = -1;
    }
    lock(&pids_lock);
    if (task->sighand != NULL) {
        sighand_release(task->sighand);
        task->sighand = NULL;
    }
    struct tgroup *group = task->group;
    if (group != NULL) {
        list_remove(&task->group_links);
        cond_destroy(&group->child_exit);
        cond_destroy(&group->stopped_cond);
        task_leave_session(task);
        list_remove(&group->pgroup);
        free(group);
        task->group = NULL;
        atomic_fetch_sub_explicit(&ish_live_guest_procs, 1, memory_order_relaxed);
    }
    task_destroy(task);
    unlock(&pids_lock);
}

// MARK: Memory

// Tells the kernel how close the app is to the system's memory line, so guests slow down instead of the app being killed.
static void den_memory_tick(bool critical) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    uint64_t footprint = 0;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t) &info, &count) == KERN_SUCCESS)
        footprint = info.phys_footprint;
    uint64_t available = (uint64_t) os_proc_available_memory();
    if (footprint == 0 || available == 0)
        return;
    ish_set_memory_status(footprint + available, available, critical);
}

static void den_memory_start(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        size_t available = os_proc_available_memory();
        size_t page = (size_t) getpagesize();
        if (available > 0 && page > 0)
            ish_set_anon_page_limit((long) ((double) available * 0.6 / (double) page));

        static dispatch_source_t timer;
        static dispatch_source_t pressure;
        dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
        timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
        dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC, 50 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(timer, ^{ den_memory_tick(false); });
        dispatch_resume(timer);
        pressure = dispatch_source_create(DISPATCH_SOURCE_TYPE_MEMORYPRESSURE, 0, DISPATCH_MEMORYPRESSURE_WARN | DISPATCH_MEMORYPRESSURE_CRITICAL, queue);
        dispatch_source_set_event_handler(pressure, ^{
            den_memory_tick((dispatch_source_get_data(pressure) & DISPATCH_MEMORYPRESSURE_CRITICAL) != 0);
        });
        dispatch_resume(pressure);
        den_memory_tick(false);
    });
}

// MARK: Files

static struct fd *den_null_fd(int flags) {
    struct fd *fd = adhoc_fd_create(&realfs_fdops);
    if (fd)
        fd->real_fd = open("/dev/null", flags);
    return fd;
}

static struct fd *den_host_fd(int real) {
    struct fd *fd = adhoc_fd_create(&realfs_fdops);
    if (fd)
        fd->real_fd = real;
    return fd;
}

static BOOL den_write_file(const char *path, NSString *text) {
    struct fd *fd = generic_open(path, O_WRONLY_ | O_CREAT_ | O_TRUNC_, 0644);
    if (!IS_ERR(fd)) {
        NSUInteger length = [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        ssize_t written = fd->ops->write(fd, text.UTF8String, length);
        fd_close(fd);
        return written >= 0 && (NSUInteger)written == length;
    }
    return NO;
}

// Queries the host's DNS servers and search domains via res_ninit so Den stays in sync with Wi-Fi / VPN changes.
static NSArray<NSString *> *den_query_system_dns(NSArray<NSString *> * __autoreleasing *outSearchDomains) {
    struct __res_state res;
    memset(&res, 0, sizeof(res));
    if (res_ninit(&res) != 0) {
        if (outSearchDomains)
            *outSearchDomains = @[];
        return @[];
    }

    NSMutableArray<NSString *> *serversOut = [NSMutableArray array];
    union res_sockaddr_union servers[NI_MAXSERV];
    int found = res_getservers(&res, servers, NI_MAXSERV);
    char address[NI_MAXHOST];
    for (int i = 0; i < found; i++) {
        union res_sockaddr_union server = servers[i];
        if (server.sin.sin_len == 0)
            continue;
        if (getnameinfo((struct sockaddr *)&server.sin, server.sin.sin_len, address, sizeof(address), NULL, 0, NI_NUMERICHOST) == 0) {
            NSString *ip = [NSString stringWithUTF8String:address];
            if (ip.length > 0 && ![serversOut containsObject:ip])
                [serversOut addObject:ip];
        }
    }

    if (outSearchDomains) {
        NSMutableArray<NSString *> *domainsOut = [NSMutableArray array];
        for (int i = 0; i < MAXDNSRCH && res.dnsrch[i] != NULL; i++) {
            const char *raw = res.dnsrch[i];
            if (raw[0] == '\0')
                continue;
            NSString *domain = [NSString stringWithUTF8String:raw];
            if (domain.length > 0 && ![domainsOut containsObject:domain])
                [domainsOut addObject:domain];
        }
        *outSearchDomains = domainsOut;
    }

    res_ndestroy(&res);
    return serversOut;
}

// Fallback write into fakefs /etc/resolv.conf if bind-mounting /etc/clio-dns or symlinking fails.
// Reuses the validated resolv.conf already rendered by Swift (preserving .custom mode and search-domain filtering).
static void den_configure_dns_fallback(NSString * _Nullable dnsDir) {
    NSString *conf = nil;
    if (dnsDir.length > 0) {
        NSString *renderedPath = [dnsDir stringByAppendingPathComponent:@"resolv.conf"];
        conf = [NSString stringWithContentsOfFile:renderedPath encoding:NSUTF8StringEncoding error:nil];
    }
    if (conf.length == 0) {
        NSArray<NSString *> *servers = den_query_system_dns(NULL);
        NSMutableString *buf = [NSMutableString new];
        for (NSString *ns in servers)
            [buf appendFormat:@"nameserver %@\n", ns];
        if (buf.length == 0)
            [buf appendString:@"# Generated by Clio Den: waiting for system DNS\n"];
        conf = buf;
    }
    if (!den_write_file("/etc/resolv.conf", conf)) {
        denDNSFallbackError = @"写入 /etc/resolv.conf 回退配置失败";
    }
}

// MARK: Running

@interface DenRun : NSObject
@property (nonatomic) int pid;
@property (nonatomic) int outRead;
@property (nonatomic) int errRead;
@property (nonatomic) NSUInteger maxOutput;
@property (nonatomic, copy, nullable) DenLine onLine;
@property (nonatomic, copy) DenDone done;
@property (nonatomic) NSMutableString *output;
@property (nonatomic) NSMutableString *errorOutput;
@property (atomic) BOOL finished;
@property (atomic) int readersLeft;
@property (atomic) BOOL exited;
@property (atomic) int code;
@end

@implementation DenRun
@end

@implementation DenKernel

static NSMutableDictionary<NSNumber *, DenRun *> *runs;
static dispatch_queue_t readers;

+ (void)initialize {
    if (self != [DenKernel class])
        return;
    runs = [NSMutableDictionary dictionary];
    readers = dispatch_queue_create("clio.den.readers", DISPATCH_QUEUE_CONCURRENT);
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(exited:) name:DenExited object:nil];
}

+ (BOOL)booted {
    return denBooted;
}

static NSString *den_posix_timezone(void) {
    NSInteger offsetSeconds = [[NSTimeZone localTimeZone] secondsFromGMT];
    if (offsetSeconds == 0)
        return @"UTC0";
    // POSIX TZ sign is inverted relative to ISO-8601 (UTC+8 => UTC-8).
    NSInteger posixSeconds = -offsetSeconds;
    NSString *sign = posixSeconds < 0 ? @"-" : @"+";
    NSInteger absSeconds = labs(posixSeconds);
    NSInteger hours = absSeconds / 3600;
    NSInteger minutes = (absSeconds % 3600) / 60;
    if (minutes > 0)
        return [NSString stringWithFormat:@"UTC%@%ld:%02ld", sign, (long)hours, (long)minutes];
    return [NSString stringWithFormat:@"UTC%@%ld", sign, (long)hours];
}

static NSMutableData *den_build_envp(NSDictionary<NSString *, NSString *> * _Nullable customEnv, BOOL interactive) {
    NSMutableDictionary<NSString *, NSString *> *env = [@{
        @"HOME": @"/root",
        @"TERM": @"xterm-256color",
        @"LANG": @"C.UTF-8",
        @"CHARSET": @"UTF-8",
        @"PATH": @"/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/bin",
        @"ENV": @"/etc/profile",
        @"OPENSSL_armcap": @"0",
        @"GODEBUG": @"asyncpreemptoff=1",
        @"GOMAXPROCS": @"2",
        @"PYTHONMALLOC": @"malloc",
        @"PYTHONDONTWRITEBYTECODE": @"1",
        @"TZ": den_posix_timezone(),
    } mutableCopy];
    if (!interactive)
        env[@"NO_COLOR"] = @"1";
    if (customEnv) {
        for (NSString *key in customEnv) {
            NSString *val = customEnv[key];
            if (key.length == 0 || [key containsString:@"="] || val == nil)
                continue;
            env[key] = val;
        }
    }
    NSMutableData *envp = [NSMutableData data];
    for (NSString *key in env) {
        NSString *pair = [NSString stringWithFormat:@"%@=%@", key, env[key]];
        const char *utf8 = pair.UTF8String;
        if (utf8 != NULL)
            [envp appendBytes:utf8 length:strlen(utf8) + 1];
    }
    [envp appendBytes:"\0" length:1];
    return envp;
}

static NSString *den_configure_unix_socket_prefix(void) {
#if TARGET_OS_SIMULATOR
    return [NSString stringWithFormat:@"unix=sim(%s)", sock_tmp_prefix];
#else
    NSString *tempDir = NSTemporaryDirectory();
    // On real iOS devices NSTemporaryDirectory() starts with /private/var/mobile/...,
    // which pushes `sock_tmp_prefix + "<pid>.<id>"` to ~108 bytes — exceeding Darwin's
    // 104-byte sockaddr_un.sun_path limit where fs/sock.c performs an unchecked sprintf.
    // /var is a symlink to /private/var, trimming 8 bytes so the path fits safely.
    if ([tempDir hasPrefix:@"/private/"])
        tempDir = [tempDir substringFromIndex:strlen("/private")];
    NSString *prefix = [tempDir stringByAppendingString:@"densock"];
    const char *utf8 = prefix.UTF8String;
    const size_t maxSunPath = sizeof(((struct sockaddr_un *)0)->sun_path);
    const size_t suffixBudget = 12; // "<pid>.<id>" + NUL
    if (utf8 == NULL)
        return @"unix=invalid-utf8(default)";
    size_t prefixLen = strlen(utf8);
    if (prefixLen + suffixBudget >= maxSunPath) {
        NSLog(@"斗室: AF_UNIX prefix too long (%zu + %zu >= %zu), keeping default to prevent overflow",
              prefixLen, suffixBudget, maxSunPath);
        return [NSString stringWithFormat:@"unix=overflow-guard(%zu/%zu)", prefixLen, maxSunPath];
    }
    sock_tmp_prefix = strdup(utf8);
    return [NSString stringWithFormat:@"unix=ok(%zu/%zu)", prefixLen, maxSunPath];
#endif
}

+ (int)bootRoot:(NSString *)root desk:(NSString *)desk {
    return [self bootRoot:root desk:desk dnsDir:nil netDir:nil];
}

+ (int)bootRoot:(NSString *)root desk:(NSString *)desk dnsDir:(NSString *)dnsDir {
    return [self bootRoot:root desk:desk dnsDir:dnsDir netDir:nil];
}

+ (void)setForkRateLimit:(uint32_t)perSecond burst:(uint32_t)burst {
    ish_set_fork_rate_limit(perSecond, burst);
}

+ (NSArray<NSString *> *)systemDNSServers {
    return den_query_system_dns(NULL);
}

+ (NSArray<NSString *> *)systemSearchDomains {
    NSArray<NSString *> *domains = nil;
    den_query_system_dns(&domains);
    return domains ?: @[];
}

+ (nullable NSString *)lastDNSFallbackError {
    return denDNSFallbackError;
}

+ (NSString *)kernelNetworkStatus {
    return denKernelNetStatus;
}

+ (int)bootRoot:(NSString *)root desk:(NSString *)desk dnsDir:(NSString *)dnsDir netDir:(NSString *)netDir {
    if (denBooted)
        return 0;
    // Enable iSH's AF_NETLINK stub on the host process before any guest starts
    // so `ip route` / `ip addr` and Go netmon probes work instead of returning ENOTSUP.
    setenv("ISH_NETLINK_STUB", "1", 0);
    den_memory_start();

    NSString *data = [root stringByAppendingPathComponent:@"data"];
    int err = mount_root(&fakefs, data.fileSystemRepresentation);
    if (err < 0)
        return err;
    fakefs_set_rootfs_data_path(data.fileSystemRepresentation);
    err = become_first_process();
    if (err < 0)
        return err;

    // The Alpine tarball carries no /dev, /proc or /tmp; make them before anything goes in.
    generic_mkdirat(AT_PWD, "/dev", 0755);
    generic_mkdirat(AT_PWD, "/proc", 0755);
    generic_mkdirat(AT_PWD, "/tmp", 01777);
    generic_mkdirat(AT_PWD, "/run", 0755);
    generic_mknodat(AT_PWD, "/dev/tty", S_IFCHR | 0666, dev_make(TTY_ALTERNATE_MAJOR, DEV_TTY_MINOR));
    generic_mknodat(AT_PWD, "/dev/ptmx", S_IFCHR | 0666, dev_make(TTY_ALTERNATE_MAJOR, DEV_PTMX_MINOR));
    generic_mknodat(AT_PWD, "/dev/null", S_IFCHR | 0666, dev_make(MEM_MAJOR, DEV_NULL_MINOR));
    generic_mknodat(AT_PWD, "/dev/zero", S_IFCHR | 0666, dev_make(MEM_MAJOR, DEV_ZERO_MINOR));
    generic_mknodat(AT_PWD, "/dev/full", S_IFCHR | 0666, dev_make(MEM_MAJOR, DEV_FULL_MINOR));
    generic_mknodat(AT_PWD, "/dev/random", S_IFCHR | 0666, dev_make(MEM_MAJOR, DEV_RANDOM_MINOR));
    generic_mknodat(AT_PWD, "/dev/urandom", S_IFCHR | 0666, dev_make(MEM_MAJOR, DEV_URANDOM_MINOR));
    generic_mkdirat(AT_PWD, "/dev/pts", 0755);
    generic_setattrat(AT_PWD, "/", (struct attr) {.type = attr_mode, .mode = 0755}, false);
    do_mount(&procfs, "proc", "/proc", "", 0);
    do_mount(&devptsfs, "devpts", "/dev/pts", "", 0);

    if (desk.length > 0) {
        generic_mkdirat(AT_PWD, "/root", 0700);
        fakefs_bind_mount("/root/desk", desk.fileSystemRepresentation, false);
    }

    denDNSFallbackError = nil;
    if (dnsDir.length > 0) {
        generic_mkdirat(AT_PWD, "/etc", 0755);
        generic_mkdirat(AT_PWD, "/etc/clio-dns", 0555);
        int bindErr = fakefs_bind_mount("/etc/clio-dns", dnsDir.fileSystemRepresentation, true);
        int linkErr = -1;
        if (bindErr >= 0) {
            generic_unlinkat(AT_PWD, "/etc/resolv.conf");
            linkErr = generic_symlinkat("/etc/clio-dns/resolv.conf", AT_PWD, "/etc/resolv.conf");
        }
        if (bindErr < 0 || linkErr < 0)
            den_configure_dns_fallback(dnsDir);
    } else {
        den_configure_dns_fallback(nil);
    }

    if (netDir.length > 0) {
        generic_mkdirat(AT_PWD, "/etc", 0755);
        generic_mkdirat(AT_PWD, "/etc/clio-net", 0555);
        int netBindErr = fakefs_bind_mount("/etc/clio-net", netDir.fileSystemRepresentation, true);
        if (netBindErr >= 0) {
            generic_mkdirat(AT_PWD, "/etc/ssh", 0755);
            generic_mkdirat(AT_PWD, "/etc/ssh/ssh_config.d", 0755);
            generic_unlinkat(AT_PWD, "/etc/ssh/ssh_config.d/90-clio-net.conf");
            generic_symlinkat("/etc/clio-net/ssh_config", AT_PWD, "/etc/ssh/ssh_config.d/90-clio-net.conf");
        }
    }
    den_write_file("/etc/motd", @"");

    exit_hook = den_exit;
    die_handler = den_die;
    NSString *sockStatus = den_configure_unix_socket_prefix();
    denKernelNetStatus = [NSString stringWithFormat:@"netlink=%s, %@", getenv("ISH_NETLINK_STUB") ?: "unset", sockStatus];

    // init: a shell that only sleeps, so commands have a parent.
    struct task *init = current;
    init->files->files[0] = den_null_fd(O_RDONLY);
    init->files->files[1] = den_null_fd(O_WRONLY);
    init->files->files[2] = den_null_fd(O_WRONLY);
    const char argv[] = "/bin/sh\0-c\0while :; do sleep 3600; done\0";
    NSMutableData *initEnv = den_build_envp(nil, NO);
    err = do_execve("/bin/sh", 3, argv, initEnv.bytes);
    if (err < 0)
        return err;
    err = task_start(init);
    if (err < 0)
        return err;
    denBooted = YES;
    return 0;
}

+ (int)run:(NSString *)command environment:(NSDictionary<NSString *, NSString *> *)environment onLine:(DenLine)onLine done:(DenDone)done {
    return [self run:command environment:environment maxOutput:400000 onLine:onLine done:done];
}

+ (int)run:(NSString *)command environment:(NSDictionary<NSString *, NSString *> *)environment maxOutput:(NSUInteger)maxOutput onLine:(DenLine)onLine done:(DenDone)done {
    if (!denBooted)
        return -1;

    NSArray<NSString *> *arguments = @[@"/bin/sh", @"-c", command];
    NSMutableData *argv = [NSMutableData data];
    for (NSString *argument in arguments)
        [argv appendBytes:argument.UTF8String length:strlen(argument.UTF8String) + 1];
    [argv appendBytes:"\0" length:1];
    if (argv.length > 60000)
        return -7; // E2BIG

    NSMutableData *envp = den_build_envp(environment, NO);

    int outPipe[2], errPipe[2];
    if (pipe(outPipe) < 0)
        return -1;
    if (pipe(errPipe) < 0) {
        close(outPipe[0]);
        close(outPipe[1]);
        return -1;
    }
    fcntl(outPipe[0], F_SETFL, O_NONBLOCK);
    fcntl(errPipe[0], F_SETFL, O_NONBLOCK);

    struct task *saved = current;
    int err = become_new_init_child();
    if (err < 0) {
        current = saved;
        close(outPipe[0]); close(outPipe[1]); close(errPipe[0]); close(errPipe[1]);
        return err;
    }
    struct task *task = current;
    // Isolate each command in its own process group (pgid == task->pid, never init's pgid 1)
    // so cancelling or timing out terminates spawned children too.
    sys_setpgid(0, 0);
    struct fd *inFd = den_null_fd(O_RDONLY);
    struct fd *outFd = den_host_fd(outPipe[1]);
    struct fd *errFd = den_host_fd(errPipe[1]);
    task->files->files[0] = inFd;
    task->files->files[1] = outFd;
    task->files->files[2] = errFd;
    if (outFd == NULL)
        close(outPipe[1]);
    if (errFd == NULL)
        close(errPipe[1]);
    if (inFd == NULL || outFd == NULL || errFd == NULL) {
        current = saved;
        den_discard_unstarted_task(task);
        close(outPipe[0]);
        close(errPipe[0]);
        return -12; // ENOMEM
    }

    err = do_execve("/bin/sh", arguments.count, argv.bytes, envp.bytes);
    if (err < 0) {
        current = saved;
        den_discard_unstarted_task(task);
        close(outPipe[0]); close(errPipe[0]);
        return err;
    }

    DenRun *run = [DenRun new];
    run.pid = task->pid;
    run.outRead = outPipe[0];
    run.errRead = errPipe[0];
    run.maxOutput = maxOutput > 0 ? maxOutput : 400000;
    run.onLine = onLine;
    run.done = done;
    run.output = [NSMutableString string];
    run.errorOutput = [NSMutableString string];
    run.readersLeft = 2;
    @synchronized (runs) {
        runs[@(run.pid)] = run;
    }
    err = task_start(task);
    current = saved;
    if (err < 0) {
        @synchronized (runs) {
            [runs removeObjectForKey:@(run.pid)];
        }
        den_discard_unstarted_task(task);
        close(outPipe[0]); close(errPipe[0]);
        return err;
    }

    [self read:run error:NO];
    [self read:run error:YES];
    return run.pid;
}

+ (void)read:(DenRun *)run error:(BOOL)isError {
    dispatch_async(readers, ^{
        int fd = isError ? run.errRead : run.outRead;
        NSMutableData *pending = [NSMutableData data];
        char buffer[8192];
        for (;;) {
            if (run.finished)
                break;
            ssize_t got = read(fd, buffer, sizeof(buffer));
            if (got > 0) {
                [pending appendBytes:buffer length:got];
                [self flush:pending run:run error:isError final:NO];
                // Cap an unbounded non-newline stream at 256 KB to prevent OOM.
                if (pending.length >= 262144)
                    [self flush:pending run:run error:isError final:YES];
            } else if (got == 0) {
                break;
            } else if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
                if (run.finished)
                    break;
                // After the process is gone, give its last words a moment, then stop.
                if (run.exited) {
                    usleep(150000);
                    if (run.finished)
                        break;
                    ssize_t last = read(fd, buffer, sizeof(buffer));
                    if (last > 0) {
                        [pending appendBytes:buffer length:last];
                        continue;
                    }
                    break;
                }
                usleep(10000);
            } else {
                break;
            }
        }
        if (!run.finished)
            [self flush:pending run:run error:isError final:YES];
        close(fd);
        @synchronized (run) {
            run.readersLeft -= 1;
        }
        [self finishIfDone:run];
    });
}

/// Hands complete lines over; keeps a partial line until more arrives.
+ (void)flush:(NSMutableData *)pending run:(DenRun *)run error:(BOOL)isError final:(BOOL)final {
    const char *bytes = pending.bytes;
    NSUInteger start = 0;
    for (NSUInteger i = 0; i < pending.length; i++) {
        if (bytes[i] == '\n') {
            [self emit:[NSData dataWithBytes:bytes + start length:i - start] run:run error:isError];
            start = i + 1;
        }
    }
    if (final && start < pending.length) {
        [self emit:[NSData dataWithBytes:bytes + start length:pending.length - start] run:run error:isError];
        start = pending.length;
    }
    [pending replaceBytesInRange:NSMakeRange(0, start) withBytes:NULL length:0];
}

+ (void)emit:(NSData *)data run:(DenRun *)run error:(BOOL)isError {
    if (run.finished)
        return;
    NSString *line = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
        ?: [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding] ?: @"";
    NSMutableString *into = isError ? run.errorOutput : run.output;
    @synchronized (into) {
        if (into.length < run.maxOutput) {
            [into appendString:line];
            [into appendString:@"\n"];
        }
    }
    DenLine onLine = run.onLine;
    if (onLine)
        onLine(line, isError);
}

+ (void)exited:(NSNotification *)note {
    int pid = [note.userInfo[@"pid"] intValue];
    DenRun *run;
    @synchronized (runs) {
        run = runs[@(pid)];
    }
    if (!run)
        return;
    run.code = [note.userInfo[@"code"] intValue];
    run.exited = YES;
    // Background jobs can keep the pipes open; don't wait on them forever.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), readers, ^{
        @synchronized (run) {
            run.readersLeft = 0;
        }
        [self finishIfDone:run];
    });
    [self finishIfDone:run];
}

+ (void)finishIfDone:(DenRun *)run {
    @synchronized (run) {
        if (run.finished || !run.exited || run.readersLeft > 0)
            return;
        run.finished = YES;
    }
    @synchronized (runs) {
        [runs removeObjectForKey:@(run.pid)];
    }
    int raw = run.code;
    // The kernel reports a wait status: exit code in the high byte, or a signal in the low bits.
    int code = (raw & 0x7f) ? 128 + (raw & 0x7f) : (raw >> 8) & 0xff;
    NSString *output, *errorOutput;
    @synchronized (run.output) { output = [run.output copy]; }
    @synchronized (run.errorOutput) { errorOutput = [run.errorOutput copy]; }
    DenDone done = run.done;
    dispatch_async(dispatch_get_main_queue(), ^{ done(code, output, errorOutput); });
}

+ (BOOL)kill:(int)pid {
    if (pid <= 1)
        return NO;
    struct siginfo_ info = SIGINFO_NIL;
    pid_t_ pgid = 0;
    lock(&pids_lock);
    struct task *task = pid_get_task((dword_t) pid);
    if (task) {
        if (task->group != NULL && task->group->pgid > 1 && task->group->pgid == task->pid)
            pgid = task->group->pgid;
        send_signal(task, SIGKILL_, info);
    }
    unlock(&pids_lock);
    // Kill the isolated command's entire process group (children spawned by /bin/sh -c),
    // never init's pgid 1.
    if (pgid > 1) {
        send_group_signal(pgid, SIGKILL_, info);
    } else if (task == NULL) {
        // Parent shell may already have exited while children remain in pgid == pid.
        if (send_group_signal((dword_t) pid, SIGKILL_, info) == 0)
            return YES;
    }
    return task != NULL || pgid > 1;
}

@end


// MARK: 笔砚 — a pseudo-terminal whose screen is a view in the app

@interface DenTerminal ()
- (void)releaseTTY;
@property (nonatomic, copy) void (^output)(NSData *);
@property (nonatomic, copy) void (^exited)(void);
@property (nonatomic) struct tty *tty;
@property (nonatomic) int pid;
@property (atomic) BOOL gone;
@end

static int den_tty_init(struct tty *tty) {
    return 0;
}

static int den_tty_write(struct tty *tty, const void *buf, size_t len, bool blocking) {
    void *owner = tty->data;
    if (owner == NULL)
        return (int) len;
    DenTerminal *terminal = (__bridge DenTerminal *) owner;
    NSData *data = [NSData dataWithBytes:buf length:len];
    void (^output)(NSData *) = terminal.output;
    if (output)
        dispatch_async(dispatch_get_main_queue(), ^{ output(data); });
    return (int) len;
}

static void den_tty_cleanup(struct tty *tty) {
    // Runs when the last reference goes, which is after the terminal let go of its own: it no longer points here.
    if (tty->data != NULL)
        CFBridgingRelease(tty->data);
    tty->data = NULL;
}

static struct tty_driver_ops den_tty_ops = {
    .init = den_tty_init,
    .write = den_tty_write,
    .cleanup = den_tty_cleanup,
};
static struct tty_driver den_pty_driver = {.ops = &den_tty_ops};

@implementation DenTerminal

+ (instancetype)openWithOutput:(void (^)(NSData *))output exited:(void (^)(void))exited error:(int *)error {
    return [self openWithEnvironment:nil output:output exited:exited error:error];
}

+ (instancetype)openWithEnvironment:(NSDictionary<NSString *, NSString *> *)environment
                             output:(void (^)(NSData *))output
                             exited:(void (^)(void))exited
                              error:(int *)error {
    if (!denBooted) {
        if (error) *error = -1;
        return nil;
    }
    DenTerminal *terminal = [DenTerminal new];
    terminal.output = output;
    terminal.exited = exited;

    struct task *saved = current;
    int err = become_new_init_child();
    if (err < 0) {
        current = saved;
        if (error) *error = err;
        return nil;
    }
    struct task *task = current;
    struct tty *tty = pty_open_fake(&den_pty_driver);
    if (IS_ERR(tty)) {
        current = saved;
        den_discard_unstarted_task(task);
        if (error) *error = (int) PTR_ERR(tty);
        return nil;
    }
    tty->data = (void *) CFBridgingRetain(terminal);
    // The terminal keeps the reference it opened until the shell is gone: the screen may still type or resize
    // while the shell exits on another thread, and a released tty would be freed under it.
    terminal.tty = tty;
    NSString *stdioFile = [NSString stringWithFormat:@"/dev/pts/%d", tty->num];
    err = create_stdio(stdioFile.fileSystemRepresentation, TTY_PSEUDO_SLAVE_MAJOR, tty->num);
    if (err < 0) {
        current = saved;
        den_discard_unstarted_task(task);
        [terminal releaseTTY];
        if (error) *error = err;
        return nil;
    }

    const char argv[] = "/bin/sh\0-c\0cd /root 2>/dev/null; exec /bin/sh -l\0";
    NSMutableData *envp = den_build_envp(environment, YES);
    err = do_execve("/bin/sh", 3, argv, envp.bytes);
    if (err < 0) {
        current = saved;
        den_discard_unstarted_task(task);
        [terminal releaseTTY];
        if (error) *error = err;
        return nil;
    }
    terminal.pid = task->pid;
    [NSNotificationCenter.defaultCenter addObserver:terminal selector:@selector(processExited:) name:DenExited object:nil];
    err = task_start(task);
    current = saved;
    if (err < 0) {
        [NSNotificationCenter.defaultCenter removeObserver:terminal];
        den_discard_unstarted_task(task);
        [terminal releaseTTY];
        if (error) *error = err;
        return nil;
    }

    if (error) *error = 0;
    return terminal;
}

- (void)processExited:(NSNotification *)note {
    if ([note.userInfo[@"pid"] intValue] != self.pid || self.gone)
        return;
    self.gone = YES;
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [self releaseTTY];
    if (self.exited)
        self.exited();
}

/// Lets go of the terminal's own reference, once. Typing and resizing hold the same lock, so they never use a tty
/// that is being let go.
- (void)releaseTTY {
    @synchronized (self) {
        struct tty *tty = self.tty;
        if (tty == NULL)
            return;
        self.tty = NULL;
        lock(&ttys_lock);
        tty_release(tty);
        unlock(&ttys_lock);
    }
}

- (void)send:(NSData *)data {
    if (data.length == 0)
        return;
    @synchronized (self) {
        struct tty *tty = self.tty;
        if (tty == NULL || self.gone)
            return;
        tty_input(tty, data.bytes, data.length, 0);
    }
}

- (void)resizeColumns:(int)columns rows:(int)rows {
    if (columns <= 0 || rows <= 0)
        return;
    @synchronized (self) {
        struct tty *tty = self.tty;
        if (tty == NULL || self.gone)
            return;
        lock(&tty->lock);
        tty_set_winsize(tty, (struct winsize_) {.col = (word_t) columns, .row = (word_t) rows});
        unlock(&tty->lock);
    }
}

- (void)close {
    if (!self.gone)
        [DenKernel kill:self.pid];
}

@end
