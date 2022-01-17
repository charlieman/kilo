const std = @import("std");
const os = std.os;
const linux = os.linux;
const mem = std.mem;

const c = @cImport({
    @cInclude("ctype.h");
});

// These variables are not set in zig's std.os
const VTIME: u8 = 5;
const VMIN: u8 = 6;

//*** data ***/
var allocator: std.mem.Allocator = undefined;
var stdout: std.fs.File.Writer = undefined;

const Flow = enum {
    keep_going,
    exit,
};

const editorConfig = struct {
    termios: linux.termios = undefined,
    screen_rows: u32 = undefined,
    screen_cols: u32 = undefined,
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

fn editorReadKey() !u8 {
    var char: [1]u8 = .{0};
    var nread = try os.read(linux.STDIN_FILENO, char[0..1]);
    while (nread != 1) {
        if (nread == -1) return error.read;
        nread = try os.read(linux.STDIN_FILENO, char[0..1]);
    }
    return char[0];
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

fn editorProcessKeypress() !Flow {
    var char = try editorReadKey();
    switch (char) {
        ctrlKey('q') => return .exit,
        else => {},
    }
    return .keep_going;
}

fn iscntrl(char: u8) bool {
    // we could write c < 0x20 || c == 0x7f and avoid
    // including ctype.h and linking to libC
    return c.iscntrl(char) != 0;
}

inline fn ctrlKey(char: u8) u8 {
    return char & 0b1_1111;
}

//*** output ***/

fn editorDrawRows(buffer: std.ArrayList(u8).Writer) !void {
    var y: u32 = 0;
    while (y < E.screen_rows) : (y += 1) {
        _ = try buffer.write("~");
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

    // J: Erase In Display (https://vt100.net/docs/vt100-ug/chapter3.html#ED)
    // 2: Argument to ED (Erase all of the display)
    _ = try writer.write("\x1b[2J");

    // H: Cursor position (https://vt100.net/docs/vt100-ug/chapter3.html#CUP)
    _ = try writer.write("\x1b[H");

    try editorDrawRows(writer);

    _ = try writer.write("\x1b[H");
    // h: Set Mode https://vt100.net/docs/vt100-ug/chapter3.html#SM
    _ = try writer.write("\x1b[?25h");

    _ = try stdout.write(ab.items);
}

//*** input ***/

//*** init ***/

fn initEditor() !void {
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
