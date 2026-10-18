//! 一次采样的数据模型。null = 本机不可用(或这一刻读不到),绝不用 0 冒充。
pub const BatteryStatus = enum { charging, discharging, full, not_charging, unknown };

pub const Sample = struct {
    cpu_x10: ?i32 = null, // CPU 占用,千分比
    cpu_mhz: ?i32 = null,
    cpu_temp_c10: ?i32 = null, // 0.1 °C
    gpu_pct: ?i32 = null,
    gpu_mhz: ?i32 = null,
    gpu_temp_c10: ?i32 = null,
    apu_power_mw: ?i32 = null, // 整颗 APU 的 socket 功耗
    mem_used_mb: ?i32 = null,
    mem_total_mb: ?i32 = null,
    bat_pct: ?i32 = null,
    bat_power_mw: ?i32 = null, // 正 = 放电,负 = 充电
    bat_status: ?BatteryStatus = null,

    pub fn memX10(s: *const Sample) ?i32 {
        const used = s.mem_used_mb orelse return null;
        const total = s.mem_total_mb orelse return null;
        if (total <= 0) return null;
        return @intCast(@divTrunc(@as(i64, used) * 1000, total));
    }

    /// 功耗:有 APU 读数(Steam Deck 等)用 APU;否则退回电池放电功率,充电时无意义。
    pub fn powerMw(s: *const Sample) ?i32 {
        if (s.apu_power_mw) |p| return p;
        const b = s.bat_power_mw orelse return null;
        return if (b > 0) b else null;
    }
};

const std = @import("std");

test "power prefers APU and ignores charging" {
    try std.testing.expectEqual(@as(?i32, 3000), (Sample{ .apu_power_mw = 3000, .bat_power_mw = 9000 }).powerMw());
    try std.testing.expectEqual(@as(?i32, 9000), (Sample{ .bat_power_mw = 9000 }).powerMw());
    try std.testing.expectEqual(@as(?i32, null), (Sample{ .bat_power_mw = -5000 }).powerMw());
    try std.testing.expectEqual(@as(?i32, 250), (Sample{ .mem_used_mb = 1, .mem_total_mb = 4 }).memX10());
    try std.testing.expectEqual(@as(?i32, null), (Sample{ .mem_total_mb = 4 }).memX10());
}
