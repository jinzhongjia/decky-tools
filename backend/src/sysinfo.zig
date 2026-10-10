//! 系统信息:主机名、系统版本、内核、机型、CPU 型号、推荐 IP。按需查询,不常驻。
//! 不读取 MAC、序列号、SSID 等可识别个人/设备的信息。
const std = @import("std");
const src = @import("source.zig");
const json = @import("json.zig");
const netinfo = @import("netinfo.zig");

pub fn write(w: *std.Io.Writer) !void {
    var first = true;
    try w.writeByte('{');
    var buf: [256]u8 = undefined;
    try json.optStr(w, &first, "hostname", src.text("/proc/sys/kernel/hostname", &buf) orelse "");
    try json.optStr(w, &first, "kernel", src.text("/proc/sys/kernel/osrelease", &buf) orelse "");
    try json.optStr(w, &first, "product", src.text("/sys/class/dmi/id/product_name", &buf) orelse "");

    var big: [16384]u8 = undefined;
    const release = src.text("/etc/os-release", &big) orelse "";
    try json.optStr(w, &first, "os", field(release, "PRETTY_NAME") orelse "");
    try json.optStr(w, &first, "os_build", field(release, "BUILD_ID") orelse "");
    try json.optStr(w, &first, "cpu_model", cpuModel(src.text("/proc/cpuinfo", &big) orelse "") orelse "");

    // Table 约 3KB,放静态区避免占用栈
    const S = struct {
        var table: netinfo.Table = .{};
    };
    S.table = .{};
    if (S.table.load()) |_| {
        if (S.table.recommended()) |addr| {
            var ipbuf: [64]u8 = undefined;
            try json.optStr(w, &first, "ip", netinfo.format(&ipbuf, addr));
            if (S.table.findLink(addr.index)) |link| try json.optStr(w, &first, "interface", src.str(&link.name));
        }
    }
    try w.writeByte('}');
}

/// os-release 的 KEY=VALUE,要求完整键名匹配并去掉引号。
pub fn field(text: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len <= key.len or !std.mem.startsWith(u8, line, key) or line[key.len] != '=') continue;
        return std.mem.trim(u8, line[key.len + 1 ..], "\"' \r");
    }
    return null;
}

pub fn cpuModel(text: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const split = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.mem.eql(u8, std.mem.trim(u8, line[0..split], " \t"), "model name")) continue;
        const value = std.mem.trim(u8, line[split + 1 ..], " \t\r");
        return if (value.len > 0) value else null;
    }
    return null;
}

test "os-release parser matches complete keys" {
    try std.testing.expectEqualStrings("3.8", field("VERSION_ID=\"3.8\"\nBUILD_ID=2026", "VERSION_ID").?);
    try std.testing.expect(field("VERSION_ID=3.8", "VERSION") == null);
}

test "cpu model reads the exact key" {
    try std.testing.expectEqualStrings("AMD Custom APU", cpuModel("processor: 0\nmodel name\t: AMD Custom APU\n").?);
    try std.testing.expect(cpuModel("model: 1\n") == null);
}
