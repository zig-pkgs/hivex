const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const t = target.result;
    const config_h = b.addConfigHeader(.{
        .style = .{ .autoconf = b.path("upstream/config.h.in") },
        .include_path = "config.h",
    }, .{
        .ENABLE_NLS = 1,
        .HAVE_BINDTEXTDOMAIN = 1,
        .HAVE_BYTESWAP_H = 1,

        .HAVE_CAML_ALLOC_INITIALIZED_STRING = null,
        .HAVE_CAML_RAISE_WITH_ARGS = null,
        .HAVE_CAML_UNIXSUPPORT_H = null,
        .HAVE_CFLOCALECOPYPREFERREDLANGUAGES = null,
        .HAVE_CFPREFERENCESCOPYAPPVALUE = null,

        .HAVE_DCGETTEXT = 1,
        .HAVE_DLFCN_H = 1,
        .HAVE_ENDIAN_H = 1,
        .HAVE_GETTEXT = 1,
        .HAVE_ICONV = 1,
        .HAVE_INTTYPES_H = 1,
        .HAVE_LIBINTL_H = 1,
        .HAVE_LIBREADLINE = 1,
        .HAVE_MMAP = 1,
        .HAVE_RB_HASH_LOOKUP = null,
        .HAVE_STDINT_H = 1,
        .HAVE_STDIO_H = 1,
        .HAVE_STDLIB_H = 1,
        .HAVE_STRINGS_H = 1,
        .HAVE_STRING_H = 1,
        .HAVE_SYS_STAT_H = 1,
        .HAVE_SYS_TYPES_H = 1,
        .HAVE_UNISTD_H = 1,
        .ICONV_CONST = {},
        .LT_OBJDIR = ".libs/",
        .PACKAGE = "hivex",
        .PACKAGE_BUGREPORT = "",
        .PACKAGE_NAME = "hivex",
        .PACKAGE_STRING = "hivex 1.3.23",
        .PACKAGE_TARNAME = "hivex",
        .PACKAGE_URL = "",
        .PACKAGE_VERSION = "1.3.23",
        .PACKAGE_VERSION_EXTRA = "",
        .PACKAGE_VERSION_MAJOR = 1,
        .PACKAGE_VERSION_MINOR = 3,
        .PACKAGE_VERSION_RELEASE = 23,
        .PROTOTYPES = 1,
        .SIZEOF_LONG = t.c_type_byte_size(.long),
        .STDC_HEADERS = 1,
        .VERSION = "1.3.23",
        ._FILE_OFFSET_BITS = null,
        ._LARGE_FILES = null,
        .__PROTOTYPES = 1,
    });
    const lib = b.addStaticLibrary(.{
        .name = "hivex",
        .link_libc = true,
        .target = target,
        .optimize = optimize,
    });
    lib.addIncludePath(b.path("upstream/gnulib/lib"));
    lib.addIncludePath(b.path("upstream/lib"));
    lib.addIncludePath(b.path("upstream/include"));
    lib.addCSourceFiles(.{
        .root = b.path("upstream"),
        .files = &libgnu_src,
        .flags = &.{},
    });
    lib.addCSourceFiles(.{
        .root = b.path("upstream"),
        .files = &hivex_src,
        .flags = &.{},
    });
    lib.addConfigHeader(config_h);
    lib.installHeader(b.path("upstream/include/hivex.h"), "hivex.h");
    b.installArtifact(lib);

    const lib_unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/root.zig" },
        .target = target,
        .optimize = optimize,
    });
    lib_unit_tests.linkLibrary(lib);

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}

const libgnu_src = [_][]const u8{
    "gnulib/lib/full-read.c",
    "gnulib/lib/full-write.c",
    "gnulib/lib/safe-read.c",
    "gnulib/lib/safe-write.c",
    "gnulib/lib/xstrtol.c",
    "gnulib/lib/xstrtoll.c",
    "gnulib/lib/xstrtoul.c",
    "gnulib/lib/xstrtoull.c",
    "gnulib/lib/xstrtoumax.c",
};

const hivex_src = [_][]const u8{
    "lib/handle.c",
    "lib/node.c",
    "lib/offset-list.c",
    "lib/utf16.c",
    "lib/util.c",
    "lib/value.c",
    "lib/visit.c",
    "lib/write.c",
};
