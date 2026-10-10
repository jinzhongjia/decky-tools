//! 传感器发现与读取:按能力探测 hwmon / drm / power_supply,不假设具体机型。
//! 未发现的项保持不可用(null),绝不用 0 冒充。逻辑源自 decky-scope monitor。
const std = @import("std");
const src = @import("source.zig");
const Value = src.Value;

pub const BatteryStatus = enum { charging, discharging, full, not_charging, unknown };

pub const Reading = struct {
    cpu_mhz: ?i64 = null,
    cpu_temp_mc: ?i64 = null,
    gpu_pct: ?i64 = null,
    gpu_mhz: ?i64 = null,
    gpu_temp_mc: ?i64 = null,
    apu_power_mw: ?i64 = null,
    battery_pct: ?i64 = null,
    /// 正数 = 放电功率,负数 = 充电功率
    battery_power_mw: ?i64 = null,
    battery_status: ?BatteryStatus = null,
};

pub const Sensors = struct {
    cpufreq: [256]Value = @splat(.{}),
    cpu_temp: Value = .{},
    gpu_busy: Value = .{},
    gpu_freq: Value = .{},
    gpu_temp: Value = .{},
    apu_power: Value = .{},
    bat_capacity: Value = .{},
    bat_status: Value = .{},
    bat_power: Value = .{},
    bat_current: Value = .{},
    bat_voltage: Value = .{},

    pub fn init() Sensors {
        var self = Sensors{};
        const deck = isSteamDeck();
        self.cpuFreq();
        self.hwmon(deck);
        self.gpu(deck);
        self.battery();
        return self;
    }

    pub fn deinit(self: *Sensors) void {
        for (&self.cpufreq) |*v| v.close();
        inline for (.{ "cpu_temp", "gpu_busy", "gpu_freq", "gpu_temp", "apu_power", "bat_capacity", "bat_status", "bat_power", "bat_current", "bat_voltage" }) |name| @field(self, name).close();
    }

    fn cpuFreq(self: *Sensors) void {
        var d = src.dir("/sys/devices/system/cpu") catch return;
        defer d.deinit();
        var buf: [512]u8 = undefined;
        while (d.next()) |entry| {
            if (!std.mem.startsWith(u8, entry, "cpu")) continue;
            const id = std.fmt.parseInt(usize, entry[3..], 10) catch continue;
            if (id >= self.cpufreq.len) continue;
            self.cpufreq[id] = Value.init(src.join(&buf, "/sys/devices/system/cpu/{s}/cpufreq/scaling_cur_freq", .{entry}) orelse continue);
        }
    }

    fn hwmon(self: *Sensors, deck: bool) void {
        // 两轮:先找首选的封装温度传感器,找不到再退回 ACPI 热区
        for (0..2) |pass| {
            var d = src.dir("/sys/class/hwmon") catch return;
            defer d.deinit();
            while (d.next()) |entry| {
                if (self.cpu_temp.ok()) return;
                var basebuf: [256]u8 = undefined;
                var pathbuf: [512]u8 = undefined;
                var namebuf: [64]u8 = undefined;
                const base = src.join(&basebuf, "/sys/class/hwmon/{s}", .{entry}) orelse continue;
                const name = src.text(src.join(&pathbuf, "{s}/name", .{base}) orelse continue, &namebuf) orelse continue;
                const preferred = if (deck) eql(name, "acpitz") else eql(name, "k10temp") or eql(name, "coretemp") or eql(name, "zenpower");
                if ((pass == 0 and preferred) or (pass == 1 and eql(name, "acpitz")))
                    self.cpu_temp = Value.init(src.join(&pathbuf, "{s}/temp1_input", .{base}) orelse continue);
            }
        }
    }

    fn gpu(self: *Sensors, deck: bool) void {
        var d = src.dir("/sys/class/drm") catch return;
        defer d.deinit();
        while (d.next()) |entry| {
            if (!std.mem.startsWith(u8, entry, "card")) continue;
            _ = std.fmt.parseInt(u32, entry[4..], 10) catch continue;
            var basebuf: [256]u8 = undefined;
            var pathbuf: [512]u8 = undefined;
            const base = src.join(&basebuf, "/sys/class/drm/{s}/device", .{entry}) orelse continue;
            self.gpu_busy = Value.init(src.join(&pathbuf, "{s}/gpu_busy_percent", .{base}) orelse continue);
            if (!self.gpu_busy.ok()) continue;
            self.gpuHwmon(base, deck);
            return;
        }
    }

    fn gpuHwmon(self: *Sensors, device: []const u8, deck: bool) void {
        var pathbuf: [512]u8 = undefined;
        var d = src.dir(src.join(&pathbuf, "{s}/hwmon", .{device}) orelse return) catch return;
        defer d.deinit();
        while (d.next()) |entry| {
            var basebuf: [512]u8 = undefined;
            var namebuf: [64]u8 = undefined;
            const base = src.join(&basebuf, "{s}/hwmon/{s}", .{ device, entry }) orelse continue;
            const name = src.text(src.join(&pathbuf, "{s}/name", .{base}) orelse continue, &namebuf) orelse continue;
            if (!eql(name, "amdgpu")) continue;
            self.gpu_temp = Value.init(src.join(&pathbuf, "{s}/temp1_input", .{base}) orelse return);
            self.gpu_freq = Value.init(src.join(&pathbuf, "{s}/freq1_input", .{base}) orelse return);
            // 只有已知 APU(Steam Deck)上 amdgpu 的 power1 才代表整颗芯片功耗;独显上语义不同,不报
            if (deck) {
                self.apu_power = Value.init(src.join(&pathbuf, "{s}/power1_average", .{base}) orelse return);
                if (self.apu_power.int() == null) {
                    self.apu_power.close();
                    self.apu_power = Value.init(src.join(&pathbuf, "{s}/power1_input", .{base}) orelse return);
                }
            }
            return;
        }
    }

    fn battery(self: *Sensors) void {
        var d = src.dir("/sys/class/power_supply") catch return;
        defer d.deinit();
        while (d.next()) |entry| {
            var basebuf: [256]u8 = undefined;
            var pathbuf: [512]u8 = undefined;
            var txt: [64]u8 = undefined;
            const base = src.join(&basebuf, "/sys/class/power_supply/{s}", .{entry}) orelse continue;
            const kind = src.text(src.join(&pathbuf, "{s}/type", .{base}) orelse continue, &txt) orelse continue;
            if (!eql(kind, "Battery")) continue;
            if (src.text(src.join(&pathbuf, "{s}/present", .{base}) orelse continue, &txt)) |present| {
                if (eql(present, "0")) continue;
            }
            self.bat_capacity = Value.init(src.join(&pathbuf, "{s}/capacity", .{base}) orelse continue);
            if (!self.bat_capacity.ok()) continue;
            self.bat_status = Value.init(src.join(&pathbuf, "{s}/status", .{base}) orelse return);
            self.bat_power = Value.init(src.join(&pathbuf, "{s}/power_now", .{base}) orelse return);
            self.bat_current = Value.init(src.join(&pathbuf, "{s}/current_now", .{base}) orelse return);
            self.bat_voltage = Value.init(src.join(&pathbuf, "{s}/voltage_now", .{base}) orelse return);
            return;
        }
    }

    pub fn read(self: *const Sensors) Reading {
        var r = Reading{};
        r.cpu_mhz = self.avgCpuMhz();
        r.cpu_temp_mc = self.cpu_temp.int();
        r.gpu_pct = percent(self.gpu_busy.int());
        if (self.gpu_freq.int()) |hz| r.gpu_mhz = @divTrunc(hz, 1_000_000);
        r.gpu_temp_mc = self.gpu_temp.int();
        if (self.apu_power.int()) |uw| r.apu_power_mw = @divTrunc(uw, 1000);
        r.battery_pct = percent(self.bat_capacity.int());
        var buf: [32]u8 = undefined;
        if (self.bat_status.read(&buf)) |text| {
            const status = parseStatus(text);
            r.battery_status = status;
            r.battery_power_mw = batteryPowerMw(status, self.bat_power.int(), self.bat_current.int(), self.bat_voltage.int());
        }
        return r;
    }

    fn avgCpuMhz(self: *const Sensors) ?i64 {
        var sum: i64 = 0;
        var count: i64 = 0;
        for (self.cpufreq) |v| if (v.int()) |khz| {
            if (khz > 0 and khz < 100_000_000) {
                sum += khz;
                count += 1;
            }
        };
        return if (count > 0) @divTrunc(sum, count * 1000) else null;
    }
};

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn isSteamDeck() bool {
    var buf: [64]u8 = undefined;
    const board = src.text("/sys/class/dmi/id/board_name", &buf) orelse return false;
    return eql(board, "Jupiter") or eql(board, "Galileo");
}

fn percent(value: ?i64) ?i64 {
    const v = value orelse return null;
    return if (v >= 0 and v <= 100) v else null;
}

pub fn parseStatus(text: []const u8) BatteryStatus {
    if (eql(text, "Charging")) return .charging;
    if (eql(text, "Discharging")) return .discharging;
    if (eql(text, "Full")) return .full;
    if (eql(text, "Not charging")) return .not_charging;
    return .unknown;
}

/// power_now 优先,否则用 current×voltage 推算;充电为负。满电/未充电视为 0。
pub fn batteryPowerMw(status: BatteryStatus, power_uw: ?i64, current_ua: ?i64, voltage_uv: ?i64) ?i64 {
    switch (status) {
        .full, .not_charging => return 0,
        .unknown => return null,
        .charging, .discharging => {},
    }
    var mw: i128 = undefined;
    if (power_uw != null and power_uw.? >= 0) {
        mw = @divTrunc(power_uw.?, 1000);
    } else {
        const current = current_ua orelse return null;
        const voltage = voltage_uv orelse return null;
        if (voltage <= 0) return null;
        const magnitude: i128 = @intCast(@abs(@as(i128, current)));
        mw = @divTrunc(magnitude * voltage, 1_000_000_000); // µA·µV → mW
    }
    if (mw > std.math.maxInt(i32)) return null;
    const v: i64 = @intCast(mw);
    return if (status == .charging) -v else v;
}

test "battery power prefers power_now and derives from current and voltage" {
    try std.testing.expectEqual(@as(?i64, 14000), batteryPowerMw(.discharging, 14000000, 2000000, 8000000));
    try std.testing.expectEqual(@as(?i64, 16000), batteryPowerMw(.discharging, null, 2000000, 8000000));
    try std.testing.expectEqual(@as(?i64, -16000), batteryPowerMw(.charging, null, -2000000, 8000000));
    try std.testing.expectEqual(@as(?i64, 0), batteryPowerMw(.full, null, null, null));
    try std.testing.expectEqual(@as(?i64, null), batteryPowerMw(.unknown, 1000000, null, null));
    try std.testing.expectEqual(@as(?i64, null), batteryPowerMw(.discharging, null, 1000000, 0));
}

test "status parsing and percent bounds" {
    try std.testing.expectEqual(BatteryStatus.not_charging, parseStatus("Not charging"));
    try std.testing.expectEqual(BatteryStatus.unknown, parseStatus("weird"));
    try std.testing.expectEqual(@as(?i64, null), percent(101));
    try std.testing.expectEqual(@as(?i64, 0), percent(0));
}
