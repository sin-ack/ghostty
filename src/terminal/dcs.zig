const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const terminal = @import("main.zig");
const DCS = terminal.DCS;

const log = std.log.scoped(.terminal_dcs);

/// DCS command handler. This should be hooked into a terminal.Stream handler.
/// The hook/put/unhook functions are meant to be called from the
/// terminal.stream dcsHook, dcsPut, and dcsUnhook functions, respectively.
pub const Handler = struct {
    state: State = .{ .inactive = {} },

    /// Maximum bytes any DCS command can take. This is to prevent
    /// malicious input from causing us to allocate too much memory.
    /// This is arbitrarily set to 1MB today, increase if needed.
    max_bytes: usize = 1024 * 1024,

    pub fn deinit(self: *Handler) void {
        self.discard();
    }

    pub fn hook(self: *Handler, alloc: Allocator, dcs: DCS) ?Command {
        assert(self.state == .inactive);

        // Initialize our state to ignore in case of error
        self.state = .{ .ignore = {} };

        // Try to parse the hook.
        const hk_ = tryHook(alloc, dcs) catch |err| {
            log.info("error initializing DCS hook, will ignore hook err={}", .{err});
            return null;
        };
        const hk = hk_ orelse {
            log.info("unknown DCS hook: {}", .{dcs});
            return null;
        };

        self.state = hk.state;
        return hk.command;
    }

    const Hook = struct {
        state: State,
        command: ?Command = null,
    };

    fn tryHook(alloc: Allocator, dcs: DCS) !?Hook {
        return switch (dcs.intermediates.len) {
            0 => switch (dcs.final) {
                // Tmux control mode
                'p' => tmux: {
                    // Tmux control mode must start with ESC P 1000 p
                    if (dcs.params.len != 1 or dcs.params[0] != 1000) break :tmux null;

                    break :tmux .{
                        .state = .{
                            .tmux = .{
                                .buffer = try std.ArrayList(u8).initCapacity(
                                    alloc,
                                    128, // Arbitrary choice to limit initial reallocs
                                ),
                            },
                        },
                        .command = .{ .tmux = .{ .enter = {} } },
                    };
                },

                else => null,
            },

            1 => switch (dcs.intermediates[0]) {
                '+' => switch (dcs.final) {
                    // XTGETTCAP
                    // https://github.com/mitchellh/ghostty/issues/517
                    'q' => .{
                        .state = .{
                            .xtgettcap = try std.ArrayList(u8).initCapacity(
                                alloc,
                                128, // Arbitrary choice
                            ),
                        },
                    },

                    else => null,
                },

                '$' => switch (dcs.final) {
                    // DECRQSS
                    'q' => .{ .state = .{
                        .decrqss = .{},
                    } },

                    else => null,
                },

                else => null,
            },

            else => null,
        };
    }

    /// Put a byte into the DCS handler. This will return a command
    /// if a command needs to be executed.
    pub fn put(self: *Handler, byte: u8) ?Command {
        return self.tryPut(byte) catch |err| {
            // On error we just discard our state and ignore the rest
            log.info("error putting byte into DCS handler err={}", .{err});
            self.discard();
            self.state = .{ .ignore = {} };
            return null;
        };
    }

    fn tryPut(self: *Handler, byte: u8) !?Command {
        switch (self.state) {
            .inactive,
            .ignore,
            => {},

            .tmux => |*tmux| return try tmux.put(byte, self.max_bytes),

            .xtgettcap => |*list| {
                if (list.items.len >= self.max_bytes) {
                    return error.OutOfMemory;
                }

                try list.append(byte);
            },

            .decrqss => |*buffer| {
                if (buffer.len >= buffer.data.len) {
                    return error.OutOfMemory;
                }

                buffer.data[buffer.len] = byte;
                buffer.len += 1;
            },
        }

        return null;
    }

    pub fn unhook(self: *Handler) ?Command {
        // Note: we do NOT call deinit here on purpose because some commands
        // transfer memory ownership. If state needs cleanup, the switch
        // prong below should handle it.
        defer self.state = .{ .inactive = {} };

        return switch (self.state) {
            .inactive,
            .ignore,
            => null,

            .tmux => tmux: {
                self.state.deinit();
                break :tmux .{ .tmux = .{ .exit = {} } };
            },

            .xtgettcap => |list| .{ .xtgettcap = .{ .data = list } },

            .decrqss => |buffer| .{ .decrqss = switch (buffer.len) {
                0 => .none,
                1 => switch (buffer.data[0]) {
                    'm' => .sgr,
                    'r' => .decstbm,
                    's' => .decslrm,
                    else => .none,
                },
                2 => switch (buffer.data[0]) {
                    ' ' => switch (buffer.data[1]) {
                        'q' => .decscusr,
                        else => .none,
                    },
                    else => .none,
                },
                else => unreachable,
            } },
        };
    }

    fn discard(self: *Handler) void {
        self.state.deinit();
        self.state = .{ .inactive = {} };
    }
};

pub const Command = union(enum) {
    /// XTGETTCAP
    xtgettcap: XTGETTCAP,

    /// DECRQSS
    decrqss: DECRQSS,

    /// Tmux control mode
    tmux: Tmux,

    pub fn deinit(self: Command) void {
        switch (self) {
            .xtgettcap => |*v| v.data.deinit(),
            .decrqss => {},
            .tmux => {},
        }
    }

    pub const XTGETTCAP = struct {
        data: std.ArrayList(u8),
        i: usize = 0,

        /// Returns the next terminfo key being requested and null
        /// when there are no more keys. The returned value is NOT hex-decoded
        /// because we expect to use a comptime lookup table.
        pub fn next(self: *XTGETTCAP) ?[]const u8 {
            if (self.i >= self.data.items.len) return null;

            var rem = self.data.items[self.i..];
            const idx = std.mem.indexOf(u8, rem, ";") orelse rem.len;

            // Note that if we're at the end, idx + 1 is len + 1 so we're over
            // the end but that's okay because our check above is >= so we'll
            // never read.
            self.i += idx + 1;

            return rem[0..idx];
        }
    };

    /// Supported DECRQSS settings
    pub const DECRQSS = enum {
        none,
        sgr,
        decscusr,
        decstbm,
        decslrm,
    };

    /// Tmux control mode
    pub const Tmux = union(enum) {
        enter: void,
        exit: void,
    };
};

const State = union(enum) {
    /// We're not in a DCS state at the moment.
    inactive: void,

    /// We're hooked, but its an unknown DCS command or one that went
    /// invalid due to some bad input, so we're ignoring the rest.
    ignore: void,

    /// XTGETTCAP
    xtgettcap: std.ArrayList(u8),

    /// DECRQSS
    decrqss: struct {
        data: [2]u8 = undefined,
        len: u2 = 0,
    },

    /// Tmux control mode: https://github.com/tmux/tmux/wiki/Control-Mode
    tmux: TmuxState,

    pub fn deinit(self: *State) void {
        switch (self.*) {
            .inactive,
            .ignore,
            => {},

            .xtgettcap => |*v| v.deinit(),
            .decrqss => {},
            .tmux => |*v| v.deinit(),
        }
    }
};

const TmuxState = struct {
    tag: Tag = .idle,
    buffer: std.ArrayList(u8),

    const Tag = enum {
        /// Outside of any active command. This should drop any output
        /// unless it is '%' on the first byte of a line.
        idle,

        /// We experienced unexpected input and are in a broken state
        /// so we cannot continue processing.
        broken,

        /// Inside an active command (started with '%').
        command,

        /// Inside a begin/end block.
        block,
    };

    pub fn deinit(self: *TmuxState) void {
        self.buffer.deinit();
    }

    // Handle a byte of input.
    pub fn put(self: *TmuxState, byte: u8, max_bytes: usize) !?Command {
        if (self.buffer.items.len >= max_bytes) {
            self.broken();
            return error.OutOfMemory;
        }

        switch (self.tag) {
            // Drop because we're in a broken state.
            .broken => return null,

            // Waiting for a command so if the byte is not '%' then
            // we're in a broken state. Return an exit command.
            .idle => if (byte != '%') {
                self.broken();
                return .{ .tmux = .{ .exit = {} } };
            } else {
                self.tag = .command;
            },

            // If we're in a command and its not a newline then
            // we accumulate. If it is a newline then we have a
            // complete command we need to parse.
            .command => if (byte == '\n') {
                // We have a complete command, parse it.
                return try self.parseCommand();
            },

            // If we're ina block then we accumulate until we see a newline
            // and then we check to see if that line ended the block.
            .block => if (byte == '\n') {
                const idx = if (std.mem.lastIndexOfScalar(
                    u8,
                    self.buffer.items,
                    '\n',
                )) |v| v + 1 else 0;
                const line = self.buffer.items[idx..];
                if (std.mem.startsWith(u8, line, "%end") or
                    std.mem.startsWith(u8, line, "%error"))
                {
                    // If it is an error then log it.
                    if (std.mem.startsWith(u8, line, "%error")) {
                        const output = self.buffer.items[0..idx];
                        log.warn("tmux control mode error={s}", .{output});
                    }

                    // We ignore the rest of the line, see %begin for why.
                    self.tag = .idle;
                    self.buffer.clearRetainingCapacity();
                    return null;
                }
            },
        }

        try self.buffer.append(byte);

        return null;
    }

    fn parseCommand(self: *TmuxState) !?Command {
        assert(self.tag == .command);

        var it = std.mem.tokenizeScalar(u8, self.buffer.items, ' ');

        // The command MUST exist because we guard entering the command
        // state on seeing at least a '%'.
        const cmd = it.next().?;
        if (std.mem.eql(u8, cmd, "%begin")) {
            // We don't use the rest of the tokens for now because tmux
            // claims to guarantee that begin/end are always in order and
            // never intermixed. In the future, we should probably validate
            // this.
            // TODO(tmuxcc): do this before merge?

            // Move to block state because we expect a corresponding end/error
            // and want to accumulate the data.
            self.tag = .block;
            self.buffer.clearRetainingCapacity();
            return null;
        } else {
            // Unknown command, log it and return to idle state.
            log.warn("unknown tmux control mode command={s}", .{cmd});
        }

        // Successful exit, revert to idle state.
        self.buffer.clearRetainingCapacity();
        self.tag = .idle;

        return null;
    }

    // Mark the tmux state as broken.
    fn broken(self: *TmuxState) void {
        self.tag = .broken;
        self.buffer.clearAndFree();
    }
};

test "unknown DCS command" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var h: Handler = .{};
    defer h.deinit();
    try testing.expect(h.hook(alloc, .{ .final = 'A' }) == null);
    try testing.expect(h.state == .ignore);
    try testing.expect(h.unhook() == null);
    try testing.expect(h.state == .inactive);
}

test "XTGETTCAP command" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var h: Handler = .{};
    defer h.deinit();
    try testing.expect(h.hook(alloc, .{ .intermediates = "+", .final = 'q' }) == null);
    for ("536D756C78") |byte| _ = h.put(byte);
    var cmd = h.unhook().?;
    defer cmd.deinit();
    try testing.expect(cmd == .xtgettcap);
    try testing.expectEqualStrings("536D756C78", cmd.xtgettcap.next().?);
    try testing.expect(cmd.xtgettcap.next() == null);
}

test "XTGETTCAP command multiple keys" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var h: Handler = .{};
    defer h.deinit();
    try testing.expect(h.hook(alloc, .{ .intermediates = "+", .final = 'q' }) == null);
    for ("536D756C78;536D756C78") |byte| _ = h.put(byte);
    var cmd = h.unhook().?;
    defer cmd.deinit();
    try testing.expect(cmd == .xtgettcap);
    try testing.expectEqualStrings("536D756C78", cmd.xtgettcap.next().?);
    try testing.expectEqualStrings("536D756C78", cmd.xtgettcap.next().?);
    try testing.expect(cmd.xtgettcap.next() == null);
}

test "XTGETTCAP command invalid data" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var h: Handler = .{};
    defer h.deinit();
    try testing.expect(h.hook(alloc, .{ .intermediates = "+", .final = 'q' }) == null);
    for ("who;536D756C78") |byte| _ = h.put(byte);
    var cmd = h.unhook().?;
    defer cmd.deinit();
    try testing.expect(cmd == .xtgettcap);
    try testing.expectEqualStrings("who", cmd.xtgettcap.next().?);
    try testing.expectEqualStrings("536D756C78", cmd.xtgettcap.next().?);
    try testing.expect(cmd.xtgettcap.next() == null);
}

test "DECRQSS command" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var h: Handler = .{};
    defer h.deinit();
    try testing.expect(h.hook(alloc, .{ .intermediates = "$", .final = 'q' }) == null);
    _ = h.put('m');
    var cmd = h.unhook().?;
    defer cmd.deinit();
    try testing.expect(cmd == .decrqss);
    try testing.expect(cmd.decrqss == .sgr);
}

test "DECRQSS invalid command" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var h: Handler = .{};
    defer h.deinit();
    try testing.expect(h.hook(alloc, .{ .intermediates = "$", .final = 'q' }) == null);
    _ = h.put('z');
    var cmd = h.unhook().?;
    defer cmd.deinit();
    try testing.expect(cmd == .decrqss);
    try testing.expect(cmd.decrqss == .none);

    h.discard();

    try testing.expect(h.hook(alloc, .{ .intermediates = "$", .final = 'q' }) == null);
    _ = h.put('"');
    _ = h.put(' ');
    _ = h.put('q');
    try testing.expect(h.unhook() == null);
}

test "tmux enter and implicit exit" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var h: Handler = .{};
    defer h.deinit();

    {
        var cmd = h.hook(alloc, .{ .params = &.{1000}, .final = 'p' }).?;
        defer cmd.deinit();
        try testing.expect(cmd == .tmux);
        try testing.expect(cmd.tmux == .enter);
    }

    {
        var cmd = h.unhook().?;
        defer cmd.deinit();
        try testing.expect(cmd == .tmux);
        try testing.expect(cmd.tmux == .exit);
    }
}

test "tmux begin/end empty" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var h: Handler = .{};
    defer h.deinit();
    h.hook(alloc, .{ .params = &.{1000}, .final = 'p' }).?.deinit();
    for ("%begin 1578922740 269 1\n") |byte| try testing.expect(h.put(byte) == null);
    for ("%end 1578922740 269 1\n") |byte| try testing.expect(h.put(byte) == null);
}

test "tmux begin/error empty" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var h: Handler = .{};
    defer h.deinit();
    h.hook(alloc, .{ .params = &.{1000}, .final = 'p' }).?.deinit();
    for ("%begin 1578922740 269 1\n") |byte| try testing.expect(h.put(byte) == null);
    for ("%error 1578922740 269 1\n") |byte| try testing.expect(h.put(byte) == null);
}
