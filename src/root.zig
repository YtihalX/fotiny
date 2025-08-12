//! By convention, root.zig is the root source file when making a library. If
//! you are making an executable, the convention is to delete this file and
//! start with main.zig instead.
const std = @import("std");
const c = @cImport({
    @cInclude("libnotify/notify.h");
});
const testing = std.testing;

const avatar_data = @embedFile("assets/avatar.png");
var instance: ?*NotifierSystem = null;
pub const NotifierSystem = struct {
    allocator: std.mem.Allocator,
    running: bool,
    resting: bool,
    random: std.Random.DefaultPrng,
    notification1_count: u32 = 0,
    last_break_time: i64,
    condition: std.Thread.Condition,
    mutex: std.Thread.Mutex,

    const MIN_INTERVAL_MS = 4 * 60 * 1000; // 5 minutes
    const MAX_INTERVAL_MS = 6 * 60 * 1000; // 8 minutes
    const WORK_PERIOD_MS = 90 * 60 * 1000; // 90 minutes
    const REST_PERIOD_MS = 20 * 60 * 1000; // 20 minutes

    pub fn init(allocator: std.mem.Allocator) NotifierSystem {
        return .{
            .allocator = allocator,
            .running = true,
            .resting = false,
            .random = std.Random.DefaultPrng.init(@intCast(std.time.timestamp())),
            .last_break_time = std.time.milliTimestamp(),
            .condition = std.Thread.Condition{},
            .mutex = std.Thread.Mutex{},
        };
    }

    fn playSound(sound_type: SoundType) void {
        const sound_file = switch (sound_type) {
            .bell => "/usr/share/sounds/freedesktop/stereo/bell.oga",
            .complete => "/usr/share/sounds/freedesktop/stereo/complete.oga",
            .message => "/usr/share/sounds/freedesktop/stereo/message.oga",
        };

        // Try multiple sound players in order of preference
        playWithCommand("paplay", sound_file) catch {
            playWithCommand("aplay", sound_file) catch {
                playWithCommand("pw-play", sound_file) catch {
                    // Try system beep as last resort
                    _ = std.process.Child.run(.{
                        .allocator = std.heap.page_allocator,
                        .argv = &[_][]const u8{ "printf", "\\a" },
                    }) catch {};
                };
            };
        };
    }

    fn playWithCommand(player: []const u8, file: []const u8) !void {
        var child = std.process.Child.init(
            &[_][]const u8{ player, file },
            std.heap.page_allocator,
        );
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        _ = try child.spawnAndWait();
    }

    fn sendNotification(
        summary: [:0]const u8,
        body: [:0]const u8,
        urgency: c.NotifyUrgency,
        sound_type: SoundType,
        icon: ?[:0]const u8,
    ) !void {
        const notification = c.notify_notification_new(
            summary,
            body,
            icon orelse null, // icon
        );
        if (notification == null) return error.NotificationCreationFailed;
        defer c.g_object_unref(notification);

        c.notify_notification_set_urgency(notification, urgency);
        c.notify_notification_set_timeout(notification, c.NOTIFY_EXPIRES_DEFAULT);

        var err: ?*c.GError = null;
        if (c.notify_notification_show(notification, &err) == 0) {
            if (err) |e| {
                defer c.g_error_free(e);
            }
            return error.NotificationShowFailed;
        }

        // Play sound after showing notification
        playSound(sound_type);
    }

    fn getRandomInterval(self: *NotifierSystem) u64 {
        const range = MAX_INTERVAL_MS - MIN_INTERVAL_MS;
        const random_offset = self.random.random().intRangeAtMost(u32, 0, range);
        return MIN_INTERVAL_MS + random_offset;
    }

    fn formatTime(ms: u64, buf: []u8) ![:0]u8 {
        const minutes = ms / (60 * 1000);
        const seconds = (ms % (60 * 1000)) / 1000;
        return try std.fmt.bufPrintZ(buf, "{} min {} sec", .{ minutes, seconds });
    }

    fn sleepUntil(self: *NotifierSystem, target_time_ms: i64) !void {
        while (self.running) {
            const current = std.time.milliTimestamp();
            if (target_time_ms < current) {
                return;
            }

            const remaining = @as(u64, @intCast(target_time_ms - current));
            try self.condition.timedWait(&self.mutex, remaining * std.time.ns_per_ms);
        }
    }

    fn getAvatarPath(self: *NotifierSystem) ![:0]const u8 {
        // Get temporary directory
        const tmp_dir = std.posix.getenv("TMPDIR") orelse "/tmp";

        // Create a path for our temporary avatar file
        var avatar_path_buf: [256]u8 = undefined;
        const avatar_path = try std.fmt.bufPrintZ(&avatar_path_buf, "{s}/fotiny-avatar.png", .{tmp_dir});

        // Create the file
        const file = try std.fs.createFileAbsolute(avatar_path, .{});
        defer file.close();

        // Write the embedded data to the file
        _ = try file.writeAll(avatar_data);

        // Return the path (allocated copy that caller will own)
        return try self.allocator.dupeZ(u8, avatar_path);
    }

    pub fn run(self: *NotifierSystem) !void {
        const avatar_path = try getAvatarPath(self);
        defer self.allocator.free(avatar_path);

        // const cwd = try std.fs.cwd().realpathAlloc(self.allocator, ".");
        // defer self.allocator.free(cwd);
        //
        // var avatar_path_buf: [256]u8 = undefined;
        // const avatar_path = try std.fmt.bufPrintZ(&avatar_path_buf, "{s}/assets/avatar.png", .{cwd});

        // Send start notification

        instance = self;
        defer instance = null;
        if (c.notify_init("Fotiny") == 0) {
            return error.NotifyInitFailed;
        }
        defer c.notify_uninit();

        const sigaction = std.os.linux.Sigaction{
            .handler = .{ .handler = handleSignal },
            .mask = std.os.linux.empty_sigset,
            .flags = 0,
        };
        _ = std.os.linux.sigaction(std.os.linux.SIG.INT, &sigaction, null);

        sendNotification(
            "Work Session Started",
            "Starting work session. \nദ്ദി(˵ •̀ ᴗ - ˵ ) ✧",
            c.NOTIFY_URGENCY_NORMAL,
            .message,
            avatar_path,
        ) catch |err| {
            std.debug.print("Failed to send start notification: {any}\n", .{err});
        };

        self.last_break_time = std.time.milliTimestamp();
        var next_notification1_time = std.time.milliTimestamp() + @as(i64, @intCast(self.getRandomInterval()));

        while (self.running) : (self.mutex.unlock()) {
            self.mutex.lock();
            const current_time = std.time.milliTimestamp();
            var next_event_time: i64 = std.math.maxInt(i64);

            if (self.resting) {
                const rest_end_time = self.last_break_time + REST_PERIOD_MS;

                if (current_time >= rest_end_time) {
                    // Rest period is over
                    self.resting = false;
                    self.notification1_count = 0;

                    sendNotification(
                        "Break Over - Back to Work!",
                        "Your 20-minute break is over. Starting new work session.",
                        c.NOTIFY_URGENCY_NORMAL,
                        .message,
                        avatar_path,
                    ) catch |err| {
                        std.debug.print("Failed to send back-to-work notification: {any}\n", .{err});
                    };

                    self.last_break_time = current_time;
                    next_notification1_time = current_time + @as(i64, @intCast(self.getRandomInterval()));
                    continue;
                } else {
                    // Still resting, sleep until rest ends
                    next_event_time = rest_end_time;
                }
            } else {
                const break_time = self.last_break_time + WORK_PERIOD_MS;

                // Check if it's time for a break
                if (current_time >= break_time) {
                    self.resting = true;
                    self.last_break_time = current_time;

                    sendNotification(
                        "🎉 Break Time! (90 minutes reached)",
                        "Take a 20-minute break. You've been working for 90 minutes. Stretch, rest your eyes, and relax!",
                        c.NOTIFY_URGENCY_CRITICAL,
                        .complete,
                        avatar_path,
                    ) catch |err| {
                        std.debug.print("Failed to send break notification: {any}\n", .{err});
                    };

                    std.debug.print("Break started at {}\n", .{current_time});
                    continue;
                }

                // Check if it's time for notification1
                if (current_time >= next_notification1_time) {
                    self.notification1_count += 1;

                    var time_buf: [64]u8 = undefined;
                    const time_until_break = @as(u64, @intCast(break_time - current_time));
                    const time_str = formatTime(time_until_break, &time_buf) catch "unknown";

                    var buf: [256]u8 = undefined;
                    const body = std.fmt.bufPrintZ(
                        &buf,
                        "Reminder #{}, rest for 20s\nNext break in: {s}",
                        .{ self.notification1_count, time_str },
                    ) catch "Reminder";

                    sendNotification(
                        "⏰ Regular Check-in",
                        body,
                        c.NOTIFY_URGENCY_NORMAL,
                        .bell,
                        avatar_path,
                    ) catch |err| {
                        std.debug.print("Failed to send notification1: {any}\n", .{err});
                    };

                    // Schedule next random notification
                    const next_interval = self.getRandomInterval();
                    next_notification1_time = current_time + @as(i64, @intCast(next_interval));

                    var interval_buf: [64]u8 = undefined;
                    const interval_str = formatTime(next_interval, &interval_buf) catch "unknown";
                    std.debug.print("Next notification in: {s}\n", .{interval_str});
                    continue;
                }

                // Determine next event time (earliest of: notification1 or break)
                next_event_time = @min(next_notification1_time, break_time);
            }

            // Sleep until the next event
            if (next_event_time > current_time) {
                var time_buf: [64]u8 = undefined;
                const sleep_ms = @as(u64, @intCast(next_event_time - current_time));
                const sleep_str = formatTime(sleep_ms, &time_buf) catch "unknown";
                std.debug.print("Sleeping for {s} until next event...\n", .{sleep_str});

                try self.sleepUntil(next_event_time);
            }
        }
    }

    const SoundType = enum {
        bell,
        complete,
        message,
    };
};

fn handleSignal(_: c_int) callconv(.C) void {
    std.debug.print("\n[Interrupt received, shutting down...]\n", .{});

    // 6. Can access global_instance because same module
    if (instance) |notifier| {
        notifier.mutex.lock();
        defer notifier.mutex.unlock();
        notifier.running = false;
        notifier.condition.signal();
    }
}

pub export fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "basic add functionality" {
    try testing.expect(add(3, 7) == 10);
}
