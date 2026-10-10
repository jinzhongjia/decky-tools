//! 一次采样 = CPU 占用(/proc/stat 差分)+ 各传感器读数。
const std = @import("std");
const src = @import("source.zig");
const json = @import("json.zig");
const sensors = @import("sensors.zig");

pub const Cpu = struct { total: u64, idle: u64 };

pub const Memory = struct { used_mb: ?i64 = null, total_mb: ?i64 = null };

pub const Sample = struct {
    cpu_pct_x10: ?i64 = null,
    mem: Memory = .{},
    r: sensors.Reading = .{},

    pub fn write(self: *const Sample, w: *std.Io.Writer) !void {
        try w.writeByte('{');
        var first = true;
        try json.optInt(w, &first, "cpu_pct_x10", self.cpu_pct_x10);
        try json.optInt(w, &first, "mem_used_mb", self.mem.used_mb);
        try json.optInt(w, &first, "mem_total_mb", self.mem.total_mb);
        inline for (.{ "cpu_mhz", "cpu_temp_mc", "gpu_pct", "gpu_mhz", "gpu_temp_mc", "apu_power_mw", "battery_pct", "battery_power_mw" }) |key|
            try json.optInt(w, &first, key, @field(self.r, key));
        if (self.r.battery_status) |s| try json.optStr(w, &first, "battery_status", @tagName(s));
        try w.writeByte('}');
    }
};

pub const Sampler = struct {
    stat: src.Value,
    meminfo: src.Value,
    sensors: sensors.Sensors,
    prev: ?Cpu = null,
    buf: [16384]u8 = undefined,

    pub fn init() Sampler {
        return .{ .stat = src.Value.init("/proc/stat"), .meminfo = src.Value.init("/proc/meminfo"), .sensors = sensors.Sensors.init() };
    }

    pub fn deinit(self: *Sampler) void {
        self.stat.close();
        self.meminfo.close();
        self.sensors.deinit();
    }

    pub fn sample(self: *Sampler) Sample {
        var s = Sample{ .r = self.sensors.read() };
        if (self.meminfo.read(&self.buf)) |text| s.mem = parseMeminfo(text);
        const text = self.stat.read(&self.buf) orelse {
            self.prev = null;
            return s;
        };
        const line = text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len];
        const cur = parseCpu(line) orelse {
            self.prev = null;
            return s;
        };
        s.cpu_pct_x10 = usage(self.prev, cur);
        self.prev = cur;
        return s;
    }
};

/// 解析 /proc/stat 的汇总 "cpu " 行;guest/guest_nice 已含在 user/nice 中,只取前 8 列。
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

/// 已用 = MemTotal - MemAvailable(与 free/htop 的 "used" 口径一致);缺 MemAvailable 时不猜。
pub fn parseMeminfo(text: []const u8) Memory {
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
    var m = Memory{};
    const t = total orelse return m;
    m.total_mb = @divTrunc(t, 1024);
    if (avail) |a| if (a <= t) {
        m.used_mb = @divTrunc(t - a, 1024);
    };
    return m;
}

/// 两次采样间的占用率,千分比;首次或计数回绕时返回 null。
pub fn usage(prev: ?Cpu, cur: Cpu) ?i64 {
    const p = prev orelse return null;
    if (cur.total <= p.total or cur.idle < p.idle) return null;
    const dt = cur.total - p.total;
    const di = @min(cur.idle - p.idle, dt);
    return @intCast(@as(u128, dt - di) * 1000 / dt);
}

test "CPU usage excludes guest time and handles resets" {
    const c = parseCpu("cpu 100 0 100 800 0 0 0 0 50 20").?;
    try std.testing.expectEqual(@as(u64, 1000), c.total);
    try std.testing.expectEqual(@as(?i64, 200), usage(.{ .total = 0, .idle = 0 }, c));
    try std.testing.expect(usage(c, .{ .total = 10, .idle = 1 }) == null);
    try std.testing.expect(usage(null, c) == null);
    try std.testing.expect(parseCpu("cpu0 1 2 3 4") == null);
}

test "meminfo used excludes reclaimable memory and never guesses" {
    const m = parseMeminfo("MemTotal:  16384000 kB\nMemFree: 100 kB\nMemAvailable: 12288000 kB\n");
    try std.testing.expectEqual(@as(?i64, 16000), m.total_mb);
    try std.testing.expectEqual(@as(?i64, 4000), m.used_mb);
    const partial = parseMeminfo("MemTotal: 2048 kB\n");
    try std.testing.expectEqual(@as(?i64, 2), partial.total_mb);
    try std.testing.expect(partial.used_mb == null);
}

test "sample JSON omits unavailable metrics" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const s = Sample{ .cpu_pct_x10 = 125, .mem = .{ .total_mb = 16000 }, .r = .{ .gpu_pct = 0, .battery_status = .charging } };
    try s.write(&w);
    try std.testing.expectEqualStrings("{\"cpu_pct_x10\":125,\"mem_total_mb\":16000,\"gpu_pct\":0,\"battery_status\":\"charging\"}", w.buffered());
}
