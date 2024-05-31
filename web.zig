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

const CheckVersionCb = ?*const fn (*anyopaque, bool) callconv(.C) void;
const DownloadCb = ?*const fn (*anyopaque, [*]u8, usize) callconv(.C) void;

const Updater = struct {
    url: []const u8,
    arena_impl: *Arena,
    arena: std.mem.Allocator = undefined,

    name: []const u8,
    /// Version to query against
    version: std.SemanticVersion,

    cb: CheckVersionCb,

    app: App = undefined,
};

const App = struct {
    version: []const u8,
    changes: []const u8,
    bin: struct {
        macos: ?[]const u8 = null,
        windows: ?[]const u8 = null,
        linux: ?[]const u8 = null,
    },
};

const DownloadOptions = extern struct {
    cb: DownloadCb,
    chunk_size: c_int,
    sha256: [*:0]const u8,
};

export fn updater_init(
    url: [*:0]const u8,
    name: [*:0]const u8,
    current_version: [*:0]const u8,
    cb: CheckVersionCb,
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
        .cb = cb,
    };

    updater.arena_impl.* = Arena.init(std.heap.raw_c_allocator);
    updater.arena = updater.arena_impl.allocator();

    return updater;
}

export fn updater_deinit(u: ?*Updater) void {
    if (u) |updater| {
        updater.arena_impl.deinit();
    } else fatal_error(error.UpdaterNull);
}

export fn updater_fetch(u: ?*Updater) void {
    if (u) |updater| {
        var fetch_thread = std.Thread.spawn(.{}, fetch_async, .{updater}) catch |e|
            fatal_error(e);
        fetch_thread.detach();
    } else fatal_error(error.UpdaterNull);
}

export fn updater_get_bin_url(u: ?*Updater) [*:0]const u8 {
    if (u) |updater| {
        switch (builtin.os.tag) {
            .macos => {
                if (updater.app.bin.macos) |macos|
                    return (std.mem.concatWithSentinel(updater.arena, u8, &.{macos}, 0) catch |e|
                        fatal_error(e)).ptr;
                return "MacOS bin not found";
            },
            .linux => {
                if (updater.app.bin.linux) |linux|
                    return (std.mem.concatWithSentinel(updater.arena, u8, &.{linux}, 0) catch |e|
                        fatal_error(e)).ptr;
                return "Linux bin not found";
            },
            .windows => {
                if (updater.app.bin.windows) |windows|
                    return (std.mem.concatWithSentinel(updater.arena, u8, &.{windows}, 0) catch |e|
                        fatal_error(e)).ptr;
                return "Windows bin not found";
            },
            else => @panic("Unsupported OS"),
        }
    }

    return "Updater is null";
}

export fn updater_download_bin(u: ?*Updater, url: [*:0]const u8, options: DownloadOptions) void {
    if (u) |updater| {
        var dl_thread = std.Thread.spawn(
            .{},
            download_async,
            .{ updater, span(url), options },
        ) catch |e|
            fatal_error(e);
        dl_thread.detach();
    } else fatal_error(error.UpdaterIsNull);
}

fn fetch_async(u: *Updater) !void {
    defer {
        std.Thread.yield() catch |e| std.log.err("{!}\n", .{e});
    }

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
    const json_value = parsed.value;
    const plugin_json = json_value.object.get(u.name) orelse {
        std.log.err("Name {s} not found\n", .{u.name});
        return error.NameNotFound;
    };
    const parsed_plugin = try json.parseFromValue(App, u.arena, plugin_json, .{});
    defer parsed_plugin.deinit();
    const plugin: App = parsed_plugin.value;

    u.app = plugin;

    const new_version = try std.SemanticVersion.parse(plugin.version);
    const needs_update = std.SemanticVersion.order(new_version, u.version).compare(.gt);

    if (u.cb) |func| {
        func(u, needs_update);
    } else return error.NoCallback;
}

fn parseToValue(allocator: std.mem.Allocator, str: []const u8) !json.Parsed(json.Value) {
    return try json.parseFromSlice(json.Value, allocator, str, .{});
}

fn download_async(u: *Updater, url: []const u8, options: DownloadOptions) !void {
    defer {
        std.Thread.yield() catch |e| std.log.err("{!}\n", .{e});
    }

    var client = Client{ .allocator = u.arena };
    defer client.deinit();

    const uri = try std.Uri.parse(url);

    var server_header_buffer = [_]u8{0} ** 4096;

    var req = try client.open(
        .GET,
        uri,
        .{ .server_header_buffer = &server_header_buffer },
    );
    defer req.deinit();

    try req.send();
    try req.wait();
    const buf = try req.reader().readAllAlloc(u.arena, 1 << 32);
    defer u.arena.free(buf);

    std.debug.print("Response: \n{s}\n", .{buf});

    if (options.cb) |func|
        func(u, buf.ptr, buf.len)
    else
        return error.NoCallback;
}
