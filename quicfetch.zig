const std = @import("std");
const builtin = @import("builtin");
const debug_build = builtin.mode == .Debug;

fn fatal_error(err: anyerror) noreturn {
    std.log.err("{!}\n", .{err});
    std.process.exit(1);
}

const Arena = std.heap.ArenaAllocator;

const span = std.mem.span;

const Client = std.http.Client;
const Header = std.http.Client.Request.Headers;

const json = std.json;

const Hash = std.crypto.hash.sha2.Sha256;

const CheckVersionCb = ?*const fn (*anyopaque, bool) callconv(.C) void;
const DownloadProgressCb = ?*const fn (*anyopaque, read: usize, total: usize) callconv(.C) void;
const DownloadFinishedCb = ?*const fn (*anyopaque, ok: bool, size: usize) callconv(.C) void;

const Updater = struct {
    url: []const u8,
    arena_impl: *Arena,
    arena: std.mem.Allocator = undefined,

    name: []const u8,
    /// Version to query against
    version: std.SemanticVersion,

    app: App = undefined,

    /// Undefined until updater_fetch() is called
    fetch_thread: std.Thread = undefined,
    /// Undefined until updater_download_bin() is called
    dl_thread: std.Thread = undefined,
};

const App = struct {
    version: []const u8,
    changes: []const u8,
    bin: struct {
        macos: ?BinInfo = null,
        windows: ?BinInfo = null,
        linux: ?BinInfo = null,
    },

    pub fn getBinForOS(self: App) !BinInfo {
        switch (builtin.os.tag) {
            .macos => return self.bin.macos orelse error.NoBin,
            .linux => return self.bin.linux orelse error.NoBin,
            .windows => return self.bin.windows orelse error.NoBin,
            else => @panic("Unsupported OS"),
        }
    }
};

const BinInfo = struct {
    url: []const u8,
    /// SHA256
    checksum: []const u8,
};

const DownloadOptions = extern struct {
    progress: DownloadProgressCb,
    finished: DownloadFinishedCb,
    dest_dir: ?[*:0]const u8,
    chunk_size: c_int,
};

export fn updater_init(
    url: [*:0]const u8,
    name: [*:0]const u8,
    current_version: [*:0]const u8,
) ?*Updater {
    const updater = std.heap.c_allocator.create(Updater) catch |e|
        fatal_error(e);
    updater.* = .{
        .url = span(url),
        .arena_impl = std.heap.c_allocator.create(Arena) catch |e|
            fatal_error(e),
        .name = span(name),
        .version = std.SemanticVersion.parse(span(current_version)) catch |e|
            fatal_error(e),
    };

    updater.arena_impl.* = Arena.init(std.heap.raw_c_allocator);
    updater.arena = updater.arena_impl.allocator();

    return updater;
}

export fn updater_deinit(u: ?*Updater) void {
    if (u) |updater| {
        updater.fetch_thread.join();
        updater.dl_thread.join();
        updater.arena_impl.deinit();
    } else fatal_error(error.UpdaterNull);
}

export fn updater_fetch(u: ?*Updater, cb: CheckVersionCb) void {
    if (u) |updater| {
        const fetch_thread = std.Thread.spawn(
            .{},
            fetchWrapper,
            .{ updater, cb },
        ) catch |e|
            fatal_error(e);
        updater.fetch_thread = fetch_thread;
    } else fatal_error(error.UpdaterNull);
}

/// Uses OS-appropriate URL
export fn updater_download_bin(u: ?*Updater, options: DownloadOptions) void {
    if (u) |updater| {
        const dl_thread = std.Thread.spawn(
            .{},
            downloadWrapper,
            .{ updater, options },
        ) catch |e|
            fatal_error(e);
        updater.dl_thread = dl_thread;
    } else fatal_error(error.UpdaterIsNull);
}

fn fetchWrapper(u: *Updater, cb: CheckVersionCb) void {
    fetchAsync(u, cb) catch |e| {
        std.log.err("Fetch: {!}\n", .{e});
    };
    // std.Thread.yield() catch |e| std.log.err("{!}\n", .{e});
}

fn fetchAsync(u: *Updater, cb: CheckVersionCb) !void {
    var client = Client{ .allocator = u.arena };
    defer client.deinit();

    var buf = std.ArrayList(u8).init(u.arena);
    defer buf.deinit();

    const res = try client.fetch(
        .{
            .location = .{ .url = u.url },
            .response_storage = .{ .dynamic = &buf },
        },
    );

    if (res.status != .ok) {
        const name = res.status.phrase() orelse @tagName(res.status);
        std.log.err("Connection failed: {d}: {s}", .{ @intFromEnum(res.status), name });
        return error.ConnectionFailed;
    }

    const parsed = try parseToValue(u.arena, buf.items);
    defer parsed.deinit();
    const plugin_json = parsed.value.object.get(u.name) orelse {
        std.log.err("Name {s} not found\n", .{u.name});
        return error.NameNotFound;
    };
    const parsed_plugin = try json.parseFromValue(App, u.arena, plugin_json, .{});
    defer parsed_plugin.deinit();
    const plugin: App = parsed_plugin.value;

    u.app = plugin;

    const new_version = try std.SemanticVersion.parse(plugin.version);
    const needs_update = std.SemanticVersion.order(new_version, u.version).compare(.gt);

    if (cb) |func| {
        func(u, needs_update);
    } else return error.NoCallback;
}

fn parseToValue(allocator: std.mem.Allocator, str: []const u8) !json.Parsed(json.Value) {
    return try json.parseFromSlice(json.Value, allocator, str, .{});
}

fn downloadWrapper(
    u: *Updater,
    options: DownloadOptions,
) void {
    downloadAsync(u, options) catch |e| {
        std.log.err("Download: {!}\n", .{e});
    };
    // std.Thread.yield() catch |e| std.log.err("{!}\n", .{e});
}

fn downloadAsync(
    u: *Updater,
    options: DownloadOptions,
) !void {
    const bin = u.app.getBinForOS() catch |e| {
        fatal_error(e);
    };
    // For my own edification, I'd like to know why I have to dupe this and the
    // checksum. We don't delete `url` and `checksum` during the lifetime of
    // this thread, right? So why does its memory get invalidated during this fn?...
    const url = try u.arena.dupe(u8, bin.url);
    const filename = std.fs.path.basename(url);
    const checksum = try u.arena.dupe(u8, bin.checksum);

    const dest_dir = span(options.dest_dir) orelse try std.fs.cwd().realpathAlloc(u.arena, ".");

    var client = Client{ .allocator = u.arena };
    defer client.deinit();

    const uri = try std.Uri.parse(url);

    var server_header_buffer = [_]u8{0} ** 512;

    var req = try client.open(
        .GET,
        uri,
        .{ .server_header_buffer = &server_header_buffer },
    );
    defer req.deinit();

    try req.send();
    try req.wait();
    const res = req.response;
    if (res.status != .ok) {
        const name = res.status.phrase() orelse @tagName(res.status);
        std.log.err("Connection failed: {d}: {s}", .{ @intFromEnum(res.status), name });
        return error.ConnectionFailed;
    }
    const content_type = res.content_type orelse "null";
    std.debug.print("Content-type: {s}\n", .{content_type});
    const size = res.content_length orelse 0;

    const buf = try u.arena.alloc(
        u8,
        std.math.ceilPowerOfTwoAssert(usize, size),
    );
    defer u.arena.free(buf);

    var bytes_read: usize = 0;
    while (bytes_read < size) {
        bytes_read += try req.reader().readAtLeast(buf[bytes_read..], @intCast(options.chunk_size));
        if (options.progress) |func|
            func(u, bytes_read, size);
    }

    if (bytes_read != size) {
        std.log.err("Couldn't read full buffer\n", .{});
        if (options.finished) |func|
            func(u, false, bytes_read);
    }

    std.debug.print("Checking hash...\n", .{});
    var hash: [Hash.digest_length]u8 = undefined;
    Hash.hash(buf[0..bytes_read], &hash, .{});
    if (!checkHash(u.arena, checksum, &hash)) {
        std.log.err("Hashes don't match\nExpected: {s}\n", .{
            checksum,
        });
        if (options.finished) |func|
            func(u, false, bytes_read);
        return error.BadHash;
    }
    std.debug.print("Hash OK\n", .{});

    var dest = std.fs.openDirAbsolute(dest_dir, .{}) catch |e| {
        std.log.err("{!}\n", .{e});
        if (options.finished) |func|
            func(u, false, bytes_read);
        return e;
    };
    defer dest.close();
    dest.writeFile2(.{ .sub_path = filename, .data = buf[0..bytes_read] }) catch |e| {
        std.log.err("{!}\n", .{e});
        if (options.finished) |func|
            func(u, false, bytes_read);
        return e;
    };

    if (options.finished) |func|
        func(u, true, bytes_read);
}

fn checkHash(allocator: std.mem.Allocator, expected: []const u8, hash: []const u8) bool {
    const expected_bytes = allocator.alloc(u8, expected.len / 2) catch @panic("OOM");
    for (expected_bytes, 0..) |*r, i| {
        r.* = std.fmt.parseInt(u8, expected[2 * i .. 2 * i + 2], 16) catch |e| {
            std.log.err("Int parse failed: {s}\n", .{@errorName(e)});
            return false;
        };
    }
    return std.mem.eql(u8, expected_bytes, hash);
}