//! Terminal column width of UTF-8 strings, skipping ANSI escapes so styled
//! text measures to its visible width. Backed by libvaxis' `gwidth`.

const std = @import("std");
const gwidth = @import("vaxis").gwidth;

/// Visible column width of UTF-8 `bytes`. Skips ANSI escapes (CSI and others) and
/// measures the rest grapheme by grapheme.
pub fn displayWidth(bytes: []const u8) usize {
    var w: usize = 0;
    var i: usize = 0;
    var seg_start: usize = 0;
    while (i < bytes.len) {
        if (bytes[i] == 0x1b) { // ESC: flush the visible run, then skip the sequence
            if (i > seg_start) w += gwidth.gwidth(bytes[seg_start..i], .unicode);
            i += 1;
            if (i < bytes.len and bytes[i] == '[') {
                i += 1;
                while (i < bytes.len and !(bytes[i] >= 0x40 and bytes[i] <= 0x7e)) : (i += 1) {}
                if (i < bytes.len) i += 1; // final byte
            } else if (i < bytes.len) {
                i += 1;
            }
            seg_start = i;
            continue;
        }
        i += 1;
    }
    if (i > seg_start) w += gwidth.gwidth(bytes[seg_start..i], .unicode);
    return w;
}

test "displayWidth ignores ANSI and counts runes" {
    try std.testing.expectEqual(@as(usize, 5), displayWidth("hello"));
    try std.testing.expectEqual(@as(usize, 4), displayWidth("\x1b[1mbold\x1b[0m"));
    try std.testing.expectEqual(@as(usize, 2), displayWidth("世")); // wide
}

test "displayWidth handles emoji and combining marks" {
    try std.testing.expectEqual(@as(usize, 2), displayWidth("😀")); // wide emoji
    try std.testing.expectEqual(@as(usize, 1), displayWidth("e\u{0301}")); // e + combining acute = 1
}
