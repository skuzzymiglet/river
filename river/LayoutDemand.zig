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

const Error = error{ViewDimensionMismatch};

const log = std.log.scoped(.layout);

/// Arbitrary timeout
const timeout = 1000;

serial: u32,
views: u32,
output: *Output,

/// Timeout timer
timer: ?*wl.EventSource = null,

/// Proposed view dimensions
view_boxen: std.ArrayList(Box),

pub fn new(output: *Output, views: u32) !Self {
    var demand: Self = .{
        .serial = output.root.server.wl_server.nextSerial(),
        .output = output,
        .views = views,
        .view_boxen = std.ArrayList(Box).init(util.gpa),
    };

    // Attach a timout timer
    const event_loop = output.root.server.wl_server.getEventLoop();
    demand.timer = try event_loop.addTimer(*Self, handleTimeout, &demand);
    errdefer demand.timer.?.remove();
    try demand.timer.?.timerUpdate(timeout);

    return demand;
}

pub fn deinit(self: *const Self) void {
    if (self.timer) |timer| timer.remove();
    self.view_boxen.deinit();
}

/// Destroy the LayoutDemand on timeout.
/// All further responses to the event will simply be ignored.
fn handleTimeout(self: *Self) callconv(.C) c_int {
    log.notice(
        "layout demand for output '{}' timed out",
        .{self.output.wlr_output.name},
    );
    self.deinit();
    const output = self.output;
    if (output.layout_demand) |demand| output.layout_demand = null;

    // Start a transaction, so things that happened while
    // this LayoutDemand was timing out are applied correctly.
    // Remember: An active layout demand blocks all transactions.
    // on the affected output.
    output.root.startTransaction();

    return 0;
}

/// Push a set of proposed view dimensions and position to the list
pub fn pushViewDimensions(self: *Self, x: i32, y: i32, width: u32, height: u32) !void {
    const box = try self.view_boxen.addOne();

    // Here we apply the offset to align the coords with the origin of the
    // usable area and shrink the dimensions to accomodate the border size.
    box.* = .{
        .x = x + self.output.usable_box.x + @intCast(i32, self.output.root.server.config.border_width),
        .y = y + self.output.usable_box.y + @intCast(i32, self.output.root.server.config.border_width),
        .width = if (width > 2 * self.output.root.server.config.border_width)
            width - 2 * self.output.root.server.config.border_width
        else
            width,
        .height = if (height > 2 * self.output.root.server.config.border_width)
            height - 2 * self.output.root.server.config.border_width
        else
            height,
    };
}

/// Apply the proposed layout to the output
pub fn apply(self: *Self) !void {
    const output = self.output;

    // Whether the layout demand succeeds or fails, we need to finish the layout demand
    // and start a transaction.
    defer {
        output.layout_demand.?.deinit();
        output.layout_demand = null;
        output.root.startTransaction();
    }

    // Check if amount of proposed dimensions matches amount of views to arrange
    if (output.layout_demand.?.views != output.layout_demand.?.view_boxen.items.len) {
        log.err(
            "amount of proposed view dimensions ({}) does not match amount of views ({}); Aborting layout demand",
            .{ output.layout_demand.?.view_boxen.items.len, output.layout_demand.?.views },
        );
        return Error.ViewDimensionMismatch;
    }

    // Apply proposed layout to views and start transaction
    var it = ViewStack(View).iter(output.views.first, .forward, output.pending.tags, Output.arrangeFilter);
    var i: u32 = 0;
    while (it.next()) |view| : (i += 1) {
        view.pending.box = output.layout_demand.?.view_boxen.items[i];
        view.applyConstraints();
    }
    output.pending.layout = true;

    // TODO layout name?
}
