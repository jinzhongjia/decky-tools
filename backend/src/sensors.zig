//! CPU / GPU 传感器。按能力探测,不假设机型;读不到的项保持 null,绝不用 0 冒充。
//! - apu 模式:AMD APU 的 gpu_metrics 一次读取覆盖 CPU 频率/温度、GPU 占用/频率/温度与芯片功耗(见 apu.zig)。
//! - generic 模式:其余硬件逐个读 cpufreq / hwmon / drm 属性(逻辑源自 decky-scope monitor)。
const std = @import("std");
const src = @import("source.zig");
const apu = @import("apu.zig");
const model = @import("model.zig");
const Value = src.Value;

pub const Sensors = struct {
    metrics: Value = .{}, // apu 模式:gpu_metrics
    cpufreq: [64]Value = @splat(.{}),
    cpu_temp: Value = .{},
    gpu_busy: Value = .{},
    gpu_freq: Value = .{},
    gpu_temp: Value = .{},

    pub fn init() Sensors {
        var self = Sensors{};
        if (self.findApuMetrics()) return self;
        self.cpuFreq();
        self.hwmon();
        self.gpu();
        return self;
    }

    pub fn deinit(self: *Sensors) void {
        for (&self.cpufreq) |*v| v.close();
        inline for (.{ "metrics", "cpu_temp", "gpu_busy", "gpu_freq", "gpu_temp" }) |f| @field(self, f).close();
    }

    pub fn apuMode(self: *const Sensors) bool {
        return self.metrics.ok();
    }

    pub fn read(self: *const Sensors, s: *model.Sample) void {
        if (self.apuMode()) return self.readApu(s);
        s.cpu_mhz = self.avgCpuMhz();
        s.cpu_temp_c10 = milliToC10(self.cpu_temp.int());
        s.gpu_pct = percent(self.gpu_busy.int());
        if (self.gpu_freq.int()) |hz| s.gpu_mhz = @intCast(@divTrunc(hz, 1_000_000));
        s.gpu_temp_c10 = milliToC10(self.gpu_temp.int());
    }

    fn readApu(self: *const Sensors, s: *model.Sample) void {
        var buf: [512]u8 = undefined;
        const n = src.pread(self.metrics, &buf) orelse return;
        const m = apu.parse(buf[0..n]) orelse return;
        s.cpu_mhz = m.cpu_mhz;
        s.cpu_temp_c10 = m.cpu_temp_c10;
        s.gpu_pct = m.gpu_pct;
        s.gpu_mhz = m.gpu_mhz;
        s.gpu_temp_c10 = m.gpu_temp_c10;
        s.apu_power_mw = m.socket_power_mw;
    }

    /// 找第一张带受支持 gpu_metrics 的 DRM 卡;找到即进入 apu 模式。
    fn findApuMetrics(self: *Sensors) bool {
        var d = src.dir("/sys/class/drm") catch return false;
        defer d.deinit();
        while (d.next()) |entry| {
            if (!isCard(entry)) continue;
            var pathbuf: [256]u8 = undefined;
            var v = Value.init(src.join(&pathbuf, "/sys/class/drm/{s}/device/gpu_metrics", .{entry}) orelse continue);
            var buf: [512]u8 = undefined;
            const n = src.pread(v, &buf) orelse 0;
            if (apu.supported(buf[0..n])) {
                self.metrics = v;
                return true;
            }
            v.close();
        }
        return false;
    }

    fn cpuFreq(self: *Sensors) void {
        var d = src.dir("/sys/devices/system/cpu") catch return;
        defer d.deinit();
        var buf: [256]u8 = undefined;
        while (d.next()) |entry| {
            if (!std.mem.startsWith(u8, entry, "cpu")) continue;
            const id = std.fmt.parseInt(usize, entry[3..], 10) catch continue;
            if (id >= self.cpufreq.len) continue;
            self.cpufreq[id] = Value.init(src.join(&buf, "/sys/devices/system/cpu/{s}/cpufreq/scaling_cur_freq", .{entry}) orelse continue);
        }
    }

    fn hwmon(self: *Sensors) void {
        const deck = isSteamDeck();
        // 两轮:先找首选的封装温度传感器,找不到再退回 ACPI 热区(每次读取都要求值 ACPI 方法,较贵)
        for (0..2) |pass| {
            var d = src.dir("/sys/class/hwmon") catch return;
            defer d.deinit();
            while (d.next()) |entry| {
                if (self.cpu_temp.ok()) return;
                var basebuf: [128]u8 = undefined;
                var pathbuf: [256]u8 = undefined;
                var namebuf: [64]u8 = undefined;
                const base = src.join(&basebuf, "/sys/class/hwmon/{s}", .{entry}) orelse continue;
                const name = src.text(src.join(&pathbuf, "{s}/name", .{base}) orelse continue, &namebuf) orelse continue;
                const preferred = if (deck) eql(name, "acpitz") else eql(name, "k10temp") or eql(name, "coretemp") or eql(name, "zenpower");
                if ((pass == 0 and preferred) or (pass == 1 and eql(name, "acpitz")))
                    self.cpu_temp = Value.init(src.join(&pathbuf, "{s}/temp1_input", .{base}) orelse continue);
            }
        }
    }

    fn gpu(self: *Sensors) void {
        var d = src.dir("/sys/class/drm") catch return;
        defer d.deinit();
        while (d.next()) |entry| {
            if (!isCard(entry)) continue;
            var basebuf: [128]u8 = undefined;
            var pathbuf: [256]u8 = undefined;
            const base = src.join(&basebuf, "/sys/class/drm/{s}/device", .{entry}) orelse continue;
            self.gpu_busy = Value.init(src.join(&pathbuf, "{s}/gpu_busy_percent", .{base}) orelse continue);
            if (!self.gpu_busy.ok()) continue;
            self.gpuHwmon(base);
            return;
        }
    }

    fn gpuHwmon(self: *Sensors, device: []const u8) void {
        var pathbuf: [256]u8 = undefined;
        var d = src.dir(src.join(&pathbuf, "{s}/hwmon", .{device}) orelse return) catch return;
        defer d.deinit();
        while (d.next()) |entry| {
            var basebuf: [256]u8 = undefined;
            var namebuf: [64]u8 = undefined;
            const base = src.join(&basebuf, "{s}/hwmon/{s}", .{ device, entry }) orelse continue;
            const name = src.text(src.join(&pathbuf, "{s}/name", .{base}) orelse continue, &namebuf) orelse continue;
            if (!eql(name, "amdgpu")) continue;
            self.gpu_temp = Value.init(src.join(&pathbuf, "{s}/temp1_input", .{base}) orelse return);
            self.gpu_freq = Value.init(src.join(&pathbuf, "{s}/freq1_input", .{base}) orelse return);
            return;
        }
    }

    fn avgCpuMhz(self: *const Sensors) ?i32 {
        var sum: i64 = 0;
        var count: i64 = 0;
        for (self.cpufreq) |v| if (v.int()) |khz| {
            if (khz > 0 and khz < 100_000_000) {
                sum += khz;
                count += 1;
            }
        };
        return if (count > 0) @intCast(@divTrunc(sum, count * 1000)) else null;
    }
};

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn isCard(entry: []const u8) bool {
    if (!std.mem.startsWith(u8, entry, "card")) return false;
    _ = std.fmt.parseInt(u32, entry[4..], 10) catch return false;
    return true;
}

fn isSteamDeck() bool {
    var buf: [64]u8 = undefined;
    const board = src.text("/sys/class/dmi/id/board_name", &buf) orelse return false;
    return eql(board, "Jupiter") or eql(board, "Galileo");
}

fn percent(value: ?i64) ?i32 {
    const v = value orelse return null;
    return if (v >= 0 and v <= 100) @intCast(v) else null;
}

fn milliToC10(value: ?i64) ?i32 {
    const v = value orelse return null;
    return std.math.cast(i32, @divTrunc(v + 50, 100));
}

test "unit helpers" {
    try std.testing.expectEqual(@as(?i32, 580), milliToC10(58000));
    try std.testing.expectEqual(@as(?i32, null), percent(101));
    try std.testing.expect(isCard("card0") and !isCard("card0-eDP-1") and !isCard("renderD128"));
}
