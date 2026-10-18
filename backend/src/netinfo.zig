//! 通过 rtnetlink 同步 dump 链路/地址/默认路由,选出"推荐 IP":
//! 走默认路由、非虚拟网卡、优先私网 IPv4。逻辑源自 decky-scope monitor 的 netlink.zig。
const std = @import("std");
const sys = @import("sys.zig");
const src = @import("source.zig");

const RTM_GETLINK = 18;
const RTM_GETADDR = 22;
const RTM_GETROUTE = 26;

pub const Link = struct { index: u32 = 0, flags: u32 = 0, name: [16]u8 = @splat(0) };
pub const Address = struct { index: u32 = 0, family: u8 = 0, scope: u8 = 0, flags: u32 = 0, bytes: [16]u8 = @splat(0) };
pub const Route = struct { index: u32 = 0, family: u8 = 0, metric: u32 = 0 };

pub const Table = struct {
    links: [64]Link = @splat(.{}),
    link_count: usize = 0,
    addresses: [128]Address = @splat(.{}),
    address_count: usize = 0,
    routes: [64]Route = @splat(.{}),
    route_count: usize = 0,

    /// 依次 dump 三类对象;任何一步失败返回 null(调用方当作"网络信息不可用")。
    pub fn load(self: *Table) ?void {
        const fd = sys.routeSocket() catch return null;
        defer sys.close(fd);
        var buf: [32768]u8 = undefined;
        const kinds = [_]u16{ RTM_GETLINK, RTM_GETADDR, RTM_GETROUTE };
        for (kinds, 1..) |kind, seq| {
            sys.routeDump(fd, kind, @intCast(seq)) catch return null;
            self.drain(fd, @intCast(seq), &buf) catch return null;
        }
    }

    fn drain(self: *Table, fd: i32, seq: u32, buf: []u8) !void {
        // 有界:正常 dump 几个数据报就结束,防止异常内核行为卡死
        for (0..64) |_| {
            const n = try sys.recv(fd, buf);
            if (try self.messages(buf[0..n], seq)) return;
        }
        return error.TooManyMessages;
    }

    /// 解析一个数据报;遇到 NLMSG_DONE 返回 true。
    pub fn messages(self: *Table, data: []const u8, seq: u32) !bool {
        var pos: usize = 0;
        while (pos + 16 <= data.len) {
            const len = u32at(data[pos..], 0);
            if (len < 16 or len > data.len - pos) return error.InvalidMessage;
            const msg = data[pos..][0..len];
            pos += align4(len);
            if (u32at(msg, 8) != seq) continue;
            switch (u16at(msg, 4)) {
                2 => return error.KernelError, // NLMSG_ERROR
                3 => return true, // NLMSG_DONE
                16 => self.link(msg),
                20 => self.address(msg),
                24 => self.route(msg),
                else => {},
            }
        }
        return false;
    }

    fn link(self: *Table, msg: []const u8) void {
        if (msg.len < 32 or self.link_count == self.links.len) return;
        var l = Link{ .index = u32at(msg, 20), .flags = u32at(msg, 24) };
        var attrs = Attributes{ .data = msg[32..] };
        while (attrs.next()) |a| if (a.kind == 3) { // IFLA_IFNAME
            const name = src.str(a.data);
            @memcpy(l.name[0..@min(15, name.len)], name[0..@min(15, name.len)]);
        };
        self.links[self.link_count] = l;
        self.link_count += 1;
    }

    fn address(self: *Table, msg: []const u8) void {
        if (msg.len < 24 or (msg[16] != 2 and msg[16] != 10) or self.address_count == self.addresses.len) return;
        var addr = Address{ .family = msg[16], .flags = msg[18], .scope = msg[19], .index = u32at(msg, 20) };
        const width: usize = if (addr.family == 2) 4 else 16;
        var found = false;
        var local = false;
        var attrs = Attributes{ .data = msg[24..] };
        while (attrs.next()) |a| {
            // IFA_ADDRESS / IFA_LOCAL;点对点链路上 LOCAL 才是本机地址
            if ((a.kind == 1 or a.kind == 2) and a.data.len >= width and (!local or a.kind == 2)) {
                @memcpy(addr.bytes[0..width], a.data[0..width]);
                found = true;
                if (a.kind == 2) local = true;
            }
            if (a.kind == 8 and a.data.len >= 4) addr.flags = u32at(a.data, 0); // IFA_FLAGS
        }
        if (!found) return;
        self.addresses[self.address_count] = addr;
        self.address_count += 1;
    }

    fn route(self: *Table, msg: []const u8) void {
        // 只要默认路由(dst_len = 0)的单播路由
        if (msg.len < 28 or msg[17] != 0 or msg[23] != 1 or self.route_count == self.routes.len) return;
        var r = Route{ .family = msg[16] };
        var table: u32 = msg[20];
        var attrs = Attributes{ .data = msg[28..] };
        while (attrs.next()) |a| {
            if (a.data.len < 4) continue;
            if (a.kind == 4) r.index = u32at(a.data, 0); // RTA_OIF
            if (a.kind == 6) r.metric = u32at(a.data, 0); // RTA_PRIORITY
            if (a.kind == 15) table = u32at(a.data, 0); // RTA_TABLE
        }
        if (table != 254 or r.index == 0) return; // main 表
        self.routes[self.route_count] = r;
        self.route_count += 1;
    }

    pub fn findLink(self: *const Table, index: u32) ?*const Link {
        for (self.links[0..self.link_count]) |*l| if (l.index == index) return l;
        return null;
    }

    fn usable(self: *const Table, index: u32) bool {
        const l = self.findLink(index) orelse return false;
        return l.flags & 1 != 0 and !virtual(src.str(&l.name)); // IFF_UP
    }

    fn defaultMetric(self: *const Table, addr: Address) ?u32 {
        var metric: ?u32 = null;
        for (self.routes[0..self.route_count]) |r| {
            if (r.index == addr.index and r.family == addr.family) metric = @min(metric orelse std.math.maxInt(u32), r.metric);
        }
        return metric;
    }

    pub fn recommended(self: *const Table) ?Address {
        var best: ?Address = null;
        var best_score: u8 = 255;
        var best_metric: u32 = std.math.maxInt(u32);
        for (self.addresses[0..self.address_count]) |addr| {
            if (!eligible(addr) or !self.usable(addr.index)) continue;
            const m = self.defaultMetric(addr) orelse continue;
            // 同族里有更优先的默认路由走别的网卡时,这个地址不是出口
            var shadowed = false;
            for (self.routes[0..self.route_count]) |r| {
                if (r.family == addr.family and r.metric < m and self.usable(r.index)) shadowed = true;
            }
            if (shadowed) continue;
            const score: u8 = if (addr.family == 2 and private4(addr.bytes)) 0 else if (addr.family == 10 and addr.bytes[0] & 0xfe == 0xfc) 1 else 2;
            if (best == null or score < best_score or (score == best_score and m < best_metric)) {
                best = addr;
                best_score = score;
                best_metric = m;
            }
        }
        return best;
    }
};

const Attribute = struct { kind: u16, data: []const u8 };
const Attributes = struct {
    data: []const u8,
    fn next(self: *Attributes) ?Attribute {
        if (self.data.len < 4) return null;
        const len = u16at(self.data, 0);
        if (len < 4 or len > self.data.len) {
            self.data = "";
            return null;
        }
        const out: Attribute = .{ .kind = u16at(self.data, 2) & 0x3fff, .data = self.data[4..len] };
        self.data = self.data[@min(align4(len), self.data.len)..];
        return out;
    }
};

fn u16at(b: []const u8, i: usize) u16 {
    return std.mem.readInt(u16, b[i..][0..2], .little);
}
fn u32at(b: []const u8, i: usize) u32 {
    return std.mem.readInt(u32, b[i..][0..4], .little);
}
fn align4(n: usize) usize {
    return (n + 3) & ~@as(usize, 3);
}

fn virtual(name: []const u8) bool {
    inline for (.{ "lo", "tun", "tap", "wg", "docker", "veth", "virbr", "tailscale", "Cloudflare" }) |prefix| {
        if (std.mem.startsWith(u8, name, prefix)) return true;
    }
    return false;
}

fn private4(a: [16]u8) bool {
    return a[0] == 10 or (a[0] == 172 and a[1] >= 16 and a[1] <= 31) or (a[0] == 192 and a[1] == 168);
}

fn eligible(a: Address) bool {
    if (a.scope != 0 or a.flags & (0x20 | 0x40 | 0x08) != 0) return false; // deprecated/tentative/DAD failed
    if (a.family == 2) return a.bytes[0] != 0 and a.bytes[0] != 127 and a.bytes[0] < 224 and !(a.bytes[0] == 169 and a.bytes[1] == 254);
    return a.family == 10 and a.flags & 1 == 0 and a.bytes[0] != 0xff and !(a.bytes[0] == 0xfe and a.bytes[1] & 0xc0 == 0x80) and !std.mem.allEqual(u8, a.bytes[0..15], 0);
}

pub fn format(buf: []u8, a: Address) []const u8 {
    if (a.family == 2) return std.mem.print(buf, "{d}.{d}.{d}.{d}", .{ a.bytes[0], a.bytes[1], a.bytes[2], a.bytes[3] }) catch "";
    var w = std.Io.Writer.fixed(buf);
    for (0..8) |i| {
        if (i > 0) w.writeByte(':') catch return "";
        w.print("{x}", .{std.mem.readInt(u16, a.bytes[i * 2 ..][0..2], .big)}) catch return "";
    }
    return w.buffered();
}

fn ipv4(a: u8, b: u8, c: u8, d: u8) [16]u8 {
    return .{ a, b, c, d } ++ @as([12]u8, @splat(0));
}

test "address filtering respects scope, loopback and DAD" {
    var a = Address{ .family = 2, .bytes = ipv4(192, 168, 1, 2) };
    try std.testing.expect(eligible(a));
    a.flags = 0x40;
    try std.testing.expect(!eligible(a));
    a.flags = 0;
    a.bytes[0] = 127;
    try std.testing.expect(!eligible(a));
}

test "recommended picks default-route private address on a real interface" {
    var t = Table{};
    t.links[0] = .{ .index = 2, .flags = 1, .name = "wlan0".* ++ @as([11]u8, @splat(0)) };
    t.links[1] = .{ .index = 3, .flags = 1, .name = "docker0".* ++ @as([9]u8, @splat(0)) };
    t.link_count = 2;
    t.addresses[0] = .{ .index = 3, .family = 2, .bytes = ipv4(172, 17, 0, 1) };
    t.addresses[1] = .{ .index = 2, .family = 2, .bytes = ipv4(192, 168, 1, 155) };
    t.address_count = 2;
    t.routes[0] = .{ .index = 2, .family = 2, .metric = 600 };
    t.route_count = 1;
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("192.168.1.155", format(&buf, t.recommended().?));
}

test "malformed netlink lengths are rejected" {
    var t = Table{};
    var bytes: [16]u8 = @splat(0);
    bytes[0] = 40;
    try std.testing.expectError(error.InvalidMessage, t.messages(&bytes, 1));
}
