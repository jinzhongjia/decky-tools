//! AMD APU 的 gpu_metrics(format 2、content ≥ 2,即 gpu_metrics_v2_2 ~ v2_4)。
//! 一次读取(约 170 字节)即可得到 GPU 占用/频率/温度、CPU 各核频率/温度与整颗芯片功耗,
//! 替代 cpufreq ×N、ACPI 温度区(每次求值约 200 µs)与多个 amdgpu 属性文件。
//! 布局见 Linux drivers/gpu/drm/amd/include/kgd_pp_interface.h;已用 Steam Deck(v2.4)实机数据核对。
const std = @import("std");

/// 需要读到 current_coreclk[8] 末尾。
pub const min_size = 104;
const invalid: u16 = 0xffff;

const Off = struct {
    const temperature_gfx = 4;
    const temperature_core = 8; // [8]u16
    const average_gfx_activity = 28;
    const average_socket_power = 40;
    const current_gfxclk = 76;
    const current_coreclk = 88; // [8]u16
};

pub const Metrics = struct {
    gpu_pct: ?i32 = null,
    gpu_mhz: ?i32 = null,
    gpu_temp_c10: ?i32 = null,
    cpu_mhz: ?i32 = null,
    cpu_temp_c10: ?i32 = null,
    socket_power_mw: ?i32 = null,
};

fn at(b: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, b[off..][0..2], .little);
}

/// 只接受已知布局:format_revision 2(APU)且 content_revision ≥ 2;其余格式走通用 sysfs 路径。
pub fn supported(b: []const u8) bool {
    return b.len >= min_size and b[2] == 2 and b[3] >= 2 and at(b, 0) >= min_size;
}

fn value(raw: u16) ?i32 {
    return if (raw == invalid or raw == 0) null else raw;
}

/// 0.01 °C → 0.1 °C(四舍五入)。
fn temp(raw: u16) ?i32 {
    const v = value(raw) orelse return null;
    return @divTrunc(v + 5, 10);
}

/// 新内核为百分比;部分旧固件为 0.01 %,超过 100 时按后者换算。
fn activity(raw: u16) ?i32 {
    if (raw == invalid) return null;
    return if (raw > 100) @divTrunc(@as(i32, raw), 100) else raw;
}

pub fn parse(b: []const u8) ?Metrics {
    if (!supported(b)) return null;
    var m = Metrics{
        .gpu_pct = activity(at(b, Off.average_gfx_activity)),
        .gpu_mhz = value(at(b, Off.current_gfxclk)),
        .gpu_temp_c10 = temp(at(b, Off.temperature_gfx)),
        // 运行中的 APU 不可能是 0 mW:实测偶发的 0 是 SMU 的瞬时无效读数,当作缺失,不让图表掉到 0
        .socket_power_mw = value(at(b, Off.average_socket_power)),
    };
    // 各核:频率取有效核的平均,温度取最高(未使用的核位为 0xffff)
    var sum: i32 = 0;
    var cores: i32 = 0;
    var hottest: ?i32 = null;
    for (0..8) |i| {
        if (value(at(b, Off.current_coreclk + i * 2))) |mhz| {
            sum += mhz;
            cores += 1;
        }
        if (temp(at(b, Off.temperature_core + i * 2))) |t| hottest = @max(hottest orelse t, t);
    }
    if (cores > 0) m.cpu_mhz = @divTrunc(sum, cores);
    m.cpu_temp_c10 = hottest;
    return m;
}

/// Steam Deck OLED 实机抓取的 gpu_metrics(v2.4,168 字节);期望值由独立的 Python struct 解码得出。
const deck_v2_4 =
    "a8000204a113ec13a1135014a1133714ffffffffffffffff0514ffff11000000" ++
    "0a71f57525f10000ff0fa703730253019e009e00d200db00ffffffffffffffff" ++
    "b801c9012003200358029001c800900120032003580290015006790979097909" ++
    "ffffffffffffffff7909ffff00000000ffffffffffffffff0000000000000000" ++
    "d9133714e8133e14f3134414ffffffffffffffff2f14ffffeb02b602a402dc04" ++
    "8803f801ffffffff";

test "parses Steam Deck gpu_metrics v2.4" {
    var buf: [168]u8 = undefined;
    _ = try std.fmt.hexToBytes(&buf, deck_v2_4);
    const m = parse(&buf).?;
    try std.testing.expectEqual(@as(?i32, 17), m.gpu_pct);
    try std.testing.expectEqual(@as(?i32, 200), m.gpu_mhz);
    try std.testing.expectEqual(@as(?i32, 503), m.gpu_temp_c10); // 50.25 °C
    try std.testing.expectEqual(@as(?i32, 2222), m.cpu_mhz); // 4 个有效核:1616、2425 ×3
    try std.testing.expectEqual(@as(?i32, 520), m.cpu_temp_c10); // 最热核 52.00 °C
    try std.testing.expectEqual(@as(?i32, 4095), m.socket_power_mw);
}

test "zero socket power is a missing reading, zero GPU activity is real" {
    var buf: [168]u8 = undefined;
    _ = try std.fmt.hexToBytes(&buf, deck_v2_4);
    std.mem.writeInt(u16, buf[Off.average_socket_power..][0..2], 0, .little);
    std.mem.writeInt(u16, buf[Off.average_gfx_activity..][0..2], 0, .little);
    const m = parse(&buf).?;
    try std.testing.expectEqual(@as(?i32, null), m.socket_power_mw);
    try std.testing.expectEqual(@as(?i32, 0), m.gpu_pct);
}

test "rejects unknown layouts and scales legacy activity" {
    var buf: [168]u8 = undefined;
    _ = try std.fmt.hexToBytes(&buf, deck_v2_4);
    buf[2] = 3; // gpu_metrics_v3_x(Phoenix 等)布局不同
    try std.testing.expect(parse(&buf) == null);
    buf[2] = 2;
    buf[3] = 1;
    try std.testing.expect(parse(&buf) == null);
    try std.testing.expect(parse(buf[0..50]) == null);
    try std.testing.expectEqual(@as(?i32, 99), activity(9900));
    try std.testing.expectEqual(@as(?i32, 99), activity(99));
}
