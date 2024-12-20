const std = @import("std");
const mem = std.mem;
const builtin = @import("builtin");
const SourceLocation = std.builtin.SourceLocation;
const debug_build = builtin.mode == .Debug;

fn debugPrint(comptime fmt: []const u8, args: anytype, comptime src: SourceLocation) void {
    if (!debug_build) {
        return;
    }
    std.debug.print("(quicfetch): {s}:fn {s}|{d}: " ++ fmt, .{
        src.file,
        src.fn_name,
        src.line,
    } ++ args);
}

fn logError(err: anyerror, comptime src: SourceLocation) void {
    std.log.err("(quicfetch): {s}:fn {s}|{d}: {s}\n", .{
        src.file,
        src.fn_name,
        src.line,
        @errorName(err),
    });
}

const Arena = std.heap.ArenaAllocator;

const span = std.mem.span;

const Client = std.http.Client;
const Header = std.http.Client.Request.Headers;

const json = std.json;

const Hash = std.crypto.hash.sha2.Sha256;

const CheckVersionCb = ?*const fn (*anyopaque, bool, ?*anyopaque) callconv(.C) void;
const DownloadProgressCb = ?*const fn (*anyopaque, read: usize, total: usize, ?*anyopaque) callconv(.C) void;
const DownloadFinishedCb = ?*const fn (*anyopaque, ok: bool, size: usize, ?*anyopaque) callconv(.C) void;

const Updater = struct {
    url: []const u8,
    arena_impl: *Arena,
    arena: std.mem.Allocator = undefined,

    name: []const u8,
    /// Version to query against
    version: std.SemanticVersion,

    app: App = undefined,

    msg_buf: [256]u8 = .{0} ** 256,

    user_data: ?*anyopaque = null,

    /// Undefined until updater_fetch() is called
    fetch_thread: std.Thread = undefined,
    /// Undefined until updater_download_bin() is called
    dl_thread: std.Thread = undefined,

    fn writeMessage(u: *Updater, comptime fmt: []const u8, args: anytype) void {
        @memset(&u.msg_buf, 0);
        _ = std.fmt.bufPrintZ(&u.msg_buf, fmt, args) catch |e| {
            logError(e, @src());
        };
    }

    pub fn getBinForOS(self: *Updater) !BinInfo {
        const app = self.app;
        switch (builtin.os.tag) {
            .macos => return app.bin.macos orelse {
                self.writeMessage("MacOS bin not found", .{});
                return error.BinNotFound;
            },
            .linux => return app.bin.linux orelse {
                self.writeMessage("Linux bin not found", .{});
                return error.BinNotFound;
            },
            .windows => return app.bin.windows orelse {
                self.writeMessage("Windows bin not found", .{});
                return error.BinNotFound;
            },
            else => @panic("Unsupported OS"),
        }
    }
};

// struct corresponding to a plugin entry in the JSON response
const App = struct {
    version: []const u8,
    changes: []const u8,
    bin: struct {
        macos: ?BinInfo = null,
        windows: ?BinInfo = null,
        linux: ?BinInfo = null,
    },
};

const BinInfo = struct {
    url: []const u8,
    /// SHA256
    checksum: []const u8,
};

const DownloadOptions = extern struct {
    progress: DownloadProgressCb,
    finished: DownloadFinishedCb,
    dest_file: ?[*:0]const u8,
    chunk_size: c_int,
};

export fn updater_init(
    url: [*:0]const u8,
    name: [*:0]const u8,
    current_version: [*:0]const u8,
    user_data: ?*anyopaque,
) ?*Updater {
    debugPrint("Initializing updater for plugin {s} with URL: {s}\n", .{
        name,
        url,
    }, @src());
    const updater = std.heap.c_allocator.create(Updater) catch |e| {
        logError(e, @src());
        return null;
    };
    updater.* = .{
        .url = span(url),
        .arena_impl = std.heap.c_allocator.create(Arena) catch |e| {
            logError(e, @src());
            return null;
        },
        .name = span(name),
        .version = std.SemanticVersion.parse(span(current_version)) catch |e| {
            logError(e, @src());
            return null;
        },
        .user_data = user_data,
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
        std.heap.c_allocator.destroy(updater);
    } else logError(error.UpdaterNull, @src());
}

export fn updater_fetch(u: ?*Updater, cb: CheckVersionCb) void {
    if (u) |updater| {
        const fetch_thread = std.Thread.spawn(
            .{},
            fetchAsyncCatchError,
            .{ updater, cb },
        ) catch |e| {
            updater.writeMessage("Error: {s}\n", .{@errorName(e)});
            return;
        };
        updater.fetch_thread = fetch_thread;
    } else logError(error.UpdaterNull, @src());
}

/// Uses OS-appropriate URL
export fn updater_download_bin(u: ?*Updater, options: DownloadOptions) void {
    if (u) |updater| {
        const dl_thread = std.Thread.spawn(
            .{},
            downloadAsyncCatchError,
            .{ updater, options },
        ) catch |e| {
            updater.writeMessage("Error: {s}\n", .{@errorName(e)});
            return;
        };
        updater.dl_thread = dl_thread;
    } else logError(error.UpdaterNull, @src());
}

export fn updater_get_message(u: ?*Updater) [*]const u8 {
    if (u) |updater| {
        return (&updater.msg_buf).ptr;
    } else {
        logError(error.UpdaterNull, @src());
        return "Error: Updater is null";
    }
}

fn fetchAsyncCatchError(u: *Updater, cb: CheckVersionCb) void {
    fetchAsync(u, cb) catch |e| {
        u.writeMessage("Error fetching update: {s}\n", .{@errorName(e)});
        if (cb) |func|
            func(u, false, u.user_data);
    };
}

fn fetchAsync(u: *Updater, cb: CheckVersionCb) !void {
    var client = Client{ .allocator = u.arena };
    defer client.deinit();

    var buf = std.ArrayList(u8).init(u.arena);
    defer buf.deinit();

    const res = try client.fetch(.{
        .location = .{ .url = u.url },
        .response_storage = .{ .dynamic = &buf },
    });

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

    if (needs_update) {
        u.writeMessage(
            \\Version: {s}
            \\Changes:
            \\{s}
        , .{
            plugin.version,
            plugin.changes,
        });
    } else {
        u.writeMessage("Plugin is up-to-date", .{});
    }

    if (cb) |func| {
        func(u, needs_update, u.user_data);
    } else return error.NoCallback;
}

fn parseToValue(allocator: std.mem.Allocator, str: []const u8) !json.Parsed(json.Value) {
    return try json.parseFromSlice(json.Value, allocator, str, .{});
}

fn downloadAsyncCatchError(
    u: *Updater,
    options: DownloadOptions,
) void {
    downloadAsync(u, options) catch |e| {
        u.writeMessage("Error downloading update: {s}\n", .{@errorName(e)});
        if (options.finished) |func| {
            func(u, false, 0, u.user_data);
        }
    };
}

fn downloadAsync(
    u: *Updater,
    options: DownloadOptions,
) !void {
    const bin = try u.getBinForOS();
    // For my own edification, I'd like to know why I have to dupe this and the
    // checksum. We don't delete `url` and `checksum` during the lifetime of
    // this thread, right? So why does its memory get invalidated during this fn?...
    const url = try u.arena.dupe(u8, bin.url);
    const checksum = try u.arena.dupe(u8, bin.checksum);

    const dest_file = span(options.dest_file) orelse blk: {
        const basename = std.fs.path.basename(bin.url);
        _ = try std.fs.cwd().createFile(basename, .{});
        break :blk try std.fs.cwd().realpathAlloc(u.arena, basename);
    };

    var client = Client{ .allocator = u.arena };
    defer client.deinit();

    const uri = try std.Uri.parse(url);

    var server_header_buffer = [_]u8{0} ** 512;

    debugPrint("Connecting to {s}\n", .{url}, @src());
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
    const size = res.content_length orelse 0;

    const buf = try u.arena.alloc(
        u8,
        std.math.ceilPowerOfTwoAssert(usize, size),
    );
    defer u.arena.free(buf);

    // read bytes into memory
    var bytes_read: usize = 0;
    while (bytes_read < size) {
        bytes_read += try req.reader().readAtLeast(buf[bytes_read..], @intCast(options.chunk_size));
        // call user progress function
        if (options.progress) |func|
            func(u, bytes_read, size, u.user_data);
    }

    if (bytes_read != size) {
        std.log.err("Couldn't read full buffer\n", .{});
        u.writeMessage("Error downloading update: Couldn't read full data buffer", .{});
        if (options.finished) |func|
            func(u, false, bytes_read, u.user_data);
    }

    // verify checksum
    debugPrint("Checking hash...\n", .{}, @src());
    var hash: [Hash.digest_length]u8 = undefined;
    Hash.hash(buf[0..bytes_read], &hash, .{});
    if (!checkHash(u.arena, checksum, &hash)) {
        std.log.err("Hashes don't match\nExpected: {s}\n", .{
            checksum,
        });
        if (options.finished) |func|
            func(u, false, bytes_read, u.user_data);
        return error.BadHash;
    }
    debugPrint("Hash OK\n", .{}, @src());

    // save buffer to file
    debugPrint("Saving file to: {s}\n", .{dest_file}, @src());
    var file = std.fs.createFileAbsolute(dest_file, .{}) catch |e| {
        std.log.err("{!}\n", .{e});
        if (options.finished) |func|
            func(u, false, bytes_read, u.user_data);
        return e;
    };
    defer file.close();
    file.writeAll(buf) catch |e| {
        std.log.err("{!}\n", .{e});
        if (options.finished) |func|
            func(u, false, bytes_read, u.user_data);
        return e;
    };

    if (options.finished) |func|
        func(u, true, bytes_read, u.user_data);
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

const ActivationInfo = struct {
    url: []const u8,
    license: []const u8,
    api_key: []const u8,
    on_activation: *const fn (bool, [*]const u8, usize, ?*anyopaque) callconv(.C) void,
    user_data: ?*anyopaque,

    fn writeMessage(comptime fmt: []const u8, args: anytype) [:0]const u8 {
        var buf: [256]u8 = .{0} ** 256;
        return std.fmt.bufPrintZ(&buf, fmt, args) catch |e| {
            logError(e, @src());
            return "Buffer write error";
        };
    }
};

const ActivationResponse = struct {
    success: bool,
    Item: struct {
        product: []const u8,
        orderNum: []const u8,
        license: []const u8,
        activationCount: u32,
        maxActivations: u32,
    },
    message: []const u8,
};

/// url must end in '/' for the request to work
export fn activation_check(
    url: [*:0]const u8,
    license: [*:0]const u8,
    api_key: [*:0]const u8,
    cb: *const fn (bool, [*]const u8, usize, ?*anyopaque) callconv(.C) void,
    user_data: ?*anyopaque,
) void {
    const activate_thread = std.Thread.spawn(
        .{},
        activateAsyncCatchError,
        .{.{
            .url = span(url),
            .license = span(license),
            .api_key = span(api_key),
            .on_activation = cb,
            .user_data = user_data,
        }},
    ) catch |e| {
        logError(e, @src());
        return;
    };
    activate_thread.detach();
}

fn activateAsyncCatchError(info: ActivationInfo) void {
    activateAsync(info) catch |e| {
        logError(e, @src());
        const msg = ActivationInfo.writeMessage("Activation failed: {!}", .{e});
        info.on_activation(false, msg.ptr, msg.len, info.user_data);
    };
}

fn activateAsync(info: ActivationInfo) !void {
    var arena_impl = std.heap.ArenaAllocator.init(std.heap.raw_c_allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    var client = Client{ .allocator = arena };
    defer client.deinit();

    var buf = std.ArrayList(u8).init(arena);
    defer buf.deinit();

    const res = try client.fetch(.{
        .location = .{ .url = try mem.concat(arena, u8, &.{ info.url, info.license }) },
        .response_storage = .{ .dynamic = &buf },
        .extra_headers = &.{
            .{ .name = "x-api-key", .value = info.api_key },
        },
    });

    debugPrint("Activation response:\n{s}\n", .{buf.items}, @src());

    if (res.status != .ok) {
        logError(error.ConnectionFailed, @src());
        const msg = ActivationInfo.writeMessage("Activation failed: {s}\n", .{@tagName(res.status)});
        info.on_activation(false, msg.ptr, msg.len, info.user_data);
        return;
    }

    const parsed = try parseToValue(arena, buf.items);
    defer parsed.deinit();

    const parsed_response = try json.parseFromValue(ActivationResponse, arena, parsed.value, .{});
    defer parsed_response.deinit();
    const response = parsed_response.value;

    if (response.success) {
        const msg = ActivationInfo.writeMessage("Activation successful\n", .{});
        info.on_activation(true, msg.ptr, msg.len, info.user_data);
    } else {
        const msg = ActivationInfo.writeMessage("Activation failed: {s}\n", .{response.message});
        info.on_activation(false, msg.ptr, msg.len, info.user_data);
        return;
    }
}
