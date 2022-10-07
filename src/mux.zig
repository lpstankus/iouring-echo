const std = @import("std");
const conn = @import("conn.zig");
const RingBuffer = @import("ring_buffer.zig").RingBuffer;

const assert = std.debug.assert;
const log = std.log.scoped(.mux);
const os = std.os;
const linux = os.linux;

var client_addr: linux.sockaddr = undefined;
var client_addrlen: linux.socklen_t = undefined;

var uring: linux.IO_Uring = undefined;
var cqe_buffer = [_]linux.io_uring_cqe{.{ .user_data = 0, .res = 0, .flags = 0 }} ** 1024;

const MuxErr = error{
    BadUring,
    ConnectionsLimitReached,
    Interrupted,
    NotSupported,
    OutOfMemory,
    SystemResources,
    Unexpected,
};

fn uringError(err: anyerror) MuxErr {
    return switch (err) {
        error.FileDescriptorInBadState,
        error.FileDescriptorInvalid,
        error.SubmissionQueueEntryInvalid,
        error.BufferInvalid,
        => error.BadUring,
        error.SignalInterrupt => error.Interrupted,
        error.SystemResources, error.CompletionQueueOvercommitted => error.SystemResources,
        else => blk: {
            log.warn("found unexpected error: {s}, stack trace dumped", .{@errorName(err)});
            std.debug.dumpCurrentStackTrace(null);
            break :blk error.Unexpected;
        },
    };
}

fn connError(err: anyerror) MuxErr {
    return switch (err) {
        error.Unexpected, error.AccessDenied => error.Unexpected,
        error.NotSupported, error.SystemOutdated => error.NotSupported,
        error.OutOfMemory, error.SystemResources => |e| e,
    };
}

const MuxOps = enum { accept, send, recv };
const UringContext = union(MuxOps) {
    accept: linux.fd_t,
    send: conn.ConnID,
    recv: conn.ConnID,
};

pub fn init() !void {
    uring = try linux.IO_Uring.init(1024, 0);
}

pub fn deinit() void {
    uring.deinit();
}

pub fn handleUpdates() MuxErr!void {
    const completions = uring.copy_cqes(&cqe_buffer, 0) catch |err| return uringError(err);
    for (cqe_buffer[0..completions]) |cqe| {
        if (cqe.err() != .SUCCESS) {
            log.warn("skipped completion, error code: {}", .{cqe.res});
            continue;
        }
        try handleCompletion(cqe);
    }
    _ = uring.submit() catch |err| return uringError(err);
}

fn handleCompletion(cqe: linux.io_uring_cqe) MuxErr!void {
    const context = @bitCast(UringContext, cqe.user_data);
    switch (context) {
        .accept => |list_sock| {
            const new_sock = if (cqe.res > 0) cqe.res else return;
            const id = try conn.add(new_sock);
            try uringRecv(id);
            try uringAccept(list_sock);
        },
        .send => |id| {
            if (cqe.res <= 0) return conn.remove(id);
            conn.bufs[id].commitPop(@intCast(usize, cqe.res)) catch return error.Unexpected;
            try uringRecv(id);
        },
        .recv => |id| {
            if (cqe.res <= 0) return conn.remove(id);
            conn.bufs[id].commitPush(@intCast(usize, cqe.res)) catch return error.Unexpected;
            try uringSend(id);
        },
    }
}

inline fn uringSubmit() MuxErr!u32 {
    return uring.submit() catch |err| return uringError(err);
}

pub inline fn uringAccept(sock: linux.fd_t) MuxErr!void {
    var union_ctx = UringContext{ .accept = sock };
    const ctx = @ptrCast(*u64, @alignCast(8, &union_ctx));
    _ = uring.accept(ctx.*, sock, &client_addr, &client_addrlen, 0) catch {
        _ = try uringSubmit();
        _ = uring.accept(ctx.*, sock, &client_addr, &client_addrlen, 0) catch return error.Unexpected;
    };
}

inline fn uringSend(id: conn.ConnID) MuxErr!void {
    var union_ctx = UringContext{ .send = id };
    const ctx = @ptrCast(*u64, @alignCast(8, &union_ctx));
    const sock = conn.socks[id];
    const buf = conn.bufs[id].slice();

    _ = uring.send(ctx.*, sock, buf, 0) catch {
        _ = try uringSubmit();
        _ = uring.send(ctx.*, sock, buf, 0) catch return error.Unexpected;
    };
}

inline fn uringRecv(id: conn.ConnID) MuxErr!void {
    var union_ctx = UringContext{ .recv = id };
    const ctx = @ptrCast(*u64, @alignCast(8, &union_ctx));
    const sock = conn.socks[id];
    const buf = conn.bufs[id].availSlice();

    _ = uring.recv(ctx.*, sock, buf, 0) catch {
        _ = try uringSubmit();
        _ = uring.recv(ctx.*, sock, buf, 0) catch return error.Unexpected;
    };
}
