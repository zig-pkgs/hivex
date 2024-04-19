const std = @import("std");
const mem = std.mem;
const posix = std.posix;
const builtin = @import("builtin");
const native_endian = builtin.cpu.arch.endian();
const c = @cImport(@cInclude("hivex.h"));
const hivex = @This();
const testing = std.testing;

pub const Hive = struct {
    handle: *c.hive_h,

    pub const Type = enum(c_uint) {
        none = 0,
        string = 1,
        expand_string = 2,
        binary = 3,
        dword = 4,
        dword_be = 5,
        link = 6,
        multiple_strings = 7,
        resource_list = 8,
        full_resource_description = 9,
        resource_requirements_list = 10,
        qword = 11,
    };

    pub const Value = union(enum) {
        none: struct {
            key: []const u8,
        },
        dword: struct {
            key: []const u8,
            value: i32,
        },
        qword: struct {
            key: []const u8,
            value: i64,
        },
        string: struct {
            key: []const u8,
            value: []const u8,
        },
        expand_string: struct {
            key: []const u8,
            value: []const u8,
        },
        hex: struct {
            key: []const u8,
            type: Type,
            value: []const u8,
        },

        pub const ConvertError = error{
            InvalidUtf8,
        } || mem.Allocator.Error || std.fmt.ParseIntError;

        pub fn convert(self: Value, gpa: mem.Allocator) ConvertError!c.hive_set_value {
            var val: c.hive_set_value = undefined;
            switch (self) {
                .none => |v| {
                    val.key = try gpa.dupeZ(u8, v.key);
                    val.len = 0;
                },
                .hex => |v| {
                    val.len = 0;
                    val.t = @intFromEnum(v.type);
                    const alloc_len = v.value.len / 3 + 1;
                    val.key = try gpa.dupeZ(u8, v.key);
                    val.value = try gpa.allocSentinel(u8, alloc_len, '\x00');
                    var it = mem.tokenize(u8, v.value, ",");
                    while (it.next()) |raw| {
                        const hex = try std.fmt.parseInt(u8, raw, 16);
                        val.value[val.len] = hex;
                        val.len += 1;
                    }
                },
                inline .string, .expand_string => |v, t| {
                    val.key = try gpa.dupeZ(u8, v.key);
                    const utf16 = try std.unicode.utf8ToUtf16LeAllocZ(gpa, v.value);
                    const ptr: [*]u8 = @ptrCast(utf16.ptr);
                    const slice = ptr[0 .. utf16.len * 2 + 1 :0];
                    val.value = slice;
                    val.len = slice.len + 1;
                    val.t = @intFromEnum(@field(Type, @tagName(t)));
                },
                inline .dword, .qword => |v, t| {
                    val.len = @sizeOf(@TypeOf(v.value));
                    val.key = try gpa.dupeZ(u8, v.key);
                    const n = blk: {
                        switch (native_endian) {
                            .little => break :blk v.value,
                            .big => break :blk @byteSwap(v.value),
                        }
                    };
                    val.value = try gpa.dupeZ(u8, mem.asBytes(&n));
                    val.t = @intFromEnum(@field(Type, @tagName(t)));
                },
            }
            return val;
        }
    };

    pub const Node = struct {
        handle: c.hive_node_h,
        hive: *c.hive_h,

        pub fn getName(self: *Node) []const u8 {
            const name = c.hivex_node_name(self.hive, self.handle);
            const len = c.hivex_node_name_len(self.hive, self.handle);
            return name[0..len];
        }

        pub fn addChild(self: *Node, name: [:0]const u8) Node {
            return .{
                .hive = self.hive,
                .handle = c.hivex_node_add_child(self.hive, self.handle, name),
            };
        }

        pub const GetChildError = error{
            ChildNotFound,
        } || posix.UnexpectedError;

        pub fn getChild(self: *Node, name: [:0]const u8) GetChildError!Node {
            const child = c.hivex_node_get_child(self.hive, self.handle, name);
            if (child == 0) {
                switch (posix.errno(-1)) {
                    .SUCCESS => return error.ChildNotFound,
                    else => |err| return posix.unexpectedErrno(err),
                }
            }
            return .{ .hive = self.hive, .handle = child };
        }

        pub const GetValueError = posix.UnexpectedError;

        pub fn getValue(self: *Node, key: [:0]const u8) GetValueError!Value {
            var len: usize = 0;
            var t: c.hive_type = undefined;
            const val = c.hivex_node_get_value(self.hive, self.handle, key);
            const rc = c.hivex_value_type(self.hive, val, &t, &len);
            switch (posix.errno(rc)) {
                .SUCCESS => {},
                else => |err| return posix.unexpectedErrno(err),
            }
            switch (@as(Type, @enumFromInt(t))) {
                .none => return .{ .none = .{ .key = key } },
                inline .string, .expand_string => |tag| {
                    const valueFn = c.hivex_value_string;
                    return @unionInit(Value, @tagName(tag), .{
                        .key = key,
                        .value = valueFn(self.hive, val)[0..len],
                    });
                },
                inline .dword, .qword => |tag| {
                    const valueFn = @field(c, "hivex_value_" ++ @tagName(tag));
                    return @unionInit(Value, @tagName(tag), .{
                        .key = key,
                        .value = valueFn(self.hive, val),
                    });
                },
                // TODO: support all types of value
                inline else => |tag| @panic("Unsupported type: " ++ @tagName(tag)),
            }
        }

        pub const SetValuesError = error{
            InvalidUtf8,
        } || posix.UnexpectedError || Value.ConvertError || mem.Allocator.Error;

        pub fn setValues(self: *Node, values: []const Value) SetValuesError!void {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const gpa = arena.allocator();
            var vals_list = std.ArrayList(c.hive_set_value).init(gpa);
            for (values) |v| {
                try vals_list.append(try v.convert(gpa));
            }
            const zero = comptime mem.zeroes(c.hive_set_value);
            const vals = try vals_list.toOwnedSliceSentinel(zero);
            const rc = c.hivex_node_set_values(
                self.hive,
                self.handle,
                vals.len,
                vals.ptr,
                0,
            );
            switch (posix.errno(rc)) {
                .SUCCESS => return,
                .NOMEM => return error.OutOfMemory,
                else => |err| return posix.unexpectedErrno(err),
            }
        }

        pub const SetValueError = error{
            InvalidUtf8,
        } || posix.UnexpectedError || Value.ConvertError;

        pub fn setValue(self: *Node, value: Value) SetValueError!void {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const gpa = arena.allocator();
            var val = try value.convert(gpa);
            const rc = c.hivex_node_set_value(self.hive, self.handle, &val, 0);
            switch (posix.errno(rc)) {
                .SUCCESS => return,
                .NOMEM => return error.OutOfMemory,
                else => |err| return posix.unexpectedErrno(err),
            }
        }
    };

    pub const OpenFlags = packed struct(c_int) {
        verbose: u1 = 0,
        debug: u1 = 0,
        write: u1 = 0,
        unsafe: u1 = 0,
        reserved: std.meta.Int(.unsigned, @bitSizeOf(c_int) - 4) = 0,
    };

    pub const OpenError = error{
        OutOfMemory,
    } || posix.OpenError || posix.UnexpectedError;

    pub fn open(path: [:0]const u8, flags: OpenFlags) OpenError!Hive {
        return .{
            .handle = c.hivex_open(path, @bitCast(flags)) orelse {
                switch (posix.errno(-1)) {
                    .SUCCESS => unreachable,
                    .NOMEM => return error.OutOfMemory,
                    else => |err| return posix.unexpectedErrno(err),
                }
            },
        };
    }

    pub fn close(self: *Hive) void {
        _ = c.hivex_close(self.handle);
    }

    pub fn root(self: *Hive) Node {
        return .{
            .hive = self.handle,
            .handle = c.hivex_root(self.handle),
        };
    }

    const CommitError = posix.OpenError || posix.WriteError;

    pub fn commit(self: *Hive, path: [:0]const u8) CommitError!void {
        const rc = c.hivex_commit(self.handle, path, 0);
        switch (posix.errno(rc)) {
            .SUCCESS => {},
            else => |err| return posix.unexpectedErrno(err),
        }
    }
};

test "open flags" {
    inline for (@typeInfo(Hive.OpenFlags).Struct.fields) |field| {
        var flags: Hive.OpenFlags = .{};
        @field(flags, field.name) = 1;
        comptime var field_name: [field.name.len]u8 = undefined;
        inline for (field.name, 0..) |char, i| {
            field_name[i] = comptime std.ascii.toUpper(char);
        }
        const field_name_c = "HIVEX_OPEN_" ++ field_name;
        if (@hasField(c, field_name_c)) {
            const expected = @field(c, field_name_c);
            const flags_c_int: c_int = @bitCast(flags);
            try testing.expectEqual(expected, flags_c_int);
        }
    }
}

test "just header" {
    var h = try Hive.open("upstream/images/minimal", .{ .write = 1 });
    defer h.close();

    var root = h.root();
    try testing.expectEqualStrings("$$$PROTO.HIV", root.getName());
    var node = root.addChild("This");
    try node.setValues(&.{
        .{
            .string = .{ .key = "a", .value = "ABCD" },
        },
        .{
            .hex = .{
                .key = "b",
                .type = .string,
                .value = "41,00,42,00,43,00,44,00,00,00",
            },
        },
        .{
            .dword = .{ .key = "c", .value = 200000 },
        },
    });
    const child = try root.getChild("This");
    try testing.expectEqual(node.handle, (child.handle));
    const value_a = (try node.getValue("a")).string.value;
    const value_b = (try node.getValue("b")).string.value;
    const value_c = (try node.getValue("c")).dword.value;
    try testing.expectEqual(200000, value_c);
    try testing.expectEqualSlices(u8, value_a, value_b);
    try h.commit("/tmp/hivex-test");
    defer std.fs.cwd().deleteFile("/tmp/hivex-test") catch {};
}
