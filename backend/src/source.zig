//! sysfs / procfs 读取小工具:常驻 fd + pread 复读,避免每次采样重新 open。
const std = @import("std");
const sys = @import("sys.zig");

/// 复制成以 0 结尾的路径(syscall 需要);放不下返回 null。
fn zpath(buf: []u8, path: []const u8) ?[:0]const u8 {
    if (path.len >= buf.len) return null;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return buf[0..path.len :0];
}

pub fn open(path: []const u8) !i32 {
    var buf: [512]u8 = undefined;
    return sys.open(zpath(&buf, path) orelse return error.PathTooLong);
}

/// 一次性读取小文件并去掉首尾空白。
pub fn text(path: []const u8, buf: []u8) ?[]const u8 {
    const fd = open(path) catch return null;
    defer sys.close(fd);
    const n = sys.pread(fd, buf, 0) catch return null;
    return std.mem.trim(u8, buf[0..n], " \t\r\n");
}

pub fn integer(s: []const u8) ?i64 {
    return std.fmt.parseInt(i64, s, 10) catch null;
}

pub const Value = struct {
    fd: i32 = -1,
    pub fn init(path: []const u8) Value {
        return .{ .fd = open(path) catch -1 };
    }
    pub fn ok(self: Value) bool {
        return self.fd >= 0;
    }
    pub fn close(self: *Value) void {
        if (self.fd >= 0) sys.close(self.fd);
        self.fd = -1;
    }
    pub fn read(self: Value, buf: []u8) ?[]const u8 {
        if (self.fd < 0) return null;
        const n = sys.pread(self.fd, buf, 0) catch return null;
        if (n == 0) return null;
        return std.mem.trim(u8, buf[0..n], " \t\r\n");
    }
    pub fn int(self: Value) ?i64 {
        var buf: [64]u8 = undefined;
        return integer(self.read(&buf) orelse return null);
    }
};

/// 原样读取(不去空白,用于二进制文件);失败或为空返回 null。
pub fn pread(v: Value, buf: []u8) ?usize {
    if (v.fd < 0) return null;
    const n = sys.pread(v.fd, buf, 0) catch return null;
    return if (n == 0) null else n;
}

pub fn dir(path: []const u8) !sys.DirIter {
    var buf: [512]u8 = undefined;
    return sys.DirIter.open(zpath(&buf, path) orelse return error.PathTooLong);
}

pub fn join(buf: []u8, comptime fmt: []const u8, args: anytype) ?[]const u8 {
    return std.mem.print(buf, fmt, args) catch null;
}

/// 把 value 截断复制进定长缓冲区(以 0 结尾),配合 str() 取回切片。
pub fn copy(dest: []u8, value: []const u8) void {
    @memset(dest, 0);
    const n = @min(dest.len - 1, value.len);
    @memcpy(dest[0..n], value[0..n]);
}

pub fn str(bytes: []const u8) []const u8 {
    return bytes[0 .. std.mem.indexOfScalar(u8, bytes, 0) orelse bytes.len];
}
