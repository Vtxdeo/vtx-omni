const std = @import("std");
const process = std.process;
const fs = std.fs;
const downloader = @import("downloader");
const ipc = @import("ipc");

fn log(comptime format: []const u8, args: anytype) void {
    std.debug.print("[Omni] " ++ format ++ "\n", args);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const base_core_path = "bin/vtx-core";
    const core_path = blk: {
        fs.cwd().access(base_core_path, .{}) catch {
            if (@import("builtin").os.tag == .windows) {
                const windows_path = base_core_path ++ ".exe";
                fs.cwd().access(windows_path, .{}) catch |err| {
                    log("FATAL: Could not find core binary at '{s}' or '{s}': {}", .{
                        base_core_path,
                        windows_path,
                        err,
                    });
                    log("Please copy the compiled 'vtx-core' to 'vtx-omni/bin/'", .{});
                    return err;
                };
                break :blk windows_path;
            }
            const err = error.FileNotFound;
            log("FATAL: Could not find core binary at '{s}': {}", .{ base_core_path, err });
            log("Please copy the compiled 'vtx-core' to 'vtx-omni/bin/'", .{});
            return err;
        };
        break :blk base_core_path;
    };

    log("Starting Vtx-Core Supervisor...", .{});

    const argv = [_][]const u8{core_path};
    var child = std.process.Child.init(&argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stdin_behavior = .Pipe;
    child.stderr_behavior = .Inherit;

    var env_map = try process.getEnvMap(allocator);
    defer env_map.deinit();
    const ffmpeg_path = "E:\\Code\\Rust\\vtxdeo\\vtx-omni\\zig-out\\bin\\vtx-ffprobe-v0.1.0-win-x86_64-full.exe";
    env_map.put("VTX_FFMPEG_BIN", ffmpeg_path) catch |err| {
        log("Failed to set VTX_FFMPEG_BIN: {}", .{err});
        return err;
    };
    child.env_map = &env_map;

    try child.spawn();
    log("Core spawned (PID: {?})", .{child.id});

    const reader_thread = try std.Thread.spawn(.{}, monitorCoreOutput, .{&child});
    reader_thread.detach();

    while (true) {
        const term = try child.wait();
        switch (term) {
            .Exited => |code| {
                log("Core exited with code {d}", .{code});
                break;
            },
            .Signal => |sig| {
                log("Core killed by signal {d}", .{sig});
                break;
            },
            .Stopped => |sig| {
                log("Core stopped by signal {d}", .{sig});
                break;
            },
            .Unknown => |code| {
                log("Core exited with unknown state {d}", .{code});
                break;
            },
        }
    }
}

fn monitorCoreOutput(child: *std.process.Child) void {
    if (child.stdout == null) return;

    const allocator = std.heap.page_allocator;
    var reader = child.stdout.?.deprecatedReader();
    var line_buf: [4096]u8 = undefined;

    while (true) {
        const line = reader.readUntilDelimiterOrEof(&line_buf, '\n') catch |err| {
            if (err == error.EndOfStream) break;
            log("Error reading from core: {}", .{err});
            break;
        };

        if (line) |l| {
            if (l.len == 0) continue;
            const req_opt = ipc.parseSystemRequest(allocator, l) catch |err| {
                log("Failed to parse IPC message: {}", .{err});
                continue;
            };
            if (req_opt) |req| {
                defer req.deinit(allocator);
                if (std.mem.eql(u8, req.name, "ffmpeg")) {
                    const asset_base = "vtx-ffmpeg";
                    const options = downloader.DownloadOptions{
                        .version = req.version,
                        .asset_base = asset_base,
                        .profile = req.profile,
                    };
                    const asset_name = downloader.buildAssetName(allocator, options) catch |err| {
                        log("Failed to build asset name: {}", .{err});
                        continue;
                    };
                    defer allocator.free(asset_name);

                    const dest_path = std.fmt.allocPrint(allocator, "bin/{s}", .{asset_name}) catch |err| {
                        log("Failed to build destination path: {}", .{err});
                        continue;
                    };
                    defer allocator.free(dest_path);

                    if (downloader.ensureDownloaded(allocator, dest_path, options)) {
                        log("Dependency downloaded: {s}", .{dest_path});
                    } else |err| {
                        log("Dependency download failed: {}", .{err});
                    }
                } else {
                    log("Unsupported dependency request: {s}", .{req.name});
                }
                continue;
            }
            log("<< RECV IPC: {s}", .{l});
        } else {
            break;
        }
    }

    log("Core output stream closed", .{});
}
