//! 一次采样 = CPU 占用(/proc/stat 差分)+ 内存(/proc/meminfo)+ 传感器 + 电池。
//! /proc 文件每次读取都由内核完整生成(stat 约 60 µs、meminfo 约 27 µs),只取开头几行,
//! 因此用小缓冲区读,避免把整份内容拷进用户态。
const std = @import("std");
const src = @import("source.zig");
const model = @import("model.zig");
const Sensors = @import("sensors.zig").Sensors;
const Battery = @import("battery.zig").Battery;

pub const Cpu = struct { total: u64, idle: u64 };

pub const Sampler = struct {
    stat: src.Value,
    meminfo: src.Value,
    sensors: Sensors,
    battery: Battery,
    prev: ?Cpu = null,

    pub fn init(uevents: bool) Sampler {
        return .{
            .stat = src.Value.init("/proc/stat"),
            .meminfo = src.Value.init("/proc/meminfo"),
            .sensors = Sensors.init(),
            .battery = Battery.init(uevents),
        };
    }

    pub fn deinit(self: *Sampler) void {
        self.stat.close();
        self.meminfo.close();
        self.sensors.deinit();
        self.battery.deinit();
    }

    pub fn sample(self: *Sampler) model.Sample {
        var s = model.Sample{};
        self.cpu(&s);
        var buf: [256]u8 = undefined; // MemTotal / MemFree / MemAvailable 位于前三行
        if (self.meminfo.read(&buf)) |text| parseMeminfo(text, &s);
        self.sensors.read(&s);
        self.battery.read(&s);
        return s;
    }

    fn cpu(self: *Sampler, s: *model.Sample) void {
        var buf: [256]u8 = undefined; // 只需要首行汇总 "cpu ..."
        const text = self.stat.read(&buf) orelse {
            self.prev = null;
            return;
        };
        const line = text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len];
        const cur = parseCpu(line) orelse {
            self.prev = null;
            return;
        };
        s.cpu_x10 = usage(self.prev, cur);
        self.prev = cur;
    }
};

/// 解析 /proc/stat 的汇总 "cpu " 行;guest/guest_nice 已含在 user/nice 中,只取前 8 列。
/// idle 与 iowait 都算空闲(与 top / MangoHud 口径一致)。
pub fn parseCpu(line: []const u8) ?Cpu {
    if (!std.mem.startsWith(u8, line, "cpu ")) return null;
    var it = std.mem.tokenizeAny(u8, line, " \t");
    _ = it.next();
    var out = Cpu{ .total = 0, .idle = 0 };
    var n: usize = 0;
    while (it.next()) |word| : (n += 1) {
        if (n >= 8) break;
        const v = std.fmt.parseInt(u64, word, 10) catch return null;
        out.total = std.math.add(u64, out.total, v) catch return null;
        if (n == 3 or n == 4) out.idle = std.math.add(u64, out.idle, v) catch return null;
    }
    return if (n >= 4) out else null;
}

/// 两次采样间的占用率,千分比;首次或计数回绕时返回 null。
pub fn usage(prev: ?Cpu, cur: Cpu) ?i32 {
    const p = prev orelse return null;
    if (cur.total <= p.total or cur.idle < p.idle) return null;
    const dt = cur.total - p.total;
    const di = @min(cur.idle - p.idle, dt);
    return @intCast(@as(u128, dt - di) * 1000 / dt);
}

/// 已用 = MemTotal - MemAvailable(与 free / htop 的 "used" 口径一致);缺 MemAvailable 时不猜。
pub fn parseMeminfo(text: []const u8, s: *model.Sample) void {
    var total: ?i64 = null;
    var avail: ?i64 = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var it = std.mem.tokenizeAny(u8, line, " \t");
        const key = it.next() orelse continue;
        const kb = src.integer(it.next() orelse continue) orelse continue;
        if (kb < 0) continue;
        if (std.mem.eql(u8, key, "MemTotal:")) total = kb;
        if (std.mem.eql(u8, key, "MemAvailable:")) avail = kb;
    }
    const t = total orelse return;
    s.mem_total_mb = std.math.cast(i32, @divTrunc(t, 1024));
    if (avail) |a| if (a <= t) {
        s.mem_used_mb = std.math.cast(i32, @divTrunc(t - a, 1024));
    };
}

test "CPU usage excludes guest time and handles resets" {
    const c = parseCpu("cpu 100 0 100 800 0 0 0 0 50 20").?;
    try std.testing.expectEqual(@as(u64, 1000), c.total);
    try std.testing.expectEqual(@as(?i32, 200), usage(.{ .total = 0, .idle = 0 }, c));
    try std.testing.expect(usage(c, .{ .total = 10, .idle = 1 }) == null);
    try std.testing.expect(usage(null, c) == null);
    try std.testing.expect(parseCpu("cpu0 1 2 3 4") == null);
}

test "meminfo uses MemAvailable and never guesses" {
    var s = model.Sample{};
    parseMeminfo("MemTotal:  16384000 kB\nMemFree: 100 kB\nMemAvailable: 12288000 kB\n", &s);
    try std.testing.expectEqual(@as(?i32, 16000), s.mem_total_mb);
    try std.testing.expectEqual(@as(?i32, 4000), s.mem_used_mb);
    // 小缓冲区截断在 MemAvailable 之前:只给总量
    var t = model.Sample{};
    parseMeminfo("MemTotal: 2048 kB\nMemFree: 1", &t);
    try std.testing.expectEqual(@as(?i32, 2), t.mem_total_mb);
    try std.testing.expect(t.mem_used_mb == null);
}
