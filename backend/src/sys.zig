//! sys.zig — 直接基于 std.os.linux 原始 syscall 的薄封装（Zig 0.16，无 libc）。
//! 源自 decky-scope monitor;只保留本项目用到的部分,不依赖仍在演进的 std.Io。
const std = @import("std");
const linux = std.os.linux;

pub const fd_t = linux.fd_t;

pub const Error = error{ Sys, Again, Closed };

fn check(rc: usize) Error!usize {
    if (linux.errno(rc) == .AGAIN) return error.Again;
    if (linux.errno(rc) != .SUCCESS) return error.Sys;
    return rc;
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
    return try check(linux.read(fd, buf.ptr, buf.len));
}

pub fn write(fd: fd_t, data: []const u8) Error!usize {
    return try check(linux.write(fd, data.ptr, data.len));
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

// ---- 目录遍历（getdents64，用于 hwmon/power_supply 探测） ----

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

// ---- 时间 ----

pub fn nowMs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000;
}

/// 含睡眠时间的单调时钟:睡眠期间时间照走,历史里体现为空档。
pub fn bootMs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.BOOTTIME, &ts);
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000;
}

pub fn nowUs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000 + @as(u64, @intCast(ts.nsec)) / 1000;
}

// ---- timerfd ----

pub fn timerfdCreate() Error!fd_t {
    const rc = try check(linux.timerfd_create(.MONOTONIC, .{ .CLOEXEC = true }));
    return @intCast(rc);
}

pub fn timerfdSet(tfd: fd_t, interval_ms: u32) Error!void {
    const sec: isize = interval_ms / 1000;
    const nsec: isize = @as(isize, interval_ms % 1000) * 1_000_000;
    const spec = linux.itimerspec{
        .it_interval = .{ .sec = sec, .nsec = nsec },
        .it_value = .{ .sec = sec, .nsec = nsec },
    };
    _ = try check(linux.timerfd_settime(tfd, .{}, &spec, null));
}

pub fn timerfdDrain(tfd: fd_t) void {
    var b: [8]u8 = undefined;
    _ = linux.read(tfd, &b, 8);
}

// ---- epoll ----

pub const EpollEvent = linux.epoll_event;

pub fn epollCreate() Error!fd_t {
    const rc = try check(linux.epoll_create1(linux.EPOLL.CLOEXEC));
    return @intCast(rc);
}

pub fn epollAdd(efd: fd_t, fd: fd_t, tag: u32) Error!void {
    var ev = linux.epoll_event{
        .events = linux.EPOLL.IN | linux.EPOLL.RDHUP | linux.EPOLL.HUP,
        .data = .{ .u32 = tag },
    };
    _ = try check(linux.epoll_ctl(efd, linux.EPOLL.CTL_ADD, fd, &ev));
}

pub fn epollWait(efd: fd_t, events: []linux.epoll_event) usize {
    while (true) {
        const rc = linux.epoll_wait(efd, events.ptr, @intCast(events.len), -1);
        if (linux.errno(rc) == .INTR) continue;
        if (linux.errno(rc) != .SUCCESS) return 0;
        return rc;
    }
}

// ---- netlink(同步 dump,用于查询 IP) ----

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

pub fn recv(fd: fd_t, buf: []u8) Error!usize {
    while (true) {
        const rc = linux.recvfrom(fd, buf.ptr, buf.len, 0, null, null);
        if (linux.errno(rc) == .INTR) continue;
        return check(rc);
    }
}
