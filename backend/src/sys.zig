//! sys.zig — 直接基于 std.os.linux 原始 syscall 的薄封装(Zig 0.17,无 libc)。
//! 源自 decky-scope monitor;只保留本项目用到的部分,不依赖仍在演进的 std.Io。
const std = @import("std");
const linux = std.os.linux;

pub const fd_t = linux.fd_t;

pub const Error = error{ Sys, Again, Closed };

fn check(rc: usize) Error!usize {
    return switch (linux.errno(rc)) {
        .SUCCESS => rc,
        .AGAIN => error.Again,
        else => error.Sys,
    };
}

// ---- 文件 ----

pub fn open(path: [:0]const u8) Error!fd_t {
    const rc = try check(linux.openat(linux.AT.FDCWD, path.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0));
    return @intCast(rc);
}

pub fn pread(fd: fd_t, buf: []u8, offset: i64) Error!usize {
    return try check(linux.pread(fd, buf.ptr, buf.len, offset));
}

pub fn read(fd: fd_t, buf: []u8) Error!usize {
    while (true) {
        const rc = linux.read(fd, buf.ptr, buf.len);
        if (linux.errno(rc) == .INTR) continue;
        return check(rc);
    }
}

/// 单次 write;返回实际写入字节数(非阻塞 fd 可能部分写入或 Again)。
pub fn write(fd: fd_t, data: []const u8) Error!usize {
    while (true) {
        const rc = linux.write(fd, data.ptr, data.len);
        if (linux.errno(rc) == .INTR) continue;
        return check(rc);
    }
}

pub fn writeAll(fd: fd_t, data: []const u8) Error!void {
    var off: usize = 0;
    while (off < data.len) {
        const n = try write(fd, data[off..]);
        if (n == 0) return error.Closed;
        off += n;
    }
}

pub fn close(fd: fd_t) void {
    _ = linux.close(fd);
}

pub fn setNonblock(fd: fd_t) void {
    const flags = linux.fcntl(fd, linux.F.GETFL, 0);
    if (linux.errno(flags) != .SUCCESS) return;
    const nonblock: u32 = @bitCast(linux.O{ .NONBLOCK = true });
    _ = linux.fcntl(fd, linux.F.SETFL, flags | nonblock);
}

// ---- 目录遍历(getdents64,用于 hwmon/power_supply 探测) ----

pub const DirIter = struct {
    fd: fd_t,
    buf: [4096]u8 = undefined,
    len: usize = 0,
    pos: usize = 0,

    pub fn open(path: [:0]const u8) Error!DirIter {
        const rc = try check(linux.openat(linux.AT.FDCWD, path.ptr, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0));
        return .{ .fd = @intCast(rc) };
    }

    pub fn next(self: *DirIter) ?[]const u8 {
        while (true) {
            if (self.pos >= self.len) {
                const rc = linux.getdents64(self.fd, &self.buf, self.buf.len);
                if (linux.errno(rc) != .SUCCESS or rc == 0) return null;
                self.len = rc;
                self.pos = 0;
            }
            const ent: *align(1) linux.dirent64 = @ptrCast(self.buf[self.pos..].ptr);
            self.pos += ent.reclen;
            const name_ptr: [*:0]const u8 = @ptrCast(@as([*]const u8, @ptrCast(ent)) + @offsetOf(linux.dirent64, "name"));
            const name = std.mem.span(name_ptr);
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            return name;
        }
    }

    pub fn deinit(self: *DirIter) void {
        close(self.fd);
    }
};

// ---- 时间(vDSO,不进内核) ----

fn ms(clock: linux.clockid_t) u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(clock, &ts);
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000;
}

/// 不含睡眠时间:用于调度下一次采样。
pub fn monoMs() u64 {
    return ms(.MONOTONIC);
}

/// 含睡眠时间:用于给采样定位时间轴,睡眠期间自然形成空档。
pub fn bootMs() u64 {
    return ms(.BOOTTIME);
}

// ---- epoll ----

pub const EpollEvent = linux.epoll_event;
pub const IN = linux.EPOLL.IN;
pub const OUT = linux.EPOLL.OUT;
pub const HUP = linux.EPOLL.HUP | linux.EPOLL.ERR | linux.EPOLL.RDHUP;

pub fn epollCreate() Error!fd_t {
    return @intCast(try check(linux.epoll_create1(linux.EPOLL.CLOEXEC)));
}

fn epollCtl(efd: fd_t, op: u32, fd: fd_t, tag: u32, events: u32) Error!void {
    var ev = linux.epoll_event{ .events = events, .data = .{ .u32 = tag } };
    _ = try check(linux.epoll_ctl(efd, op, fd, &ev));
}

pub fn epollAdd(efd: fd_t, fd: fd_t, tag: u32, events: u32) Error!void {
    try epollCtl(efd, linux.EPOLL.CTL_ADD, fd, tag, events);
}

pub fn epollMod(efd: fd_t, fd: fd_t, tag: u32, events: u32) Error!void {
    try epollCtl(efd, linux.EPOLL.CTL_MOD, fd, tag, events);
}

/// 等待事件或超时;超时值受进程 timer slack 影响,内核可把唤醒与其它定时器合并。
pub fn epollWait(efd: fd_t, events: []linux.epoll_event, timeout_ms: i32) Error!usize {
    const rc = linux.epoll_wait(efd, events.ptr, @intCast(events.len), timeout_ms);
    if (linux.errno(rc) == .INTR) return 0;
    return check(rc);
}

// ---- 调度提示 ----

/// 后台采样不应干扰游戏:SCHED_BATCH(被唤醒时不抢占正在运行的任务)+ nice 10;
/// 定时器松弛允许内核把本进程的唤醒推迟最多 slack_ns,与其它唤醒合并以省电。失败均忽略。
pub fn backgroundPriority(slack_ns: u64) void {
    _ = linux.prctl(@backingInt(linux.PR.SET_TIMERSLACK), slack_ns, 0, 0, 0);
    const attr = linux.sched_attr{ .policy = 3, .nice = 10 }; // 3 = SCHED_BATCH
    _ = linux.sched_setattr(0, &attr, 0);
}

// ---- netlink ----

/// 内核 uevent(NETLINK_KOBJECT_UEVENT,组 1):电源插拔、电池状态变化时由内核推送。
pub fn ueventSocket() Error!fd_t {
    const fd: fd_t = @intCast(try check(linux.socket(linux.AF.NETLINK, linux.SOCK.RAW | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK, linux.NETLINK.KOBJECT_UEVENT)));
    errdefer close(fd);
    const address = linux.sockaddr.nl{ .pid = 0, .groups = 1 };
    _ = try check(linux.bind(fd, @ptrCast(&address), @sizeOf(linux.sockaddr.nl)));
    return fd;
}

/// 同步 rtnetlink dump,用于查询 IP(只在按需查询系统信息时使用)。
pub fn routeSocket() Error!fd_t {
    const fd: fd_t = @intCast(try check(linux.socket(linux.AF.NETLINK, linux.SOCK.RAW | linux.SOCK.CLOEXEC, 0)));
    errdefer close(fd);
    // 内核 dump 总会应答;超时只是兜底,避免异常时阻塞事件循环
    const timeout = linux.timeval{ .sec = 1, .usec = 0 };
    _ = try check(linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.RCVTIMEO, std.mem.asBytes(&timeout), @sizeOf(linux.timeval)));
    const address = linux.sockaddr.nl{ .pid = 0, .groups = 0 };
    _ = try check(linux.bind(fd, @ptrCast(&address), @sizeOf(linux.sockaddr.nl)));
    return fd;
}

pub fn routeDump(fd: fd_t, kind: u16, seq: u32) Error!void {
    var b: [32]u8 = @splat(0);
    const len: u32 = if (kind == 18) 32 else if (kind == 22) 24 else 28;
    std.mem.writeInt(u32, b[0..4], len, .little);
    std.mem.writeInt(u16, b[4..6], kind, .little);
    std.mem.writeInt(u16, b[6..8], 0x301, .little); // NLM_F_REQUEST | NLM_F_DUMP
    std.mem.writeInt(u32, b[8..12], seq, .little);
    const address = linux.sockaddr.nl{ .pid = 0, .groups = 0 };
    _ = try check(linux.sendto(fd, &b, len, 0, @ptrCast(&address), @sizeOf(linux.sockaddr.nl)));
}

/// recv;非阻塞 socket 无数据时返回 error.Again。
pub fn recv(fd: fd_t, buf: []u8) Error!usize {
    while (true) {
        const rc = linux.recvfrom(fd, buf.ptr, buf.len, 0, null, null);
        if (linux.errno(rc) == .INTR) continue;
        return check(rc);
    }
}
