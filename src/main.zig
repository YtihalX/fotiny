//! By convention, main.zig is where your main function lives in the case that
//! you are building an executable. If you are making a library, the convention
//! is to delete this file and start with root.zig instead.

pub fn main() !void {
    std.debug.print("=================================\n", .{});
    std.debug.print("Work/Break Notification System\n", .{});
    std.debug.print("=================================\n", .{});
    std.debug.print("• Regular reminders: every 5-8 minutes (random)\n", .{});
    std.debug.print("• Break time: every 90 minutes\n", .{});
    std.debug.print("• Break duration: 20 minutes\n", .{});
    std.debug.print("• Press Ctrl+C to stop\n", .{});
    std.debug.print("=================================\n\n", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var notifier = lib.NotifierSystem.init(allocator);

    try notifier.run();
    // notifier.stop();
    std.debug.print("\n✓ Notifier stopped cleanly.\n", .{});
}



test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // Try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}

test "use other module" {
    try std.testing.expectEqual(@as(i32, 150), lib.add(100, 50));
}

test "fuzz example" {
    const Context = struct {
        fn testOne(context: @This(), input: []const u8) anyerror!void {
            _ = context;
            // Try passing `--fuzz` to `zig build test` and see if it manages to fail this test case!
            try std.testing.expect(!std.mem.eql(u8, "canyoufindme", input));
        }
    };
    try std.testing.fuzz(Context{}, Context.testOne, .{});
}

const std = @import("std");

/// This imports the separate module containing `root.zig`. Take a look in `build.zig` for details.
const lib = @import("fotiny_lib");
