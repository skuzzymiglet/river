// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020 - 2021 The River Developers
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

const Self = @This();

const std = @import("std");
const wlr = @import("wlroots");
const wayland = @import("wayland");
const wl = wayland.server.wl;
const zriver = wayland.server.zriver;

const util = @import("util.zig");

const Layout = @import("Layout.zig");
const Box = @import("Box.zig");
const Server = @import("Server.zig");
const Output = @import("Output.zig");
const View = @import("View.zig");
const ViewStack = @import("view_stack.zig").ViewStack;

const log = std.log.scoped(.layout);

/// Arbitrary timeout
const timeout = 1000;

serial: u32,
/// Number of views for which dimensions have not been pushed.
/// This will go negative if the client pushes too many dimensions.
views: i32,
/// Timeout timer
timer: *wl.EventSource,
/// Proposed view dimensions
view_boxen: []Box,

pub fn init(output: *Output, views: u32) !Self {
    const event_loop = output.root.server.wl_server.getEventLoop();
    // Pass a pointer to the output as it is stable unlike a pointer
    // to this layout demand.
    const timer = try event_loop.addTimer(*Output, handleTimeout, output);
    errdefer timer.remove();
    try timer.timerUpdate(timeout);

    return Self{
        .serial = output.root.server.wl_server.nextSerial(),
        .views = @intCast(i32, views),
        .timer = timer,
        .view_boxen = try util.gpa.alloc(Box, views),
    };
}

pub fn deinit(self: Self) void {
    self.timer.remove();
    util.gpa.free(self.view_boxen);
}

/// Destroy the LayoutDemand on timeout.
/// All further responses to the event will simply be ignored.
fn handleTimeout(output: *Output) callconv(.C) c_int {
    log.notice(
        "layout demand for output '{}' timed out",
        .{output.wlr_output.name},
    );
    output.layout_demand.?.deinit();
    output.layout_demand = null;

    // Start a transaction, so things that happened while
    // this LayoutDemand was timing out are applied correctly.
    // Remember: An active layout demand blocks all transactions.
    // on the affected output.
    output.root.startTransaction();

    return 0;
}

/// Push a set of proposed view dimensions and position to the list
pub fn pushViewDimensions(self: *Self, output: *Output, x: i32, y: i32, width: u32, height: u32) void {
    // The client pushed too many dimensions
    if (self.views < 0) return;

    // Here we apply the offset to align the coords with the origin of the
    // usable area and shrink the dimensions to accomodate the border size.
    const border_width = output.root.server.config.border_width;
    self.view_boxen[self.view_boxen.len - @intCast(usize, self.views)] = .{
        .x = x + output.usable_box.x + @intCast(i32, border_width),
        .y = y + output.usable_box.y + @intCast(i32, border_width),
        .width = if (width > 2 * border_width) width - 2 * border_width else width,
        .height = if (height > 2 * border_width) height - 2 * border_width else height,
    };

    self.views -= 1;
}

/// Apply the proposed layout to the output
pub fn apply(self: *Self, output: *Output) error{ViewDimensionMismatch}!void {
    // Whether the layout demand succeeds or fails, we need to finish the layout demand
    // and start a transaction.
    defer {
        self.deinit();
        output.layout_demand = null;
        output.root.startTransaction();
    }

    // Check if amount of proposed dimensions matches amount of views to arrange
    if (self.views != 0) {
        log.err(
            "amount of proposed view dimensions ({}) does not match amount of views ({}); Aborting layout demand",
            .{ -self.views + @intCast(i32, self.view_boxen.len), self.view_boxen.len },
        );
        return error.ViewDimensionMismatch;
    }

    // Apply proposed layout to views and start transaction
    var it = ViewStack(View).iter(output.views.first, .forward, output.pending.tags, Output.arrangeFilter);
    var i: usize = 0;
    while (it.next()) |view| : (i += 1) {
        view.pending.box = self.view_boxen[i];
        view.applyConstraints();
    }
    std.debug.assert(i == self.view_boxen.len);

    output.pending.layout = true;
}
