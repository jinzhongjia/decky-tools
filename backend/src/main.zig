//! dt-monitor:Decky Tools 的系统监控子进程(Zig 0.17,无 libc,静态链接)。
//!
//! 每秒采样一次写入内存历史(history.zig),不论是否有人在看。为不打扰游戏:
//! SCHED_BATCH + nice 10,唤醒不抢占正在运行的任务;50 ms 定时器松弛,唤醒可与其它定时器合并;
//! 采样落在固定的 1 秒网格上(MONOTONIC 调度),时间轴按 BOOTTIME 定位,睡眠期间自然留空。
//!
//! 协议(NDJSON,父进程 = 插件后端):
//!   stdin  每行一条命令:`live <window>` | `live off` | `info`
//!   stdout `{"type":"view","data":{...}}`(live 期间每秒一条完整快照,见 view.zig)
//!          `{"type":"info","data":{...}}`(响应 info)
//!          `{"type":"error","code":"..."}`(无法识别的命令)
//! stdin 关闭(父进程退出)即退出。
const std = @import("std");
const sys = @import("sys.zig");
const runtime = @import("runtime.zig");
const hist = @import("history.zig");
const model = @import("model.zig");
const view = @import("view.zig");
const Sampler = @import("sampler.zig").Sampler;
const Output = @import("out.zig").Output;

pub const panic = runtime.panic;
pub const std_options = runtime.std_options;
pub const std_options_debug_threaded_io: ?*std.Io.Threaded = null;

const STDIN = 0;
const STDOUT = 1;
const interval_ms = 1000;
const timer_slack_ns = 50 * std.time.ns_per_ms;
const tag_stdin = 1;
const tag_uevent = 2;
const tag_stdout = 3;

const State = struct {
    sampler: Sampler,
    history: hist.History = .{},
    out: Output = .{},
    last: ?model.Sample = null,
    live: ?usize = null, // 正在推送的时间范围下标
    origin_boot: u64,
    efd: sys.fd_t,
    uevent: sys.fd_t,
    stdout_watched: bool = false,
    input: [1024]u8 = undefined,
    in_len: usize = 0,
};

var state: State = undefined; // 约 45 KB,放静态区

pub fn main() u8 {
    run() catch |err| {
        sys.writeAll(2, "[dt-monitor] exit: ") catch {};
        sys.writeAll(2, @errorName(err)) catch {};
        sys.writeAll(2, "\n") catch {};
        return 1;
    };
    return 0;
}

fn run() !void {
    sys.backgroundPriority(timer_slack_ns);
    sys.setNonblock(STDOUT);
    const uevent = sys.ueventSocket() catch -1;
    defer if (uevent >= 0) sys.close(uevent);
    const efd = try sys.epollCreate();
    defer sys.close(efd);
    try sys.epollAdd(efd, STDIN, tag_stdin, sys.IN);
    if (uevent >= 0) try sys.epollAdd(efd, uevent, tag_uevent, sys.IN);
    state = .{ .sampler = Sampler.init(uevent >= 0), .origin_boot = sys.bootMs(), .efd = efd, .uevent = uevent };
    defer state.sampler.deinit();
    _ = state.sampler.sample(); // 建立 CPU 占用的差分基线
    var next = sys.monoMs() + interval_ms;
    var events: [4]sys.EpollEvent = undefined;
    while (true) {
        const now = sys.monoMs();
        if (now >= next) {
            tick();
            next += interval_ms * ((now - next) / interval_ms + 1); // 落后多个周期时直接跳到下一个网格点
        }
        const n = try sys.epollWait(efd, &events, @intCast(next -| sys.monoMs()));
        for (events[0..n]) |ev| {
            if (!try handle(ev)) return;
        }
    }
}

/// 处理一个就绪事件;返回 false 表示应退出(stdin 关闭或 stdout 对端关闭)。
fn handle(ev: sys.EpollEvent) !bool {
    switch (ev.data.u32) {
        tag_stdin => return readCommands(),
        tag_uevent => drainUevents(),
        tag_stdout => {
            if (ev.events & sys.HUP != 0) return false;
            try flush();
        },
        else => {},
    }
    return true;
}

fn tick() void {
    const s = state.sampler.sample();
    // 以 BOOTTIME 定位 tick 序号:睡眠期间时间照走,跳过的序号在历史里留空
    const seq: u32 = @intCast((sys.bootMs() - state.origin_boot + interval_ms / 2) / interval_ms);
    state.history.push(seq, .{ s.cpu_x10, if (s.gpu_pct) |g| g * 10 else null, s.memX10(), s.powerMw(), if (s.bat_pct) |b| b * 10 else null });
    state.last = s;
    if (state.live) |range| emitView(range);
}

/// 推送完整快照;上一帧还没写完(Python 读得慢)就丢弃这一帧。
fn emitView(range: usize) void {
    if (state.out.pending()) return;
    _ = state.out.append(view.write, .{ &state.history, range, state.last });
    flush() catch {};
}

fn flush() !void {
    try state.out.flush(STDOUT);
    const want = state.out.pending();
    if (want == state.stdout_watched) return;
    if (want) {
        sys.epollAdd(state.efd, STDOUT, tag_stdout, sys.OUT) catch sys.epollMod(state.efd, STDOUT, tag_stdout, sys.OUT) catch {};
    } else {
        sys.epollMod(state.efd, STDOUT, tag_stdout, 0) catch {};
    }
    state.stdout_watched = want;
}

fn drainUevents() void {
    var buf: [8192]u8 = undefined;
    for (0..16) |_| { // 有界:事件风暴时不独占循环
        const n = sys.recv(state.uevent, &buf) catch return;
        state.sampler.battery.onUevent(buf[0..n]);
    }
}

/// 读入并处理完整命令行;stdin EOF 时返回 false。
fn readCommands() !bool {
    if (state.in_len == state.input.len) state.in_len = 0; // 超长行直接丢弃
    const n = try sys.read(STDIN, state.input[state.in_len..]);
    if (n == 0) return false;
    state.in_len += n;
    while (std.mem.indexOfScalar(u8, state.input[0..state.in_len], '\n')) |end| {
        command(std.mem.trim(u8, state.input[0..end], " \r\t"));
        std.mem.copyForwards(u8, &state.input, state.input[end + 1 .. state.in_len]);
        state.in_len -= end + 1;
    }
    try flush();
    return true;
}

pub const Command = union(enum) { live: usize, live_off, info, empty, unknown };

pub fn parseCommand(line: []const u8) Command {
    if (line.len == 0) return .empty;
    if (std.mem.eql(u8, line, "info")) return .info;
    if (std.mem.eql(u8, line, "live off")) return .live_off;
    if (std.mem.startsWith(u8, line, "live ")) {
        const window = std.fmt.parseInt(u32, line["live ".len..], 10) catch return .unknown;
        if (hist.rangeIndex(window)) |r| return .{ .live = r };
    }
    return .unknown;
}

fn command(line: []const u8) void {
    switch (parseCommand(line)) {
        .live => |range| {
            state.live = range;
            emitView(range); // 立即推一帧;若仍有未写完的输出,则下一 tick 再推

        },
        .live_off => state.live = null,
        .info => _ = state.out.append(writeInfo, .{}),
        .empty => {},
        .unknown => _ = state.out.append(writeError, .{"unknown_command"}),
    }
}

fn writeInfo(w: *std.Io.Writer) !void {
    try w.writeAll("{\"type\":\"info\",\"data\":");
    try @import("sysinfo.zig").write(w);
    try w.writeAll("}\n");
}

fn writeError(w: *std.Io.Writer, code: []const u8) !void {
    try w.print("{{\"type\":\"error\",\"code\":\"{s}\"}}\n", .{code});
}

test "command parsing" {
    try std.testing.expectEqual(Command{ .live = 0 }, parseCommand("live 120"));
    try std.testing.expectEqual(Command{ .live = 1 }, parseCommand("live 1800"));
    try std.testing.expectEqual(Command.live_off, parseCommand("live off"));
    try std.testing.expectEqual(Command.info, parseCommand("info"));
    try std.testing.expectEqual(Command.unknown, parseCommand("live 999"));
    try std.testing.expectEqual(Command.unknown, parseCommand("history 120 1"));
    try std.testing.expectEqual(Command.empty, parseCommand(""));
}
