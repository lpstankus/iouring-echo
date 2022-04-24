const std = @import("std");
const RingBuffer = @import("ring_buffer.zig").RingBuffer;

pub const ConnID = u32;

const log = std.log.scoped(.conn);
const os = std.os;

const INVALID_FD = -1;
const MAX_CONNECTIONS = 512;

var alloc: std.mem.Allocator = undefined;
pub var bufs: [MAX_CONNECTIONS]RingBuffer = undefined;
pub var socks = [_]os.socket_t{INVALID_FD} ** MAX_CONNECTIONS;

pub fn init() !void {
    for (bufs) |*buf, i| buf.* = RingBuffer.init() catch |err| {
        for (bufs[0..i]) |b| b.deinit();
        return err;
    };
}

pub fn deinit() void {
    for (bufs) |buf| buf.deinit();
    for (socks) |sock| if (sock != INVALID_FD) os.closeSocket(sock);
}

pub inline fn add(sock: os.socket_t) error{ConnectionsLimitReached}!ConnID {
    for (socks) |*s, i| {
        if (s.* == INVALID_FD) {
            s.* = sock;
            log.info("new connection (id: {}, socket: {})", .{ i, sock });
            return @intCast(u32, i);
        }
    }
    return error.ConnectionsLimitReached;
}

pub inline fn remove(id: ConnID) void {
    if (socks[id] != INVALID_FD) {
        os.closeSocket(socks[id]);
        log.info("closed connection (id: {}, socket: {})", .{ id, socks[id] });
        socks[id] = INVALID_FD;
    }
    bufs[id].len = 0;
}
