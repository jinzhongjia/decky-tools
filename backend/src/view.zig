//! 每个 tick 推给前端的完整监控快照(一行 JSON)。由 Zig 直接生成,Python 只做透传:
//! 前缀固定为 view_prefix,data 以 {"range":<窗口>, 开头,Python 据此识别并提取,不做 JSON 解析。
//! 字段与 src/tools/monitor/api.ts 的 MonitorView 一一对应。
const std = @import("std");
const json = @import("json.zig");
const hist = @import("history.zig");
const model = @import("model.zig");

pub const view_prefix = "{\"type\":\"view\",\"data\":";

/// 当前读数;一位小数的字段以 0.1 为单位存储。
fn writeCurrent(w: *std.Io.Writer, s: *const model.Sample) !void {
    try w.writeAll("{\"cpu_pct\":");
    try json.tenths(w, s.cpu_x10);
    try w.writeAll(",\"cpu_mhz\":");
    try json.int(w, s.cpu_mhz);
    try w.writeAll(",\"cpu_temp_c\":");
    try json.tenths(w, s.cpu_temp_c10);
    try w.writeAll(",\"gpu_pct\":");
    try json.int(w, s.gpu_pct);
    try w.writeAll(",\"gpu_mhz\":");
    try json.int(w, s.gpu_mhz);
    try w.writeAll(",\"gpu_temp_c\":");
    try json.tenths(w, s.gpu_temp_c10);
    try w.writeAll(",\"mem_pct\":");
    try json.tenths(w, s.memX10());
    try w.writeAll(",\"mem_used_mb\":");
    try json.int(w, s.mem_used_mb);
    try w.writeAll(",\"mem_total_mb\":");
    try json.int(w, s.mem_total_mb);
    try w.writeAll(",\"power_mw\":");
    try json.int(w, s.powerMw());
    try w.writeAll(if (s.apu_power_mw != null) ",\"power_source\":\"apu\"" else ",\"power_source\":\"battery\"");
    try w.writeAll(",\"battery_pct\":");
    try json.int(w, s.bat_pct);
    try w.writeAll(",\"battery_status\":");
    if (s.bat_status) |st| try json.string(w, @tagName(st)) else try w.writeAll("null");
    try w.writeAll(",\"battery_power_mw\":");
    try json.int(w, s.bat_power_mw);
    try w.writeByte('}');
}

/// 一条曲线。百分比类以 0.1 为单位存储,但 48 像素高的图表分辨不出 0.1%,四舍五入成整数输出:
/// 每帧少约三分之一字节,而这份快照每秒要经 Python、Decky loader、前端逐层编解码。
fn writeSeries(w: *std.Io.Writer, h: *const hist.History, range: usize, m: hist.Metric) !void {
    try w.writeByte('[');
    for (0..hist.bucketCount(hist.ranges[range])) |k| {
        if (k > 0) try w.writeByte(',');
        const v = h.value(range, @intCast(k), m);
        if (m == .power) try json.int(w, v) else try json.int(w, if (v) |x| @divTrunc(x + 5, 10) else null);
    }
    try w.writeByte(']');
}

/// 功耗曲线的峰值与均值(按桶均值计算,与图表一致);不足两个点时为 null。
fn writePowerStats(w: *std.Io.Writer, h: *const hist.History, range: usize) !void {
    var peak: i32 = 0;
    var sum: i64 = 0;
    var n: i64 = 0;
    for (0..hist.bucketCount(hist.ranges[range])) |k| {
        const v = h.value(range, @intCast(k), .power) orelse continue;
        peak = if (n == 0) v else @max(peak, v);
        sum += v;
        n += 1;
    }
    if (n < 2) return w.writeAll("null");
    try w.print("{{\"peak\":{d},\"avg\":{d}}}", .{ peak, @divTrunc(sum, n) });
}

pub fn write(w: *std.Io.Writer, h: *const hist.History, range: usize, last: ?model.Sample) !void {
    const r = hist.ranges[range];
    try w.writeAll(view_prefix);
    try w.print("{{\"range\":{d},\"ranges\":[", .{r.window});
    for (hist.ranges, 0..) |x, i| try w.print("{s}{d}", .{ if (i > 0) "," else "", x.window });
    try w.print("],\"capacity\":{d},\"current\":", .{hist.bucketCount(r)});
    if (last) |s| try writeCurrent(w, &s) else try w.writeAll("null");
    try w.writeAll(",\"series\":{");
    inline for (.{ "cpu", "gpu", "memory", "power", "battery" }, 0..) |name, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("\"" ++ name ++ "\":");
        try writeSeries(w, h, range, @field(hist.Metric, name));
    }
    try w.writeAll("},\"power_stats\":");
    try writePowerStats(w, h, range);
    try w.writeAll("}}\n");
}

test "view line is valid JSON with the agreed prefix" {
    var h = hist.History{};
    h.push(10, .{ 125, 300, 192, 4100, 300 });
    h.push(11, .{ 130, null, 192, 3900, 300 });
    const s = model.Sample{ .cpu_x10 = 130, .apu_power_mw = 3900, .mem_used_mb = 1, .mem_total_mb = 4, .bat_status = .discharging };
    var buf: [8192]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try write(&w, &h, 0, s);
    const line = w.buffered();
    try std.testing.expect(std.mem.startsWith(u8, line, view_prefix ++ "{\"range\":120,"));
    try std.testing.expect(std.mem.endsWith(u8, line, "}}\n"));
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line, .{});
    defer parsed.deinit();
    const data = parsed.value.object.get("data").?.object;
    try std.testing.expectEqual(@as(i64, 120), data.get("capacity").?.integer);
    const cpu = data.get("series").?.object.get("cpu").?.array.items;
    try std.testing.expectEqual(@as(usize, 120), cpu.len);
    try std.testing.expectEqual(@as(i64, 13), cpu[119].integer);
    try std.testing.expect(cpu[0] == .null);
    const gpu = data.get("series").?.object.get("gpu").?.array.items;
    try std.testing.expect(gpu[119] == .null);
    const stats = data.get("power_stats").?.object;
    try std.testing.expectEqual(@as(i64, 4100), stats.get("peak").?.integer);
    try std.testing.expectEqual(@as(i64, 4000), stats.get("avg").?.integer);
    const current = data.get("current").?.object;
    try std.testing.expectEqualStrings("apu", current.get("power_source").?.string);
    try std.testing.expectEqual(@as(f64, 25.0), current.get("mem_pct").?.float);
}

test "view without samples" {
    var h = hist.History{};
    var buf: [8192]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try write(&w, &h, 1, null);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, w.buffered(), .{});
    defer parsed.deinit();
    const data = parsed.value.object.get("data").?.object;
    try std.testing.expect(data.get("current").? == .null);
    try std.testing.expect(data.get("power_stats").? == .null);
    try std.testing.expectEqual(@as(i64, 180), data.get("capacity").?.integer);
}
