//! 极简 JSON 输出:只需要字符串转义与可空整数。
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

/// 写 `"key":value`;value 为 null 时整项省略(缺失 ≠ 0)。
pub fn optInt(w: *std.Io.Writer, first: *bool, comptime key: []const u8, value: ?i64) !void {
    const v = value orelse return;
    if (!first.*) try w.writeByte(',');
    first.* = false;
    try w.print("\"" ++ key ++ "\":{d}", .{v});
}

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

test "missing values are omitted" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    var first = true;
    try optInt(&w, &first, "a", null);
    try optInt(&w, &first, "b", 0);
    try optStr(&w, &first, "c", "");
    try optStr(&w, &first, "d", "x");
    try std.testing.expectEqualStrings("\"b\":0,\"d\":\"x\"", w.buffered());
}
