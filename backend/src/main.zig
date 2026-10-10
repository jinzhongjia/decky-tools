//! dt-monitor:Decky Tools 的系统监控子进程。
//!
//! 每秒采样一次并写入 30 分钟内存历史(history.zig),不论是否有人在看。
//!
//! 协议(NDJSON,父进程 = 插件后端):
//!   stdin  每行一条命令:`live on` | `live off` | `info` | `history <window_s> <step_s>`
//!   stdout `{"type":"sample","data":{...}}`(live on 时每秒推送)
//!          `{"type":"info","data":{...}}`(响应 info)
//!          `{"type":"history","data":{...}}`(响应 history)
//!          `{"type":"error","code":"..."}`(无法识别的命令)
//! stdin 关闭(父进程退出)即退出。单线程 timerfd + epoll,无 libc。
const std = @import("std");
const sys = @import("sys.zig");
const runtime = @import("runtime.zig");
const Sampler = @import("sampler.zig").Sampler;
const hist = @import("history.zig");

pub const panic = runtime.panic;
pub const std_options = runtime.std_options;
pub const std_options_debug_threaded_io: ?*std.Io.Threaded = null;

const STDIN = 0;
const STDOUT = 1;

var out: [32768]u8 = undefined;
var input: [1024]u8 = undefined;
var in_len: usize = 0;
var history: hist.History = .{};
var live = false;

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
    var sampler = Sampler.init();
    defer sampler.deinit();
    _ = sampler.sample(); // 建立 CPU 基线,首个推送即有占用率
    const tfd = try sys.timerfdCreate();
    defer sys.close(tfd);
    try sys.timerfdSet(tfd, 1000);
    const efd = try sys.epollCreate();
    defer sys.close(efd);
    try sys.epollAdd(efd, tfd, 1);
    try sys.epollAdd(efd, STDIN, 2);
    var events: [4]sys.EpollEvent = undefined;
    while (true) {
        const n = sys.epollWait(efd, &events);
        if (n == 0) return error.EventLoopFailed;
        for (events[0..n]) |ev| {
            if (ev.data.u32 == 1) {
                sys.timerfdDrain(tfd);
                try tick(&sampler);
            } else if (!try readCommands()) return;
        }
    }
}

fn tick(sampler: *Sampler) !void {
    const s = sampler.sample();
    history.push(sys.bootMs(), hist.fromSample(&s));
    if (!live) return;
    var w = std.Io.Writer.fixed(&out);
    try w.writeAll("{\"type\":\"sample\",\"data\":");
    try s.write(&w);
    try w.writeAll("}\n");
    try sys.writeAll(STDOUT, w.buffered());
}

/// 读入并处理完整命令行;stdin EOF 时返回 false。
fn readCommands() !bool {
    if (in_len == input.len) in_len = 0; // 超长行直接丢弃,不让缓冲区卡死
    const n = sys.read(STDIN, input[in_len..]) catch |err| {
        if (err == error.Again) return true;
        return err;
    };
    if (n == 0) return false;
    in_len += n;
    while (std.mem.indexOfScalar(u8, input[0..in_len], '\n')) |end| {
        try handle(std.mem.trim(u8, input[0..end], " \r\t"));
        std.mem.copyForwards(u8, &input, input[end + 1 .. in_len]);
        in_len -= end + 1;
    }
    return true;
}

fn handle(line: []const u8) !void {
    var w = std.Io.Writer.fixed(&out);
    if (std.mem.eql(u8, line, "live on") or std.mem.eql(u8, line, "live off")) {
        live = std.mem.eql(u8, line, "live on");
        return;
    } else if (std.mem.eql(u8, line, "info")) {
        try w.writeAll("{\"type\":\"info\",\"data\":");
        try @import("sysinfo.zig").write(&w);
        try w.writeAll("}\n");
    } else if (hist.parseRequest(line)) |req| {
        try w.writeAll("{\"type\":\"history\",\"data\":");
        try history.write(&w, sys.bootMs(), req.window_ms, req.step_ms);
        try w.writeAll("}\n");
    } else if (line.len == 0) {
        return;
    } else {
        try w.writeAll("{\"type\":\"error\",\"code\":\"unknown_command\"}\n");
    }
    try sys.writeAll(STDOUT, w.buffered());
}
