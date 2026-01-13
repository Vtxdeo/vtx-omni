const std = @import("std");
const builtin = @import("builtin");

pub const DownloadOptions = struct {
    owner: []const u8 = "vtxdeo",
    repo: []const u8 = "vtx-ffmpeg-release",
    version: []const u8 = "v0.1.0",
    asset_base: []const u8 = "vtx-ffmpeg",
    profile: []const u8 = "full",
};

pub fn ensureDownloaded(allocator: std.mem.Allocator, dest_path: []const u8, options: DownloadOptions) !void {
    std.fs.cwd().access(dest_path, .{}) catch {
        try downloadReleaseAsset(allocator, dest_path, options);
        return;
    };
}

pub fn downloadReleaseAsset(allocator: std.mem.Allocator, dest_path: []const u8, options: DownloadOptions) !void {
    if (std.fs.path.dirname(dest_path)) |dir| {
        try std.fs.cwd().makePath(dir);
    }

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const asset_name = try buildAssetName(allocator, options);
    defer allocator.free(asset_name);

    const url = try std.fmt.allocPrint(
        allocator,
        "https://github.com/{s}/{s}/releases/download/{s}/{s}",
        .{ options.owner, options.repo, options.version, asset_name },
    );
    defer allocator.free(url);

    var file = try std.fs.cwd().createFile(dest_path, .{ .truncate = true });
    defer file.close();

    var writer_buf: [16 * 1024]u8 = undefined;
    var file_writer = file.writer(&writer_buf);

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &file_writer.interface,
    });

    if (result.status != .ok) {
        return error.DownloadFailed;
    }

    if (builtin.os.tag != .windows) {
        const perms = std.fs.File.Permissions.unixNew(0o755);
        try file.setPermissions(perms);
    }
}

pub fn buildAssetName(allocator: std.mem.Allocator, options: DownloadOptions) ![]u8 {
    const os_tag = osTagString();
    const arch = archString();
    const ext = if (builtin.os.tag == .windows) ".exe" else "";
    return std.fmt.allocPrint(
        allocator,
        "{s}-{s}-{s}-{s}-{s}{s}",
        .{ options.asset_base, options.version, os_tag, arch, options.profile, ext },
    );
}

fn osTagString() []const u8 {
    return switch (builtin.os.tag) {
        .windows => "win",
        .linux => "linux",
        .macos => "macos",
        .freebsd => "freebsd",
        .openbsd => "openbsd",
        else => @tagName(builtin.os.tag),
    };
}

fn archString() []const u8 {
    return switch (builtin.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        .x86 => "x86",
        .arm => "arm",
        else => @tagName(builtin.cpu.arch),
    };
}
