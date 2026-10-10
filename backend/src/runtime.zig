const std = @import("std");
const sys = @import("sys.zig");
pub const panic = struct {
    pub fn call(msg: []const u8, ra: ?usize) noreturn {
        _ = ra;
        sys.writeAll(2, "panic: ") catch {};
        sys.writeAll(2, msg) catch {};
        sys.writeAll(2, "\n") catch {};
        @trap();
    }
    // 安全检查 panic 入口（越界/溢出/unwrap 等）全部复用 call
    pub const sentinelMismatch = std.debug.no_panic.sentinelMismatch;
    pub const unwrapError = std.debug.no_panic.unwrapError;
    pub const outOfBounds = std.debug.no_panic.outOfBounds;
    pub const startGreaterThanEnd = std.debug.no_panic.startGreaterThanEnd;
    pub const inactiveUnionField = std.debug.no_panic.inactiveUnionField;
    pub const sliceCastLenRemainder = std.debug.no_panic.sliceCastLenRemainder;
    pub const reachedUnreachable = std.debug.no_panic.reachedUnreachable;
    pub const unwrapNull = std.debug.no_panic.unwrapNull;
    pub const castToNull = std.debug.no_panic.castToNull;
    pub const incorrectAlignment = std.debug.no_panic.incorrectAlignment;
    pub const invalidErrorCode = std.debug.no_panic.invalidErrorCode;
    pub const integerOutOfBounds = std.debug.no_panic.integerOutOfBounds;
    pub const integerOverflow = std.debug.no_panic.integerOverflow;
    pub const shlOverflow = std.debug.no_panic.shlOverflow;
    pub const shrOverflow = std.debug.no_panic.shrOverflow;
    pub const divideByZero = std.debug.no_panic.divideByZero;
    pub const exactDivisionRemainder = std.debug.no_panic.exactDivisionRemainder;
    pub const integerPartOutOfBounds = std.debug.no_panic.integerPartOutOfBounds;
    pub const corruptSwitch = std.debug.no_panic.corruptSwitch;
    pub const shiftRhsTooBig = std.debug.no_panic.shiftRhsTooBig;
    pub const invalidEnumValue = std.debug.no_panic.invalidEnumValue;
    pub const forLenMismatch = std.debug.no_panic.forLenMismatch;
    pub const copyLenMismatch = std.debug.no_panic.copyLenMismatch;
    pub const memcpyAlias = std.debug.no_panic.memcpyAlias;
    pub const noreturnReturned = std.debug.no_panic.noreturnReturned;
};

/// 关掉 segfault handler（其 dumpSegfaultInfo → std.debug 打印 → debug_io →
/// Io.Threaded 全家桶）与 256KB 的备用信号栈；崩溃排查交给内核 coredump。
/// logFn 同理换成纯 syscall 实现（默认 defaultLog 也走 debug_io）。
pub const std_options: std.Options = .{
    .enable_segfault_handler = false,
    .signal_stack_size = null,
    .logFn = minimalLog,
};

/// 切断 std.debug 的默认 Io：不设此项时 start.zig 会无条件初始化
/// Io.Threaded.global_single_threaded（拉入 864B 实例 + File.Writer
/// drain/sendFile ~1.7KB）。monitor 从不用 std.debug 的 Io 路径。
pub const std_options_debug_threaded_io: ?*std.Io.Threaded = null;

fn minimalLog(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    _ = scope;
    _ = format;
    _ = args;
    // 只输出级别标签，不带格式化（避免拉入 fmt 完整机架与 debug_io）；
    // 业务日志统一走 log.zig，此处仅兼容 std 内部可能的 std.log 调用。
    sys.writeAll(2, "[std.log." ++ @tagName(level) ++ "]\n") catch {};
}
