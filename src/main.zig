const std = @import("std");
const os = std.os;
const linux = os.linux;
const mem = std.mem;

const c = @cImport({
    @cInclude("ctype.h");
});

//*** defines ***/

// These variables are not set in zig's std.os
const VTIME: u8 = 5;
const VMIN: u8 = 6;

const KILO_VERSION = "0.0.1";

const EditorKey = enum {
    ARROW_LEFT,
    ARROW_RIGHT,
    ARROW_UP,
    ARROW_DOWN,
    HOME_KEY,
    END_KEY,
    PAGE_UP,
    PAGE_DOWN,
};

const KeyOrCode = union(enum) {
    key: EditorKey,
    code: u32,
};

//*** data ***/
var allocator: std.mem.Allocator = undefined;
var stdout: std.fs.File.Writer = undefined;

const Flow = enum {
    keep_going,
    exit,
};

const editorConfig = struct {
    cx: u32 = 0,
    cy: u32 = 0,
    screen_rows: u32 = undefined,
    screen_cols: u32 = undefined,
    termios: linux.termios = undefined,
};

var E = editorConfig{};

//*** terminal ***/

fn enableRawMode() !void {
    E.termios = try os.tcgetattr(linux.STDIN_FILENO);

    var raw = E.termios;
    raw.iflag &= ~(linux.BRKINT | linux.ICRNL | linux.INPCK | linux.ISTRIP | linux.IXON);
    raw.oflag &= ~(linux.OPOST);
    raw.cflag |= linux.CS8;
    raw.lflag &= ~(linux.ECHO | linux.ICANON | linux.IEXTEN | linux.ISIG);
    raw.cc[VMIN] = 0;
    raw.cc[VTIME] = 1;

    if (linux.tcsetattr(linux.STDIN_FILENO, .FLUSH, &raw) == -1) {
        return error.tcsetattr;
    }
}

fn disableRawMode() !void {
    // can't use this because TCSA is missing from std.c
    //try os.tcsetattr(linux.STDIN_FILENO, .FLUSH, raw);
    if (linux.tcsetattr(linux.STDIN_FILENO, .FLUSH, &E.termios) == -1) {
        return error.tcsetattr;
    }
}

fn editorReadKey() !KeyOrCode {
    var char: [1]u8 = .{0};
    var nread = try os.read(linux.STDIN_FILENO, char[0..]);
    while (nread != 1) : (nread = try os.read(linux.STDIN_FILENO, char[0..])) {
        if (nread == -1) return error.read;
    }
    if (char[0] == '\x1b') {
        var seq: [3]u8 = undefined;
        if ((try os.read(linux.STDIN_FILENO, seq[0..1])) != 1) return KeyOrCode{ .code = '\x1b' };
        if ((try os.read(linux.STDIN_FILENO, seq[1..2])) != 1) return KeyOrCode{ .code = '\x1b' };

        // ABCD: Arrow keys
        if (seq[0] == '[') {
            if (seq[1] >= '0' and seq[1] <= '9') {
                if ((try os.read(linux.STDIN_FILENO, seq[2..3])) != 1) return KeyOrCode{ .code = '\x1b' };
                if (seq[2] == '~') {
                    switch (seq[1]) {
                        '1', '7' => return KeyOrCode{ .key = .HOME_KEY },
                        '4', '8' => return KeyOrCode{ .key = .END_KEY },
                        '5' => return KeyOrCode{ .key = .PAGE_UP },
                        '6' => return KeyOrCode{ .key = .PAGE_DOWN },
                        else => {},
                    }
                }
            } else {
                switch (seq[1]) {
                    'A' => return KeyOrCode{ .key = .ARROW_UP },
                    'B' => return KeyOrCode{ .key = .ARROW_DOWN },
                    'C' => return KeyOrCode{ .key = .ARROW_RIGHT },
                    'D' => return KeyOrCode{ .key = .ARROW_LEFT },
                    'H' => return KeyOrCode{ .key = .HOME_KEY },
                    'F' => return KeyOrCode{ .key = .END_KEY },
                    else => {},
                }
            }
        } else if (seq[0] == 'O') {
            switch (seq[1]) {
                'H' => return KeyOrCode{ .key = .HOME_KEY },
                'F' => return KeyOrCode{ .key = .END_KEY },
                else => {},
            }
        }
        return KeyOrCode{ .code = '\x1b' };
    } else {
        return KeyOrCode{ .code = char[0] };
    }
}

fn getCursorPosition(rows: *u32, cols: *u32) !void {
    var buf: [31:0]u8 = undefined;

    // n: Device Status Report (https://vt100.net/docs/vt100-ug/chapter3.html#DSR)
    // 6: report active position
    if ((try stdout.write("\x1b[6n")) != 4) return error.getCursorPosition;

    var i: usize = 0;
    while (i < buf.len) : (i += 1) {
        var nread = try os.read(linux.STDIN_FILENO, buf[i .. i + 1]);
        if (nread != 1) break;
        if (buf[i] == 'R') break;
    }
    buf[i] = 0; // With the slice in the tokenizer this is not really necessary

    if (buf[0] != '\x1b' or buf[1] != '[') return error.getCursorPosition;

    var it = std.mem.tokenize(u8, buf[2..i], ";");
    rows.* = try std.fmt.parseInt(u32, it.next() orelse return error.getCursorPosition, 10);
    cols.* = try std.fmt.parseInt(u32, it.next() orelse return error.getCursorPosition, 10);
}

fn getWindowSize(rows: *u32, cols: *u32) !void {
    var ws: linux.winsize = undefined;
    const rc = linux.ioctl(linux.STDIN_FILENO, linux.T.IOCGWINSZ, @ptrToInt(&ws));
    if (linux.getErrno(rc) != .SUCCESS or ws.ws_col == 0) {
        // C: Cursor Forward (http://vt100.net/docs/vt100-ug/chapter3.html#CUF)
        // B: Cursor Down (http://vt100.net/docs/vt100-ug/chapter3.html#CUD)
        if ((try stdout.write("\x1b[999C\x1b[999B")) != 12) return error.getWindowSize;
        try getCursorPosition(rows, cols);
        return;
    }
    cols.* = ws.ws_col;
    rows.* = ws.ws_row;
}

fn iscntrl(char: u8) bool {
    // we could write c < 0x20 || c == 0x7f and avoid
    // including ctype.h and linking to libC
    return c.iscntrl(char) != 0;
}

inline fn ctrlKey(char: u32) u32 {
    return char & 0b1_1111;
}

//*** output ***/

fn editorDrawRows(buffer: std.ArrayList(u8).Writer) !void {
    var y: u32 = 0;
    while (y < E.screen_rows) : (y += 1) {
        if (y == E.screen_rows / 3) {
            var welcome = "Kilo editor -- version " ++ KILO_VERSION;
            var welcome_len: u32 = welcome.len;
            if (welcome.len > E.screen_cols) welcome_len = E.screen_cols;
            var padding = (E.screen_cols - welcome_len) / 2;
            if (padding != 0) {
                _ = try buffer.write("~");
                padding -= 1;
            }
            _ = try buffer.writeByteNTimes(' ', padding);
            _ = try buffer.write(welcome[0..welcome_len]);
        } else {
            _ = try buffer.write("~");
        }

        // K: Erase From cursor to end of line (http://vt100.net/docs/vt100-ug/chapter3.html#EL)
        _ = try buffer.write("\x1b[K");
        if (y < E.screen_rows - 1) {
            _ = try buffer.write("\r\n");
        }
    }
}

fn editorRefreshScreen() !void {
    var ab = std.ArrayList(u8).init(allocator);
    defer ab.deinit();

    const writer = ab.writer();

    // \x1b: Escape character (27)
    // [: part of the escape sequence
    // l: Reset Mode (https://vt100.net/docs/vt100-ug/chapter3.html#RM)
    // modes: https://vt100.net/docs/vt100-ug/chapter3.html#S3.3.4
    _ = try writer.write("\x1b[?25l");

    // H: Cursor position (https://vt100.net/docs/vt100-ug/chapter3.html#CUP)
    _ = try writer.write("\x1b[H");

    try editorDrawRows(writer);
    try writer.print("\x1b[{d};{d}H", .{ E.cy + 1, E.cx + 1 });

    // h: Set Mode https://vt100.net/docs/vt100-ug/chapter3.html#SM
    _ = try writer.write("\x1b[?25h");

    _ = try stdout.write(ab.items);
}

//*** input ***/

fn editorMoveCursor(key: EditorKey) void {
    switch (key) {
        .ARROW_LEFT => E.cx -|= 1,
        .ARROW_RIGHT => E.cx += @as(u32, if (E.cx < E.screen_cols - 1) 1 else 0),
        .ARROW_UP => E.cy -|= 1,
        .ARROW_DOWN => E.cy += @as(u32, if (E.cy < E.screen_rows - 1) 1 else 0),
        else => {},
    }
}

fn editorProcessKeypress() !Flow {
    var keycode = try editorReadKey();
    switch (keycode) {
        .code => |char| switch (char) {
            ctrlKey('q') => return .exit,
            else => {},
        },
        .key => |key| switch (key) {
            .ARROW_UP,
            .ARROW_LEFT,
            .ARROW_DOWN,
            .ARROW_RIGHT,
            => editorMoveCursor(key),

            .PAGE_UP, .PAGE_DOWN => {
                var times = E.screen_cols;
                while (times > 0) : (times -= 1) {
                    editorMoveCursor(if (key == .PAGE_UP) .ARROW_UP else .ARROW_DOWN);
                }
            },
            .HOME_KEY => E.cx = 0,
            .END_KEY => E.cx = E.screen_cols - 1,

            else => {},
        },
    }
    return .keep_going;
}

//*** init ***/

fn initEditor() !void {
    E.cx = 0;
    E.cy = 0;
    try getWindowSize(&E.screen_rows, &E.screen_cols);
}

var gpa = std.heap.GeneralPurposeAllocator(.{}){};

pub fn main() anyerror!void {
    defer std.testing.expect(!gpa.deinit()) catch @panic("leak");
    allocator = gpa.allocator();

    try enableRawMode();
    defer disableRawMode() catch {};

    try initEditor();

    stdout = std.io.getStdOut().writer();

    while (true) {
        try editorRefreshScreen();
        if ((try editorProcessKeypress()) == .exit) break;
    }
}

//*** tests ***/

test "basic test" {
    try std.testing.expectEqual(10, 3 + 7);
}

test "getWindowSize" {
    if (std.os.isatty(std.os.STDOUT_FILENO)) {
        var rows: u32 = 0;
        var cols: u32 = 0;
        try getWindowSize(&rows, &cols);
        try std.testing.expect(rows > 0);
        try std.testing.expect(cols > 0);
    }
}
