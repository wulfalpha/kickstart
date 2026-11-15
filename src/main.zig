const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const List = std.array_list.Managed;
const Command = struct { argv: []const []const u8 };
const Config = std.StringHashMap(Command);
const TerminalMode = enum { auto, current, new, gui };
const Options = struct {
    files: List([]const u8),
    config: ?[]const u8 = null,
    program: ?[]const u8 = null,
    action: ?[]const u8 = null,
    terminal: TerminalMode = .auto,
    verbose: bool = false,
    dry_run: bool = false,
    check: bool = false,
    generate: bool = false,
    show_path: bool = false,
    batch: bool = false,
    help: bool = false,
};

const help =
    \\Kickstart — open files without changing system associations
    \\Usage: kickstart [options] [--] file ...
    \\  --config PATH       Use a specific config file
    \\  --program COMMAND   Use this command once (quote commands with arguments)
    \\  --with NAME         Select a named action, e.g. --with edit
    \\  --terminal MODE     auto, current, new, or gui (default: auto)
    \\  --batch             Pass all files to one command; mappings must agree
    \\  --dry-run, --explain Show matching rules and exact argv without launching
    \\  --gen-config        Create a sample at the preferred config path; never overwrite
    \\  --show-config-path  Print the config path selected for reading
    \\  --check-config      Validate every configured command without launching
    \\  -v, --verbose       Show launch details; also KICKSTART_VERBOSE=1
    \\  -h, --help          Show this help
    \\
    \\Config: explicit absolute $XDG_CONFIG_HOME/kickstart/kickstartrc on Unix.
    \\macOS: ~/Library/Application Support/kickstart/kickstartrc,
    \\       falling back to an existing ~/.config/kickstart/kickstartrc.
    \\Linux: ~/.config/kickstart/kickstartrc
    \\Windows: %LOCALAPPDATA%\kickstart\kickstartrc
    \\Rules: txt=editor [args], tar.gz=archive-viewer, default=editor
    \\Named actions: txt:edit=editor, default:edit=editor
    \\Special filename rules: name:.bashrc=editor
    \\Terminal settings: myTerm=kitty [args], myArg=-e,
    \\termPrograms=nvim,vim,nano,less
    \\Commands use quotes and limited backslash escaping, never a shell.
    \\Place -- in a command's configured arguments if that application supports it.
    \\Examples: kickstart --program 'code --wait' notes.txt
    \\          kickstart --terminal current --with edit notes.txt
    \\
;

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn parseCli(a: Allocator, argv: []const []const u8) !Options {
    var o = Options{ .files = List([]const u8).init(a) };
    var positional = false;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (!positional and eql(arg, "--")) {
            positional = true;
            continue;
        }
        if (!positional and std.mem.startsWith(u8, arg, "-")) {
            if (eql(arg, "--help") or eql(arg, "-h")) {
                o.help = true;
                continue;
            }
            if (eql(arg, "--verbose") or eql(arg, "-v")) {
                o.verbose = true;
                continue;
            }
            if (eql(arg, "--dry-run") or eql(arg, "--explain")) {
                o.dry_run = true;
                continue;
            }
            if (eql(arg, "--gen-config")) {
                o.generate = true;
                continue;
            }
            if (eql(arg, "--show-config-path")) {
                o.show_path = true;
                continue;
            }
            if (eql(arg, "--check-config")) {
                o.check = true;
                continue;
            }
            if (eql(arg, "--batch")) {
                o.batch = true;
                continue;
            }
            if (eql(arg, "--config") or eql(arg, "--program") or eql(arg, "--with") or eql(arg, "--terminal")) {
                i += 1;
                if (i == argv.len or argv[i].len == 0) return error.MissingOptionValue;
                const value = argv[i];
                if (eql(arg, "--config")) o.config = value else if (eql(arg, "--program")) o.program = value else if (eql(arg, "--with")) o.action = value else o.terminal = std.meta.stringToEnum(TerminalMode, value) orelse return error.InvalidTerminalMode;
                continue;
            }
            return error.UnknownOption;
        }
        if (arg.len == 0) return error.EmptyFilename;
        try o.files.append(arg);
    }
    if (o.program != null and o.action != null) return error.ConflictingProgramSelection;
    const management_count: u8 = @as(u8, @intFromBool(o.generate)) + @as(u8, @intFromBool(o.show_path)) + @as(u8, @intFromBool(o.check));
    if (!o.help and (management_count > 1 or (management_count > 0 and
        (o.files.items.len > 0 or o.program != null or o.action != null or o.batch or o.dry_run or o.terminal != .auto)))) return error.ConflictingConfigOperation;
    return o;
}

// All parsed data belongs to the caller's arena. Backslashes only escape
// whitespace, quotes and backslashes; other backslashes remain literal.
fn parseCommand(a: Allocator, input: []const u8) !Command {
    var args = List([]const u8).init(a);
    var token = List(u8).init(a);
    var quote: ?u8 = null;
    var started = false;
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        const c = input[i];
        if (c == 0) return error.NullByte;
        if (c == '\\' and quote != @as(?u8, '\'')) {
            if (i + 1 == input.len) return error.TrailingEscape;
            const next = input[i + 1];
            if (next == '\\' or next == '"' or next == '\'' or (quote == null and std.ascii.isWhitespace(next))) {
                try token.append(next);
                i += 1;
                started = true;
                continue;
            }
        }
        if (quote) |q| {
            if (c == q) quote = null else try token.append(c);
        } else if (c == '"' or c == '\'') {
            quote = c;
            started = true;
        } else if (std.ascii.isWhitespace(c)) {
            if (started) {
                try args.append(try a.dupe(u8, token.items));
                token.clearRetainingCapacity();
                started = false;
            }
        } else {
            try token.append(c);
            started = true;
        }
    }
    if (quote != null) return error.UnclosedQuote;
    if (started) try args.append(try a.dupe(u8, token.items));
    if (args.items.len == 0 or args.items[0].len == 0) return error.EmptyCommand;
    return .{ .argv = try args.toOwnedSlice() };
}

const ConfigPurpose = enum { read, generate };

// Explicit paths are authoritative. Discovery only falls back on absence;
// generation always targets the preferred platform location.
fn configPath(a: Allocator, purpose: ConfigPurpose) ![]const u8 {
    if (builtin.os.tag == .windows) {
        const root = std.process.getEnvVarOwned(a, "LOCALAPPDATA") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => return std.fs.path.join(a, &.{ try std.process.getEnvVarOwned(a, "USERPROFILE"), "AppData", "Local", "kickstart", "kickstartrc" }),
            else => return err,
        };
        return std.fs.path.join(a, &.{ root, "kickstart", "kickstartrc" });
    }
    const xdg = std.process.getEnvVarOwned(a, "XDG_CONFIG_HOME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => "",
        else => return err,
    };
    if (xdg.len > 0 and std.fs.path.isAbsolute(xdg)) return std.fs.path.join(a, &.{ xdg, "kickstart", "kickstartrc" });
    const home = try std.process.getEnvVarOwned(a, "HOME");
    const legacy = try std.fs.path.join(a, &.{ home, ".config", "kickstart", "kickstartrc" });
    if (builtin.os.tag == .macos) {
        const native = try std.fs.path.join(a, &.{ home, "Library", "Application Support", "kickstart", "kickstartrc" });
        if (purpose == .generate) return native;
        if (try configExists(native)) return native;
        if (try configExists(legacy)) return legacy;
        return native;
    }
    return legacy;
}

// Only absence permits a fallback; unreadable configs must not silently select
// a different set of executable commands.
fn configExists(path: []const u8) !bool {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    file.close();
    return true;
}

fn diagnostic(label: []const u8, value: []const u8) void {
    std.debug.print("{s}{f}\n", .{ label, std.json.fmt(value, .{}) });
}

fn parseConfig(a: Allocator, content: []const u8) !Config {
    var config = Config.init(a);
    var lines = std.mem.splitScalar(u8, content, '\n');
    var line_number: usize = 0;
    var invalid = false;
    while (lines.next()) |line| {
        line_number += 1;
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        const pos = std.mem.indexOfScalar(u8, trimmed, '=') orelse {
            std.debug.print("Config line {d}: missing '='\n", .{line_number});
            invalid = true;
            continue;
        };
        const raw_key = std.mem.trim(u8, trimmed[0..pos], &std.ascii.whitespace);
        if (raw_key.len == 0) {
            invalid = true;
            continue;
        }
        const special = eql(raw_key, "myTerm") or eql(raw_key, "myArg") or eql(raw_key, "termPrograms");
        const key = try a.dupe(u8, raw_key);
        if (!special and !std.mem.startsWith(u8, key, "name:")) _ = std.ascii.lowerString(key, key);
        const value = std.mem.trim(u8, trimmed[pos + 1 ..], &std.ascii.whitespace);
        // Comma-separated metadata is not a command, and can contain spaces.
        const command = if (eql(key, "termPrograms")) Command{ .argv = try a.dupe([]const u8, &.{try a.dupe(u8, value)}) } else parseCommand(a, value) catch |err| {
            std.debug.print("Config line {d}: {s}\n", .{ line_number, @errorName(err) });
            invalid = true;
            continue;
        };
        if (config.contains(key)) {
            std.debug.print("Config line {d}: duplicate rule\n", .{line_number});
            invalid = true;
            continue;
        }
        try config.put(key, command);
    }
    if (invalid) return error.InvalidConfig;
    if (config.count() == 0) return error.EmptyConfig;
    return config;
}

fn generateConfig(path: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| if (dir.len > 0) {
        try std.fs.cwd().makePath(dir);
    };
    const sample = try std.fs.cwd().createFile(path, .{ .exclusive = true, .mode = 0o600 });
    defer sample.close();
    try sample.writeAll(@embedFile("sample.kickstartrc"));
    diagnostic("Created sample config; edit it before launching: ", path);
}

fn loadConfig(a: Allocator, path: []const u8, create: bool) !?Config {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        if (err != error.FileNotFound or !create) return err;
        generateConfig(path) catch |create_err| {
            if (create_err == error.PathAlreadyExists) return loadConfig(a, path, false);
            return create_err;
        };
        return null;
    };
    defer file.close();
    return try parseConfig(a, try file.readToEndAlloc(a, 1024 * 1024));
}

const Selection = struct { rule: []const u8, command: Command };
fn selectCommand(a: Allocator, config: *const Config, path: []const u8, action: ?[]const u8) !Selection {
    const base = std.fs.path.basename(path);
    const suffix = if (action) |name| try std.fmt.allocPrint(a, ":{s}", .{try std.ascii.allocLowerString(a, name)}) else "";
    const filename_key = try std.fmt.allocPrint(a, "name:{s}{s}", .{ base, suffix });
    if (config.get(filename_key)) |c| return .{ .rule = filename_key, .command = c };
    const lower = try std.ascii.allocLowerString(a, base);
    // Longest suffix first; a leading dot alone does not make a dotfile an extension.
    for (lower, 0..) |c, i| {
        if (c != '.' or i == 0 or i + 1 == lower.len) continue;
        const key = try std.fmt.allocPrint(a, "{s}{s}", .{ lower[i + 1 ..], suffix });
        if (config.get(key)) |cmd| return .{ .rule = key, .command = cmd };
    }
    const key = try std.fmt.allocPrint(a, "default{s}", .{suffix});
    return .{ .rule = key, .command = config.get(key) orelse return error.NoMatchingRule };
}

fn absolutePath(a: Allocator, path: []const u8) ![]const u8 {
    return std.fs.path.resolve(a, &.{ try std.process.getCwdAlloc(a), path });
}

fn executableFile(path: []const u8) bool {
    const stat = std.fs.cwd().statFile(path) catch return false;
    if (stat.kind != .file) return false;
    if (builtin.os.tag != .windows and stat.mode & 0o111 == 0) return false;
    return true;
}

fn resolveProgram(a: Allocator, program: []const u8) ![]const u8 {
    if (builtin.os.tag == .windows) {
        const ext = std.fs.path.extension(program);
        if (std.ascii.eqlIgnoreCase(ext, ".bat") or std.ascii.eqlIgnoreCase(ext, ".cmd")) return error.BatchScriptsRequireExplicitShell;
    }
    if (std.mem.indexOfAny(u8, program, "/\\") != null or std.fs.path.isAbsolute(program)) {
        const path = try absolutePath(a, program);
        if (executableFile(path)) return path;
        return error.ProgramNotFound;
    }
    const path = std.process.getEnvVarOwned(a, "PATH") catch return error.ProgramNotFound;
    var dirs = std.mem.splitScalar(u8, path, if (builtin.os.tag == .windows) ';' else ':');
    while (dirs.next()) |dir| {
        // Never search the current directory implicitly.
        if (!std.fs.path.isAbsolute(dir)) continue;
        const candidate = try std.fs.path.join(a, &.{ dir, program });
        if (executableFile(candidate)) return candidate;
        if (builtin.os.tag == .windows and std.fs.path.extension(program).len == 0) {
            // Batch scripts need a shell and are deliberately not auto-selected.
            const exe = try std.fmt.allocPrint(a, "{s}.exe", .{candidate});
            if (executableFile(exe)) return exe;
            const com = try std.fmt.allocPrint(a, "{s}.com", .{candidate});
            if (executableFile(com)) return com;
        }
    }
    return error.ProgramNotFound;
}

fn isTerminal(config: *const Config, program: []const u8) bool {
    const base = std.fs.path.stem(std.fs.path.basename(program));
    const names = if (config.get("termPrograms")) |c| c.argv[0] else "nvim,vim,micro,nano,less,more,htop,man,top,btop";
    var it = std.mem.splitScalar(u8, names, ',');
    while (it.next()) |name| if (eql(base, std.mem.trim(u8, name, &std.ascii.whitespace))) return true;
    return false;
}

fn appendTerminal(a: Allocator, argv: *List([]const u8), config: *const Config) !void {
    if (config.get("myTerm")) |term| {
        try argv.append(try resolveProgram(a, term.argv[0]));
        try argv.appendSlice(term.argv[1..]);
        if (config.get("myArg")) |arg| try argv.appendSlice(arg.argv) else try argv.append("-e");
        return;
    }
    const terminals = [_][]const u8{ "alacritty", "kitty", "ghostty", "wezterm", "gnome-terminal", "xterm" };
    for (terminals) |term| {
        const resolved = resolveProgram(a, term) catch |err| {
            if (err == error.ProgramNotFound) continue;
            return err;
        };
        try argv.append(resolved);
        if (eql(term, "wezterm")) try argv.appendSlice(&.{ "start", "--" }) else try argv.append(if (eql(term, "gnome-terminal")) "--" else "-e");
        return;
    }
    return error.NoTerminalFound;
}

fn launchArgv(a: Allocator, config: *const Config, command: Command, files: []const []const u8, mode: TerminalMode) ![]const []const u8 {
    var argv = List([]const u8).init(a);
    const new_terminal = mode == .new or (mode == .auto and isTerminal(config, command.argv[0]));
    if (new_terminal) try appendTerminal(a, &argv, config);
    try argv.append(try resolveProgram(a, command.argv[0]));
    try argv.appendSlice(command.argv[1..]);
    for (files) |file| try argv.append(try absolutePath(a, file));
    return argv.toOwnedSlice();
}

fn sameCommand(a: Command, b: Command) bool {
    if (a.argv.len != b.argv.len) return false;
    for (a.argv, b.argv) |x, y| if (!eql(x, y)) return false;
    return true;
}

fn checkConfig(a: Allocator, config: *const Config) !void {
    var it = config.iterator();
    var failed = false;
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (eql(key, "termPrograms") or eql(key, "myArg")) continue;
        _ = resolveProgram(a, entry.value_ptr.argv[0]) catch |err| {
            diagnostic("Unavailable rule: ", key);
            std.debug.print("  {s}\n", .{@errorName(err)});
            failed = true;
            continue;
        };
    }
    if (failed) return error.ConfigCheckFailed;
    std.debug.print("Config check passed ({d} entries).\n", .{config.count()});
}

fn run(a: Allocator) !u8 {
    const args = try std.process.argsAlloc(a);
    var o = try parseCli(a, args);
    if (o.help) {
        std.debug.print("{s}", .{help});
        return 0;
    }
    const verbose = std.process.getEnvVarOwned(a, "KICKSTART_VERBOSE") catch "";
    o.verbose = o.verbose or eql(verbose, "1") or eql(verbose, "true");
    if (o.generate or o.show_path) {
        const path = o.config orelse try configPath(a, if (o.generate) .generate else .read);
        if (o.generate) {
            generateConfig(path) catch |err| {
                if (err == error.PathAlreadyExists) diagnostic("Refusing to overwrite existing config: ", path);
                return err;
            };
        } else {
            const stdout = std.fs.File.stdout();
            try stdout.writeAll(path);
            try stdout.writeAll("\n");
        }
        return 0;
    }
    if (!o.check and o.files.items.len == 0) {
        std.debug.print("{s}", .{help});
        return 2;
    }
    var config = Config.init(a);
    // An explicit program works without requiring or creating a config.
    if (o.program == null or o.config != null or o.check) {
        const path = o.config orelse try configPath(a, .read);
        if (o.verbose or o.dry_run) diagnostic("Config: ", path);
        config = (try loadConfig(a, path, o.config == null and !o.check)) orelse return 0;
    }
    if (o.check) {
        try checkConfig(a, &config);
        return 0;
    }
    var selections = List(Selection).init(a);
    const override = if (o.program) |p| try parseCommand(a, p) else null;
    for (o.files.items) |file| {
        const selected = if (override) |c| Selection{ .rule = "--program", .command = c } else selectCommand(a, &config, file, o.action) catch |err| {
            diagnostic("No matching opener for: ", file);
            return err;
        };
        try selections.append(selected);
    }
    if (o.batch) for (selections.items[1..]) |s| {
        if (!sameCommand(selections.items[0].command, s.command)) return error.BatchRequiresSameCommand;
    };
    // Prepare every command before starting any child, preventing partial launches
    // caused by a later missing executable or invalid terminal setting.
    var launches = List([]const []const u8).init(a);
    for (selections.items, 0..) |s, i| {
        if (o.batch and i > 0) break;
        if (o.verbose or o.dry_run) diagnostic("Rule: ", s.rule);
        const files = if (o.batch) o.files.items else o.files.items[i .. i + 1];
        const argv = try launchArgv(a, &config, s.command, files, o.terminal);
        if (o.verbose or o.dry_run) std.debug.print("argv: {f}\n", .{std.json.fmt(argv, .{})});
        try launches.append(argv);
    }
    if (o.dry_run) return 0;
    var status: u8 = 0;
    for (launches.items) |argv| {
        var child = std.process.Child.init(argv, a);
        const term = try child.spawnAndWait();
        const code: u8 = switch (term) {
            .Exited => |code| code,
            else => 1,
        };
        if (code != 0) status = code;
    }
    return status;
}

pub fn main() void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const status = run(arena.allocator()) catch |err| blk: {
        std.debug.print("kickstart: {s}\n", .{@errorName(err)});
        break :blk @as(u8, 1);
    };
    arena.deinit();
    if (status != 0) std.process.exit(status);
}

test "parser preserves Windows paths, empty arguments and literal shell syntax" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const c = try parseCommand(arena.allocator(), "\"C:\\Program Files\\App\\app.exe\" \"\" 'a b' a\\ b $(whoami);x");
    try std.testing.expectEqualStrings("C:\\Program Files\\App\\app.exe", c.argv[0]);
    try std.testing.expectEqualStrings("", c.argv[1]);
    try std.testing.expectEqualStrings("a b", c.argv[2]);
    try std.testing.expectEqualStrings("a b", c.argv[3]);
    try std.testing.expectEqualStrings("$(whoami);x", c.argv[4]);
    try std.testing.expectError(error.UnclosedQuote, parseCommand(arena.allocator(), "editor 'oops"));
    try std.testing.expectError(error.TrailingEscape, parseCommand(arena.allocator(), "editor foo\\"));
}

test "matching normalizes extensions, prefers compound suffixes and treats dotfiles explicitly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = try parseConfig(a, "PDF=view\ngz=gzip\ntar.gz=archive\ndefault=edit\nname:.bashrc=shell-editor\npdf:edit=pdf-editor\n");
    try std.testing.expectEqualStrings("view", (try selectCommand(a, &config, "A.PDF", null)).command.argv[0]);
    try std.testing.expectEqualStrings("archive", (try selectCommand(a, &config, "a.tar.gz", null)).command.argv[0]);
    try std.testing.expectEqualStrings("shell-editor", (try selectCommand(a, &config, ".bashrc", null)).command.argv[0]);
    try std.testing.expectEqualStrings("default", (try selectCommand(a, &config, ".pdf", null)).rule);
    try std.testing.expectEqualStrings("pdf-editor", (try selectCommand(a, &config, "a.pdf", "edit")).command.argv[0]);
    try std.testing.expectEqualStrings("default", (try selectCommand(a, &config, "py", null)).rule);
}

test "CLI handles multiple files, option terminator and conflicts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const o = try parseCli(a, &.{ "kickstart", "--config", "local.rc", "--program", "editor --", "--", "-odd.txt", "+odd.txt" });
    try std.testing.expectEqual(@as(usize, 2), o.files.items.len);
    try std.testing.expectEqualStrings("-odd.txt", o.files.items[0]);
    try std.testing.expectError(error.MissingOptionValue, parseCli(a, &.{ "kickstart", "--config" }));
    try std.testing.expectError(error.ConflictingProgramSelection, parseCli(a, &.{ "kickstart", "--program", "edit", "--with", "view" }));
}

test "terminal arguments and special filenames remain separate argv entries" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = try parseConfig(a, "myTerm=/bin/echo --terminal-option\nmyArg=--\ntermPrograms= echo, less\n");
    const command = try parseCommand(a, "/bin/echo --");
    const argv = try launchArgv(a, &config, command, &.{"+$(touch nope).txt"}, .new);
    try std.testing.expectEqualStrings("/bin/echo", argv[0]);
    try std.testing.expectEqualStrings("--terminal-option", argv[1]);
    try std.testing.expectEqualStrings("--", argv[2]);
    try std.testing.expectEqualStrings("/bin/echo", argv[3]);
    try std.testing.expectEqualStrings("--", argv[4]);
    try std.testing.expect(std.fs.path.isAbsolute(argv[5]));
    try std.testing.expect(std.mem.endsWith(u8, argv[5], "+$(touch nope).txt"));
    try std.testing.expect(isTerminal(&config, "/bin/echo"));
    const current = try launchArgv(a, &config, command, &.{"-file.txt"}, .current);
    try std.testing.expectEqual(@as(usize, 3), current.len);
}

test "invalid configs fail instead of silently falling back" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.InvalidConfig, parseConfig(a, "txt=editor\nTXT=other\n"));
    try std.testing.expectError(error.InvalidConfig, parseConfig(a, "txt=editor\nbroken\n"));
    try std.testing.expectError(error.InvalidConfig, parseConfig(a, "txt=editor 'unterminated\n"));
    const config = try parseConfig(a, "default=editor\n");
    try std.testing.expectError(error.NoMatchingRule, selectCommand(a, &config, "a.txt", "edit"));
}
