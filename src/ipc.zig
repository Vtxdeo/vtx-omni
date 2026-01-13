const std = @import("std");

pub const Envelope = struct {
    v: u8,
    t: []const u8,
    id: ?[]const u8 = null,
    p: std.json.Value,
};

pub const DependencyRequest = struct {
    name: []u8,
    profile: []u8,
    version: []u8,

    pub fn deinit(self: *DependencyRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.profile);
        allocator.free(self.version);
    }
};

pub fn parseSystemRequest(allocator: std.mem.Allocator, line: []const u8) !?DependencyRequest {
    const parsed = try std.json.parseFromSlice(Envelope, allocator, line, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    if (!std.mem.eql(u8, parsed.value.t, "SYS_REQ_DEPENDENCY")) {
        return null;
    }

    const payload = parsed.value.p;
    const obj = switch (payload) {
        .object => |o| o,
        else => return null,
    };

    const name = try dupField(allocator, obj, "name") orelse return null;
    errdefer allocator.free(name);
    const profile = try dupField(allocator, obj, "profile") orelse return null;
    errdefer allocator.free(profile);
    const version = try dupField(allocator, obj, "version") orelse return null;

    return DependencyRequest{
        .name = name,
        .profile = profile,
        .version = version,
    };
}

fn dupField(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    key: []const u8,
) !?[]u8 {
    const value = obj.get(key) orelse return null;
    const str = switch (value) {
        .string => |s| s,
        else => return null,
    };
    return allocator.dupe(u8, str);
}
