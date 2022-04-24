const std = @import("std");

const os = std.os;
const page_size = std.mem.page_size;

pub const InitError = error{
    Unexpected,
    AccessDenied,
    OutOfMemory,
    SystemResources,
    NotSupported,
    SystemOutdated,
} || os.UnexpectedError;

fn mapRingBufferToTempFile(fd: os.fd_t, sz: usize) os.MMapError![]align(page_size) u8 {
    const buf = try os.mmap(null, sz * 2, os.PROT.NONE, os.MAP.PRIVATE | os.MAP.ANONYMOUS, -1, 0);
    const sec_buf = @alignCast(page_size, buf[sz..].ptr);
    errdefer os.munmap(buf);

    _ = try os.mmap(buf.ptr, sz, os.PROT.READ | os.PROT.WRITE, os.MAP.SHARED | os.MAP.FIXED, fd, 0);
    _ = try os.mmap(sec_buf, sz, os.PROT.READ | os.PROT.WRITE, os.MAP.SHARED | os.MAP.FIXED, fd, 0);

    return buf;
}

pub const RingBuffer = struct {
    fd: os.fd_t,
    len: u16 = 0,
    pos: u16 = 0,
    data: []align(page_size) u8,

    pub const SIZE: u16 = page_size;

    pub fn init() InitError!RingBuffer {
        comptime std.debug.assert(SIZE % page_size == 0); // SIZE has to be multiple of page size

        const fd = os.memfd_create("ring buffer memory", 0) catch |err| return switch (err) {
            error.NameTooLong => unreachable,
            error.SystemFdQuotaExceeded, error.ProcessFdQuotaExceeded => error.SystemResources,
            error.SystemOutdated => error.SystemOutdated,
            error.OutOfMemory => error.OutOfMemory,
            error.Unexpected => error.Unexpected,
        };
        errdefer os.close(fd);

        os.ftruncate(fd, SIZE) catch |err| return switch (err) {
            error.InputOutput, error.FileBusy, error.AccessDenied => unreachable,
            error.FileTooBig => error.OutOfMemory,
            error.Unexpected => error.Unexpected,
        };

        const data = mapRingBufferToTempFile(fd, SIZE) catch |err| return switch (err) {
            error.AccessDenied,
            error.PermissionDenied,
            error.LockedMemoryLimitExceeded,
            => unreachable,
            error.MemoryMappingNotSupported => error.NotSupported,
            error.OutOfMemory => error.OutOfMemory,
            error.Unexpected => error.Unexpected,
        };
        std.mem.set(u8, data, 0);

        return RingBuffer{ .fd = fd, .data = data };
    }

    pub fn deinit(buf: RingBuffer) void {
        os.munmap(buf.data);
        os.close(buf.fd);
    }

    pub inline fn slice(buf: RingBuffer) []const u8 {
        return buf.data[buf.pos .. buf.pos + buf.len];
    }

    pub inline fn sizedSlice(buf: RingBuffer, size: usize) []const u8 {
        std.debug.assert(size <= buf.len);
        return buf.data[buf.pos .. buf.pos + size];
    }

    pub inline fn availSlice(buf: RingBuffer) []u8 {
        return buf.data[buf.pos + buf.len .. buf.pos + SIZE];
    }

    pub fn push(buf: *RingBuffer, data: []const u8) usize {
        std.debug.assert(buf.pos < SIZE);
        std.debug.assert(buf.len <= SIZE);

        const sz = @minimum(SIZE - buf.len, data.len);
        std.mem.copy(u8, buf.data[buf.pos .. buf.pos + sz], data[0..sz]);
        buf.len += @intCast(u16, sz);
        return sz;
    }

    pub fn commitPush(buf: *RingBuffer, size: usize) error{NotEnoughSpace}!void {
        std.debug.assert(buf.pos < SIZE);
        std.debug.assert(buf.len <= SIZE);

        if (SIZE - buf.len < size) return error.NotEnoughSpace;
        buf.len += @intCast(u16, size);
    }

    pub fn commitPop(buf: *RingBuffer, size: usize) error{NotEnoughSpace}!void {
        std.debug.assert(buf.pos < SIZE);
        std.debug.assert(buf.len <= SIZE);

        if (buf.len < size) return error.NotEnoughSpace;
        buf.pos = (buf.pos + @intCast(u16, size)) % SIZE;
        buf.len -= @intCast(u16, size);
    }
};

test "RingBuffer operations" {
    const testing = std.testing;

    var buffer = try RingBuffer.init(); // one memory page
    defer buffer.deinit();
    {
        try testing.expectEqual(@as(usize, 0), buffer.pos);
        try testing.expectEqual(@as(usize, 0), buffer.len);
        try testing.expectEqual(@as(usize, page_size), RingBuffer.SIZE);
        try testing.expectEqual(@as(usize, page_size * 2), buffer.data.len);
    }

    const string: []const u8 = "something to be written";
    var sz = buffer.push(string);
    var pos: usize = 0;
    {
        try testing.expectEqual(string.len, sz);
        try testing.expectEqual(@as(usize, pos), buffer.pos);
        try testing.expectEqual(string.len, buffer.len);
        try testing.expectEqualSlices(u8, string, buffer.slice());
        try testing.expectEqualSlices(
            u8,
            &([_]u8{0} ** (page_size - string.len)),
            buffer.availSlice(),
        );
    }

    try buffer.commitPop(sz);
    pos += string.len;
    {
        try testing.expectEqual(@as(usize, pos), buffer.pos);
        try testing.expectEqual(@as(usize, 0), buffer.len);
    }

    const small_filler: []const u8 = &[_]u8{'A'} ** (page_size);
    sz = buffer.push(small_filler);
    {
        try testing.expectEqual(@as(usize, page_size), sz);
        try testing.expectEqual(@as(usize, pos), buffer.pos);
        try testing.expectEqual(@as(usize, page_size), buffer.len);
        try testing.expectEqualSlices(u8, small_filler, buffer.slice());
        try testing.expectEqualSlices(u8, &[_]u8{}, buffer.availSlice());
    }

    sz = buffer.push(string);
    {
        try testing.expectEqual(@as(usize, 0), sz);
        try testing.expectEqual(@as(usize, pos), buffer.pos);
        try testing.expectEqual(@as(usize, page_size), buffer.len);
        try testing.expectEqualSlices(u8, small_filler, buffer.slice());
        try testing.expectEqualSlices(u8, &[_]u8{}, buffer.availSlice());
    }

    try buffer.commitPop(page_size / 2);
    pos = (pos + (page_size / 2)) % page_size;
    {
        try testing.expectEqual(@as(usize, pos), buffer.pos);
        try testing.expectEqual(@as(usize, page_size / 2), buffer.len);
    }

    try buffer.commitPop(page_size / 2);
    pos = (pos + page_size / 2) % page_size;
    {
        try testing.expectEqual(@as(usize, pos), buffer.pos);
        try testing.expectEqual(@as(usize, 0), buffer.len);
        try testing.expectEqualSlices(u8, &[_]u8{}, buffer.slice());
        try testing.expectEqualSlices(u8, small_filler, buffer.availSlice());
    }
}
