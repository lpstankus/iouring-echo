const std = @import("std");
const builtin = @import("builtin");
const c = @import("c.zig");
const conn = @import("conn.zig");
const mux = @import("mux.zig");

const os = std.os;

fn initListenSocket(port: u16) !os.socket_t {
    const socket = try os.socket(os.AF.INET, os.SOCK.STREAM, 0);
    var server_addr = os.sockaddr.in{
        .family = os.AF.INET,
        .addr = std.mem.nativeToBig(u32, c.INADDR_ANY),
        .port = std.mem.nativeToBig(u16, port),
    };
    try os.bind(socket, @ptrCast(*os.sockaddr, &server_addr), @sizeOf(@TypeOf(server_addr)));
    try os.listen(socket, 10);

    std.log.info("socket opened in port {}", .{port});

    return socket;
}

pub fn main() anyerror!void {
    comptime if (builtin.os.tag != .linux) return error.UnsupportedOS;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer {
        if (gpa.deinit()) os.exit(1);
        std.log.info("exited with no leaks!", .{});
    }

    var args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const port = if (args.len < 2) blk: {
        std.log.info("no port number given, opening on 8000", .{});
        break :blk 8000;
    } else try std.fmt.parseInt(u16, args[1], 0);
    _ = port;

    const socket = try initListenSocket(port);
    defer os.closeSocket(socket);

    try conn.init();
    defer conn.deinit();

    try mux.init();
    defer mux.deinit();

    try mux.uringAccept(socket);

    while (true) try mux.handleUpdates();
}

test "main tests" {
    _ = @import("ring_buffer.zig");
}
