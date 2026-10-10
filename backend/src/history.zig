//! 纯内存历史:固定大小环形缓冲区保存最近 30 分钟的每秒采样(约 50 KB 静态内存),
//! 按时间分桶求均值输出给折线图。时间用 CLOCK_BOOTTIME,睡眠期间无采样 → 对应桶为 null(曲线断开)。
const std = @import("std");
const json = @import("json.zig");
const Sample = @import("sampler.zig").Sample;

pub const CAPACITY = 1800; // 1s × 1800 = 30 分钟
pub const MAX_BUCKETS = 360;
pub const KEYS = [_][]const u8{ "cpu_pct_x10", "gpu_pct", "mem_pct_x10", "apu_power_mw", "battery_power_mw", "battery_pct" };
const N = KEYS.len;

const Point = struct {
    t_ms: u64 = 0,
    mask: u8 = 0,
    v: [N]i32 = @splat(0),
};

pub fn fromSample(s: *const Sample) [N]?i64 {
    var mem: ?i64 = null;
    if (s.mem.used_mb) |u| if (s.mem.total_mb) |t| if (t > 0) {
        mem = @divTrunc(u * 1000, t);
    };
    return .{ s.cpu_pct_x10, s.r.gpu_pct, mem, s.r.apu_power_mw, s.r.battery_power_mw, s.r.battery_pct };
}

pub const History = struct {
    points: [CAPACITY]Point = @splat(.{}),
    head: usize = 0, // 下一个写入位置
    len: usize = 0,

    pub fn push(self: *History, t_ms: u64, values: [N]?i64) void {
        var p = Point{ .t_ms = t_ms };
        for (values, 0..) |value, i| if (value) |v| {
            p.v[i] = std.math.cast(i32, v) orelse continue;
            p.mask |= @as(u8, 1) << @intCast(i);
        };
        self.points[self.head] = p;
        self.head = (self.head + 1) % CAPACITY;
        self.len = @min(self.len + 1, CAPACITY);
    }

    /// 输出 (now - window, now] 区间内按 step 分桶的均值,旧 → 新;无数据的桶/字段为 null。
    pub fn write(self: *const History, w: *std.Io.Writer, now_ms: u64, window_ms: u64, step_ms: u64) !void {
        const buckets: usize = @intCast(window_ms / step_ms);
        var sums: [MAX_BUCKETS][N]i64 = @splat(@splat(0));
        var counts: [MAX_BUCKETS][N]u32 = @splat(@splat(0));
        const start = now_ms -| window_ms;
        for (0..self.len) |k| {
            const p = self.points[(self.head + CAPACITY - 1 - k) % CAPACITY];
            if (p.t_ms <= start or p.t_ms > now_ms) continue;
            const b = @min(buckets - 1, @as(usize, @intCast((p.t_ms - start - 1) / step_ms)));
            for (0..N) |i| if (p.mask & (@as(u8, 1) << @intCast(i)) != 0) {
                sums[b][i] += p.v[i];
                counts[b][i] += 1;
            };
        }
        try w.print("{{\"step_ms\":{d},\"keys\":[", .{step_ms});
        for (KEYS, 0..) |key, i| {
            if (i > 0) try w.writeByte(',');
            try json.string(w, key);
        }
        try w.writeAll("],\"points\":[");
        for (0..buckets) |b| {
            if (b > 0) try w.writeByte(',');
            try w.writeByte('[');
            for (0..N) |i| {
                if (i > 0) try w.writeByte(',');
                if (counts[b][i] == 0) try w.writeAll("null") else try w.print("{d}", .{@divTrunc(sums[b][i], counts[b][i])});
            }
            try w.writeByte(']');
        }
        try w.writeAll("]}");
    }
};

/// 解析 `history <window_s> <step_s>`;窗口 ≤ 30 分钟,桶数 1..MAX_BUCKETS。
pub fn parseRequest(line: []const u8) ?struct { window_ms: u64, step_ms: u64 } {
    const prefix = "history ";
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    var it = std.mem.tokenizeScalar(u8, line[prefix.len..], ' ');
    const window = std.fmt.parseInt(u64, it.next() orelse return null, 10) catch return null;
    const step = std.fmt.parseInt(u64, it.next() orelse return null, 10) catch return null;
    if (it.next() != null or step == 0 or window > CAPACITY or window < step or window / step > MAX_BUCKETS) return null;
    return .{ .window_ms = window * 1000, .step_ms = step * 1000 };
}

test "request validation" {
    try std.testing.expectEqual(@as(u64, 10_000), parseRequest("history 1800 10").?.step_ms);
    try std.testing.expect(parseRequest("history 1800 1") == null); // 桶太多
    try std.testing.expect(parseRequest("history 3600 10") == null); // 超出容量
    try std.testing.expect(parseRequest("history 10 0") == null);
    try std.testing.expect(parseRequest("history 10") == null);
}

test "buckets average values and leave gaps as null" {
    const h = try std.testing.allocator.create(History);
    defer std.testing.allocator.destroy(h);
    h.* = .{};
    h.push(1000, .{ 100, null, null, null, null, 50 });
    h.push(2000, .{ 300, null, null, null, null, 50 });
    h.push(4000, .{ 500, 7, null, null, null, 49 });
    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try h.write(&w, 4000, 4000, 2000);
    const out = w.buffered();
    const points = out[std.mem.indexOf(u8, out, "\"points\":").?..];
    try std.testing.expectEqualStrings("\"points\":[[200,null,null,null,null,50],[500,7,null,null,null,49]]}", points);
}

test "ring buffer overwrites oldest" {
    const h = try std.testing.allocator.create(History);
    defer std.testing.allocator.destroy(h);
    h.* = .{};
    for (0..CAPACITY + 5) |i| h.push(@intCast(i + 1), .{ @intCast(i), null, null, null, null, null });
    try std.testing.expectEqual(@as(usize, CAPACITY), h.len);
    try std.testing.expectEqual(@as(i32, CAPACITY + 4), h.points[(h.head + CAPACITY - 1) % CAPACITY].v[0]);
}
