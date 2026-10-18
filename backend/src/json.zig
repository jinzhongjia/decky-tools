//! 极简 JSON 输出:字符串转义、可空整数、一位小数的定点数。不经过浮点格式化。
const std = @import("std");

pub fn string(w: *std.Io.Writer, text: []const u8) !void {
    try w.writeByte('"');
    for (text) |c| switch (c) {
        '"', '\\' => {
            try w.writeByte('\\');
            try w.writeByte(c);
        },
        0...31 => try w.print("\\u00{x:0>2}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

/// 整数或 null。
pub fn int(w: *std.Io.Writer, value: ?i32) !void {
    const v = value orelse return w.writeAll("null");
    try w.print("{d}", .{v});
}

/// 以 0.1 为单位的定点数写成一位小数(125 → 12.5,-5 → -0.5);null 写 null。
pub fn tenths(w: *std.Io.Writer, value: ?i32) !void {
    const v = value orelse return w.writeAll("null");
    if (v < 0) try w.writeByte('-');
    const a = @abs(v);
    try w.print("{d}.{d}", .{ a / 10, a % 10 });
}

/// 写 `"key":value`;value 为空串时整项省略(系统信息里的可选字段)。
pub fn optStr(w: *std.Io.Writer, first: *bool, comptime key: []const u8, value: []const u8) !void {
    if (value.len == 0) return;
    if (!first.*) try w.writeByte(',');
    first.* = false;
    try w.writeAll("\"" ++ key ++ "\":");
    try string(w, value);
}

test "escapes control characters and quotes" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try string(&w, "a\"b\\\n");
    try std.testing.expectEqualStrings("\"a\\\"b\\\\\\u000a\"", w.buffered());
}

test "numbers" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try tenths(&w, 125);
    try w.writeByte(' ');
    try tenths(&w, -5);
    try w.writeByte(' ');
    try tenths(&w, 0);
    try w.writeByte(' ');
    try tenths(&w, null);
    try w.writeByte(' ');
    try int(&w, -42);
    try std.testing.expectEqualStrings("12.5 -0.5 0.0 null -42", w.buffered());
}
