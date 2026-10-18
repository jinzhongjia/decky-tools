//! stdout 输出队列。stdout 设为非阻塞:Python 读得慢时不能卡住采样循环。
//! 只按整行追加,部分写入的剩余字节留在队列里等 EPOLLOUT 再写,行边界永远不会被打断;
//! 队列放不下的行由调用方决定丢弃(实时快照丢一帧无妨,下一秒会有新的)。
const std = @import("std");
const sys = @import("sys.zig");

pub const capacity = 32 * 1024;

pub const Output = struct {
    buf: [capacity]u8 = undefined,
    start: usize = 0,
    end: usize = 0,

    pub fn pending(self: *const Output) bool {
        return self.end > self.start;
    }

    /// 用 render 在队尾追加一整行;空间不足时不追加并返回 false。
    pub fn append(self: *Output, render: anytype, args: anytype) bool {
        if (self.start > 0) { // 先把未写完的部分挪到开头,腾出连续空间
            std.mem.copyForwards(u8, self.buf[0 .. self.end - self.start], self.buf[self.start..self.end]);
            self.end -= self.start;
            self.start = 0;
        }
        var w = std.Io.Writer.fixed(self.buf[self.end..]);
        @call(.auto, render, .{&w} ++ args) catch return false;
        self.end += w.end;
        return true;
    }

    /// 尽量写出;对端关闭返回错误,暂时写不下(Again)则保留剩余部分。
    pub fn flush(self: *Output, fd: sys.fd_t) sys.Error!void {
        while (self.pending()) {
            const n = sys.write(fd, self.buf[self.start..self.end]) catch |err| switch (err) {
                error.Again => return,
                else => return err,
            };
            if (n == 0) return error.Closed;
            self.start += n;
        }
        self.start = 0;
        self.end = 0;
    }
};

fn line(w: *std.Io.Writer, text: []const u8) !void {
    try w.writeAll(text);
    try w.writeByte('\n');
}

test "appends whole lines and refuses overflow" {
    const o = try std.testing.allocator.create(Output);
    defer std.testing.allocator.destroy(o);
    o.* = .{};
    try std.testing.expect(o.append(line, .{"hello"}));
    try std.testing.expectEqualStrings("hello\n", o.buf[o.start..o.end]);
    o.start = 3; // 模拟部分写出
    try std.testing.expect(o.append(line, .{"x"}));
    try std.testing.expectEqualStrings("lo\nx\n", o.buf[o.start..o.end]);
    const big: [capacity - 4]u8 = @splat('a');
    try std.testing.expect(!o.append(line, .{&big}));
    try std.testing.expectEqualStrings("lo\nx\n", o.buf[o.start..o.end]); // 失败不留半行
}
