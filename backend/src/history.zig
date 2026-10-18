//! 纯内存历史:按 tick 序号预聚合的环形桶,每个时间范围一组(2 分钟 × 1 秒、30 分钟 × 10 秒)。
//! 每次采样只更新各范围的当前桶,输出时直接读桶,不再每次重扫原始点;约 9 KB 静态内存,不落盘。
//! 桶按 tick 序号(而非读数的实际时刻)定位:定时器松弛带来的几十毫秒抖动不会把两次采样挤进同一个桶;
//! 睡眠或卡顿跳过的 tick 对应的桶留空,图表在此断开,不会连成假直线。
const std = @import("std");

pub const Metric = enum { cpu, gpu, memory, power, battery };
pub const metric_count = 5;
comptime {
    std.debug.assert(std.enums.values(Metric).len == metric_count);
}

pub const Range = struct { window: u32, step: u32 };
/// 可选时间范围(秒);Python 端 tools/monitor/tool.py 的 RANGES 必须与此一致。
pub const ranges = [_]Range{ .{ .window = 120, .step = 1 }, .{ .window = 1800, .step = 10 } };

pub fn bucketCount(r: Range) u32 {
    return r.window / r.step;
}

pub fn rangeIndex(window: u32) ?usize {
    for (ranges, 0..) |r, i| if (r.window == window) return i;
    return null;
}

const offsets = blk: {
    var o: [ranges.len + 1]usize = undefined;
    o[0] = 0;
    for (ranges, 0..) |r, i| o[i + 1] = o[i] + bucketCount(r);
    break :blk o;
};

/// 全零即"空桶"(计数为 0 的桶读出 null):History 的初值全为零,放进 .bss,
/// 不必在二进制里存一份 9.6 KB 的预填表再拷贝。
const Bucket = struct {
    id: u32 = 0,
    sum: [metric_count]i32 = @splat(0),
    cnt: [metric_count]u8 = @splat(0),
};

pub const History = struct {
    buckets: [offsets[ranges.len]]Bucket = @splat(.{}),
    seq: ?u32 = null, // 最近一次写入的 tick 序号

    pub fn push(self: *History, seq: u32, values: [metric_count]?i32) void {
        self.seq = seq;
        for (ranges, 0..) |r, i| {
            const id = seq / r.step;
            const b = &self.buckets[offsets[i] + id % bucketCount(r)];
            if (b.id != id) b.* = .{ .id = id };
            for (values, 0..) |v, m| if (v) |x| {
                b.sum[m] += x;
                b.cnt[m] +|= 1;
            };
        }
    }

    /// 范围内第 k 个桶(0 = 最旧)某指标的平均值;无数据为 null。
    pub fn value(self: *const History, range: usize, k: u32, m: Metric) ?i32 {
        const seq = self.seq orelse return null;
        const r = ranges[range];
        const newest = seq / r.step;
        const back = bucketCount(r) - 1 - k;
        if (back > newest) return null; // 早于第一次采样
        const id = newest - back;
        const b = &self.buckets[offsets[range] + id % bucketCount(r)];
        const i = @backingInt(m);
        if (b.id != id or b.cnt[i] == 0) return null;
        const c: i32 = b.cnt[i];
        return @divTrunc(b.sum[i] + @divTrunc(c, 2), c);
    }
};

fn cpuOnly(cpu: ?i32) [metric_count]?i32 {
    return .{ cpu, null, null, null, null };
}

test "short range keeps one sample per bucket and leaves gaps empty" {
    var h = History{};
    h.push(100, cpuOnly(10));
    h.push(101, cpuOnly(20));
    h.push(104, cpuOnly(40)); // 102、103 被跳过(睡眠)
    const last = bucketCount(ranges[0]) - 1;
    try std.testing.expectEqual(@as(?i32, 40), h.value(0, last, .cpu));
    try std.testing.expectEqual(@as(?i32, null), h.value(0, last - 1, .cpu));
    try std.testing.expectEqual(@as(?i32, null), h.value(0, last - 2, .cpu));
    try std.testing.expectEqual(@as(?i32, 20), h.value(0, last - 3, .cpu));
    try std.testing.expectEqual(@as(?i32, null), h.value(0, last, .gpu));
    try std.testing.expectEqual(@as(?i32, null), h.value(0, 0, .cpu)); // 早于开始
}

test "long range averages ten ticks per bucket, including the partial one" {
    var h = History{};
    for (0..25) |i| h.push(@intCast(1000 + i), cpuOnly(@intCast(i)));
    const last = bucketCount(ranges[1]) - 1;
    try std.testing.expectEqual(@as(?i32, 22), h.value(1, last, .cpu)); // 序号 1020..1024 → 20..24
    try std.testing.expectEqual(@as(?i32, 15), h.value(1, last - 1, .cpu)); // 10..19 → 14.5 四舍五入
    try std.testing.expectEqual(@as(?i32, 5), h.value(1, last - 2, .cpu)); // 0..9 → 4.5
}

test "ring reuse drops stale buckets" {
    var h = History{};
    h.push(5, cpuOnly(7));
    h.push(5 + 120, cpuOnly(9)); // 同一槽位,新一轮
    const last = bucketCount(ranges[0]) - 1;
    try std.testing.expectEqual(@as(?i32, 9), h.value(0, last, .cpu));
    try std.testing.expectEqual(@as(?i32, null), h.value(0, 0, .cpu));
}
