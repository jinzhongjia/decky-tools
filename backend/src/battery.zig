//! 电池。电量 / 电流 / 电压每秒读取,保证电量与充放电功率都是当前值:读数来自 ACPI,内核缓存 1 秒,
//! 每秒首次读取要求值 _BST(实测约 340 µs CPU),为准确性接受这一开销。
//! status 例外:放电时读取它会顺带查询交流适配器(ACPI _PSR,约 400 µs CPU、阻塞 1 ms 以上),
//! 而它只在插拔电源、充满等时刻变化,内核届时会发 power_supply uevent,所以只在启动、收到 uevent
//! 以及每分钟兜底时读取,不影响准确性。
const std = @import("std");
const src = @import("source.zig");
const model = @import("model.zig");
const BatteryStatus = model.BatteryStatus;

/// 有 uevent 时的兜底刷新周期;没有 uevent(socket 打不开)时退回较短周期。
const refresh_ticks_events = 60;
const refresh_ticks_polling = 5;
/// 收到其它电源设备(如交流适配器)的事件后,在下一 tick 与 3 tick 后各复查一次:EC 状态可能稍后才更新。
const recheck_after_event: u8 = 0b1001;

pub const Battery = struct {
    name: [32]u8 = @splat(0),
    capacity: src.Value = .{},
    status: src.Value = .{},
    power: src.Value = .{},
    current: src.Value = .{},
    voltage: src.Value = .{},
    state: ?BatteryStatus = null,
    pending: u8 = 1, // 位 0 = 本 tick 需要读 status,每 tick 右移一位
    since_status: u32 = 0,
    refresh_ticks: u32 = refresh_ticks_polling,

    pub fn init(uevents: bool) Battery {
        var self = Battery{ .refresh_ticks = if (uevents) refresh_ticks_events else refresh_ticks_polling };
        var d = src.dir("/sys/class/power_supply") catch return self;
        defer d.deinit();
        while (d.next()) |entry| {
            if (self.tryAttach(entry)) return self;
        }
        return self;
    }

    fn tryAttach(self: *Battery, entry: []const u8) bool {
        var basebuf: [256]u8 = undefined;
        var pathbuf: [512]u8 = undefined;
        var txt: [64]u8 = undefined;
        const base = src.join(&basebuf, "/sys/class/power_supply/{s}", .{entry}) orelse return false;
        const kind = src.text(src.join(&pathbuf, "{s}/type", .{base}) orelse return false, &txt) orelse return false;
        if (!std.mem.eql(u8, kind, "Battery")) return false;
        if (src.text(src.join(&pathbuf, "{s}/present", .{base}) orelse return false, &txt)) |present| {
            if (std.mem.eql(u8, present, "0")) return false;
        }
        self.capacity = src.Value.init(src.join(&pathbuf, "{s}/capacity", .{base}) orelse return false);
        if (!self.capacity.ok()) return false;
        inline for (.{ .{ "status", "status" }, .{ "power", "power_now" }, .{ "current", "current_now" }, .{ "voltage", "voltage_now" } }) |f| {
            @field(self, f[0]) = src.Value.init(src.join(&pathbuf, "{s}/" ++ f[1], .{base}) orelse "");
        }
        src.copy(&self.name, entry);
        return true;
    }

    pub fn deinit(self: *Battery) void {
        inline for (.{ "capacity", "status", "power", "current", "voltage" }) |f| @field(self, f).close();
    }

    /// 推进一个 tick,决定本次是否读 status(纯计数逻辑,单测覆盖)。
    pub fn statusDue(self: *Battery) bool {
        self.since_status +|= 1;
        const urgent = self.pending & 1 != 0;
        self.pending >>= 1;
        return urgent or self.since_status >= self.refresh_ticks;
    }

    pub fn read(self: *Battery, s: *model.Sample) void {
        if (!self.capacity.ok()) return;
        if (self.statusDue()) self.refreshStatus();
        s.bat_pct = percent(self.capacity.int());
        const state = self.state orelse return;
        s.bat_status = state;
        s.bat_power_mw = powerMw(state, self.power.int(), self.current.int(), self.voltage.int());
    }

    fn refreshStatus(self: *Battery) void {
        var buf: [32]u8 = undefined;
        self.state = if (self.status.read(&buf)) |text| parseStatus(text) else null;
        self.since_status = 0;
    }

    /// 处理一条内核 uevent:本电池的事件自带最新 status,直接采用;其它电源设备的事件安排复查。
    pub fn onUevent(self: *Battery, msg: []const u8) void {
        if (!self.capacity.ok()) return;
        var power_supply = false;
        var ours = false;
        var status: ?[]const u8 = null;
        var fields = std.mem.splitScalar(u8, msg, 0);
        while (fields.next()) |f| {
            if (std.mem.eql(u8, f, "SUBSYSTEM=power_supply")) power_supply = true;
            if (std.mem.startsWith(u8, f, "POWER_SUPPLY_NAME=")) ours = std.mem.eql(u8, f["POWER_SUPPLY_NAME=".len..], src.str(&self.name));
            if (std.mem.startsWith(u8, f, "POWER_SUPPLY_STATUS=")) status = f["POWER_SUPPLY_STATUS=".len..];
        }
        if (!power_supply) return;
        if (ours and status != null) {
            self.state = parseStatus(status.?);
            self.since_status = 0;
            return;
        }
        self.pending |= recheck_after_event;
    }
};

fn percent(value: ?i64) ?i32 {
    const v = value orelse return null;
    return if (v >= 0 and v <= 100) @intCast(v) else null;
}

pub fn parseStatus(text: []const u8) BatteryStatus {
    const map = .{ .{ "Charging", .charging }, .{ "Discharging", .discharging }, .{ "Full", .full }, .{ "Not charging", .not_charging } };
    inline for (map) |m| if (std.mem.eql(u8, text, m[0])) return m[1];
    return .unknown;
}

/// power_now 优先,否则用 current × voltage 推算;充电为负。满电 / 未充电视为 0。
pub fn powerMw(status: BatteryStatus, power_uw: ?i64, current_ua: ?i64, voltage_uv: ?i64) ?i32 {
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
    const v: i32 = @intCast(mw);
    return if (status == .charging) -v else v;
}

test "battery power prefers power_now and derives from current and voltage" {
    try std.testing.expectEqual(@as(?i32, 14000), powerMw(.discharging, 14000000, 2000000, 8000000));
    try std.testing.expectEqual(@as(?i32, 16000), powerMw(.discharging, null, 2000000, 8000000));
    try std.testing.expectEqual(@as(?i32, -16000), powerMw(.charging, null, -2000000, 8000000));
    try std.testing.expectEqual(@as(?i32, 0), powerMw(.full, null, null, null));
    try std.testing.expectEqual(@as(?i32, null), powerMw(.unknown, 1000000, null, null));
    try std.testing.expectEqual(@as(?i32, null), powerMw(.discharging, null, 1000000, 0));
}

test "status parsing" {
    try std.testing.expectEqual(BatteryStatus.not_charging, parseStatus("Not charging"));
    try std.testing.expectEqual(BatteryStatus.unknown, parseStatus("weird"));
}

test "status is read rarely, and right after power events" {
    var b = Battery{ .capacity = .{ .fd = 99 }, .state = .discharging, .pending = 0, .refresh_ticks = 60, .since_status = 0 };
    var reads: u32 = 0;
    for (0..130) |_| {
        if (b.statusDue()) {
            reads += 1;
            b.since_status = 0;
        }
    }
    try std.testing.expectEqual(@as(u32, 2), reads); // 每 60 tick 兜底一次
    // 交流适配器事件:下一 tick 与 3 tick 后各读一次
    src.copy(&b.name, "BAT1");
    b.since_status = 0;
    b.onUevent("change@/x/ACAD\x00SUBSYSTEM=power_supply\x00POWER_SUPPLY_NAME=ACAD\x00");
    try std.testing.expect(b.statusDue());
    b.since_status = 0;
    try std.testing.expect(!b.statusDue());
    try std.testing.expect(!b.statusDue());
    try std.testing.expect(b.statusDue());
}

test "uevents update status without reading sysfs" {
    var b = Battery{ .capacity = .{ .fd = 99 }, .state = .discharging, .pending = 0 };
    src.copy(&b.name, "BAT1");
    b.onUevent("change@/devices/x/power_supply/BAT1\x00ACTION=change\x00SUBSYSTEM=power_supply\x00POWER_SUPPLY_NAME=BAT1\x00POWER_SUPPLY_STATUS=Charging\x00");
    try std.testing.expectEqual(@as(?BatteryStatus, .charging), b.state);
    try std.testing.expectEqual(@as(u8, 0), b.pending);
    // 交流适配器事件不带电池 status:安排下一 tick 与 3 tick 后复查
    b.onUevent("change@/devices/x/power_supply/ACAD\x00SUBSYSTEM=power_supply\x00POWER_SUPPLY_NAME=ACAD\x00POWER_SUPPLY_ONLINE=1\x00");
    try std.testing.expectEqual(recheck_after_event, b.pending);
    // 与电源无关的事件忽略
    b.pending = 0;
    b.onUevent("add@/devices/usb1\x00SUBSYSTEM=usb\x00");
    try std.testing.expectEqual(@as(u8, 0), b.pending);
}
