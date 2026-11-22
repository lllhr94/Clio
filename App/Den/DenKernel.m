// 斗室's bridge to the iSH kernel. Adapted from iSH's app/AppDelegate.m and
// app/ISHShellExecutor.m (ish-app/ish, OpenMinis/ish-arm64; GPL).

#import "DenKernel.h"
#include <resolv.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <fcntl.h>
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

static void den_write_file(const char *path, NSString *text) {
    struct fd *fd = generic_open(path, O_WRONLY_ | O_CREAT_ | O_TRUNC_, 0644);
    if (!IS_ERR(fd)) {
        fd->ops->write(fd, text.UTF8String, [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
        fd_close(fd);
    }
}

// The phone's DNS servers, written into /etc/resolv.conf so apk and curl can find hosts.
static void den_configure_dns(void) {
    struct __res_state res;
    if (res_ninit(&res) != 0)
        return;
    NSMutableString *conf = [NSMutableString new];
    union res_sockaddr_union servers[NI_MAXSERV];
    int found = res_getservers(&res, servers, NI_MAXSERV);
    char address[NI_MAXHOST];
    for (int i = 0; i < found; i++) {
        union res_sockaddr_union server = servers[i];
        if (server.sin.sin_len == 0)
            continue;
        getnameinfo((struct sockaddr *) &server.sin, server.sin.sin_len, address, sizeof(address), NULL, 0, NI_NUMERICHOST);
        [conf appendFormat:@"nameserver %s\n", address];
    }
    res_ndestroy(&res);
    if (conf.length == 0)
        [conf appendString:@"nameserver 223.5.5.5\nnameserver 1.1.1.1\n"];
    den_write_file("/etc/resolv.conf", conf);
}

// MARK: Running

@interface DenRun : NSObject
@property (nonatomic) int pid;
@property (nonatomic) int outRead;
@property (nonatomic) int errRead;
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

+ (int)bootRoot:(NSString *)root desk:(NSString *)desk {
    if (denBooted)
        return 0;
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

    den_configure_dns();
    den_write_file("/etc/motd", @"");

    exit_hook = den_exit;
    die_handler = den_die;
    sock_tmp_prefix = strdup([NSTemporaryDirectory() stringByAppendingString:@"densock"].UTF8String);

    // init: a shell that only sleeps, so commands have a parent.
    struct task *init = current;
    init->files->files[0] = den_null_fd(O_RDONLY);
    init->files->files[1] = den_null_fd(O_WRONLY);
    init->files->files[2] = den_null_fd(O_WRONLY);
    const char argv[] = "/bin/sh\0-c\0while :; do sleep 3600; done\0";
    const char envp[] = "HOME=/root\0PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\0";
    err = do_execve("/bin/sh", 3, argv, envp);
    if (err < 0)
        return err;
    task_start(init);
    denBooted = YES;
    return 0;
}

+ (int)run:(NSString *)command environment:(NSDictionary<NSString *, NSString *> *)environment onLine:(DenLine)onLine done:(DenDone)done {
    if (!denBooted)
        return -1;
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
    task->files->files[0] = den_null_fd(O_RDONLY);
    task->files->files[1] = den_host_fd(outPipe[1]);
    task->files->files[2] = den_host_fd(errPipe[1]);

    NSArray<NSString *> *arguments = @[@"/bin/sh", @"-c", command];
    NSMutableData *argv = [NSMutableData data];
    for (NSString *argument in arguments)
        [argv appendBytes:argument.UTF8String length:strlen(argument.UTF8String) + 1];
    [argv appendBytes:"\0" length:1];

    NSMutableDictionary<NSString *, NSString *> *env = [@{
        @"HOME": @"/root",
        @"TERM": @"xterm-256color",
        @"LANG": @"C.UTF-8",
        @"PATH": @"/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        @"PYTHONMALLOC": @"malloc",
    } mutableCopy];
    if (environment)
        [env addEntriesFromDictionary:environment];
    NSMutableData *envp = [NSMutableData data];
    for (NSString *key in env) {
        NSString *pair = [NSString stringWithFormat:@"%@=%@", key, env[key]];
        [envp appendBytes:pair.UTF8String length:strlen(pair.UTF8String) + 1];
    }
    [envp appendBytes:"\0" length:1];

    if (argv.length > 60000) {
        current = saved;
        close(outPipe[0]); close(errPipe[0]);
        return -7; // E2BIG
    }
    err = do_execve("/bin/sh", arguments.count, argv.bytes, envp.bytes);
    if (err < 0) {
        current = saved;
        close(outPipe[0]); close(errPipe[0]);
        return err;
    }

    DenRun *run = [DenRun new];
    run.pid = task->pid;
    run.outRead = outPipe[0];
    run.errRead = errPipe[0];
    run.onLine = onLine;
    run.done = done;
    run.output = [NSMutableString string];
    run.errorOutput = [NSMutableString string];
    run.readersLeft = 2;
    @synchronized (runs) {
        runs[@(run.pid)] = run;
    }
    task_start(task);
    current = saved;

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
            ssize_t got = read(fd, buffer, sizeof(buffer));
            if (got > 0) {
                [pending appendBytes:buffer length:got];
                [self flush:pending run:run error:isError final:NO];
            } else if (got == 0) {
                break;
            } else if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
                // After the process is gone, give its last words a moment, then stop.
                if (run.exited) {
                    usleep(150000);
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
    NSString *line = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
        ?: [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding] ?: @"";
    NSMutableString *into = isError ? run.errorOutput : run.output;
    @synchronized (into) {
        if (into.length < 400000) {
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
    struct siginfo_ info = SIGINFO_NIL;
    lock(&pids_lock);
    struct task *task = pid_get_task((dword_t) pid);
    if (task)
        send_signal(task, SIGKILL_, info);
    unlock(&pids_lock);
    return task != NULL;
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
    struct tty *tty = pty_open_fake(&den_pty_driver);
    if (IS_ERR(tty)) {
        current = saved;
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
        [terminal releaseTTY];
        if (error) *error = err;
        return nil;
    }

    const char argv[] = "/bin/sh\0-c\0cd /root 2>/dev/null; exec /bin/sh -l\0";
    const char envp[] = "TERM=xterm-256color\0HOME=/root\0LANG=C.UTF-8\0PYTHONMALLOC=malloc\0PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\0";
    err = do_execve("/bin/sh", 3, argv, envp);
    if (err < 0) {
        current = saved;
        [terminal releaseTTY];
        if (error) *error = err;
        return nil;
    }
    terminal.pid = current->pid;
    task_start(current);
    current = saved;

    [NSNotificationCenter.defaultCenter addObserver:terminal selector:@selector(processExited:) name:DenExited object:nil];
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
