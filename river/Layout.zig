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

const Box = @import("Box.zig");
const Server = @import("Server.zig");
const Output = @import("Output.zig");
const View = @import("View.zig");
const ViewStack = @import("view_stack.zig").ViewStack;
const LayoutDemand = @import("LayoutDemand.zig");

const log = std.log.scoped(.layout);

layout: *zriver.LayoutV1,
namespace: ?[]const u8,
output: *Output,

pub fn init(self: *Self, namespace: [*:0]const u8, output: *Output, client: *wl.Client, version: u32, id: u32) !void {
    self.output = output;

    self.layout = try zriver.LayoutV1.create(client, version, id);
    self.layout.setHandler(*Self, handleRequest, handleDestroy, self);

    var output_it = output.root.outputs.first;
    while (output_it) |output_node| : (output_it = output_node.next) {
        var layout_it = output_node.data.layouts.first;
        if (output_node.data.wlr_output == output.wlr_output) {

            // On this output, no other layout can have our namespace.
            while (layout_it) |layout_node| : (layout_it = layout_node.next) {
                if (std.mem.eql(u8, std.mem.span(namespace), layout_node.data.namespace.?)) {
                    self.layout.sendNamespaceInUse();
                    self.namespace = null;
                    return;
                }
            }
        } else {

            // Layouts on other outputs may share the namespace, if they come from the same client.
            while (layout_it) |layout_node| : (layout_it = layout_node.next) {
                if (std.mem.eql(u8, std.mem.span(namespace), layout_node.data.namespace.?) and
                    layout_node.data.layout.getClient() != self.layout.getClient())
                {
                    self.layout.sendNamespaceInUse();
                    self.namespace = null;
                    return;
                }
            }
        }
    }

    self.namespace = try util.gpa.dupe(u8, std.mem.span(namespace));
}

/// Send a layout demand to the client
pub fn startLayoutDemand(self: *Self, views: u32) void {
    log.debug(
        "starting layout demand '{}' on output '{}'",
        .{ self.namespace, self.output.wlr_output.name },
    );

    self.output.layout_demand = LayoutDemand.new(self.output, views) catch {
        log.err("failed starting layout demand", .{});
        return;
    };

    // Then we let the client know that we require a layout
    self.layout.sendLayoutDemand(
        views,
        self.output.usable_box.width,
        self.output.usable_box.height,
        self.output.layout_demand.?.serial,
    );

    // And finally we advertise all visible views
    var it = ViewStack(View).iter(self.output.views.first, .forward, self.output.pending.tags, Output.arrangeFilter);
    while (it.next()) |view| {
        self.layout.sendAdvertiseView(view.pending.tags, view.getAppId(), self.output.layout_demand.?.serial);
    }
    self.layout.sendAdvertiseDone(self.output.layout_demand.?.serial);
}

fn handleRequest(layout: *zriver.LayoutV1, request: zriver.LayoutV1.Request, self: *Self) void {
    switch (request) {
        .destroy => layout.destroy(),

        // We receive this event when the client wants to push a view dimension proposal
        // to the layout demand matching the serial.
        .push_view_dimensions => |req| {
            log.debug(
                "layout '{}' on output '{}' pushed view dimensions: {} {} {} {}",
                .{ self.namespace, self.output.wlr_output.name, req.x, req.y, req.width, req.height },
            );

            // Are we a valid layout?
            if (self.namespace == null) return;

            // Does the serial match?
            // We can't raise a protocol error when the serial is wrong, because we
            // destroy the LayoutDemand after a timeout or a new layout demand request
            // is raised, so that the client then has no idea that its previously
            // perfectly fine serial is now invalid. So we just ignore requests with
            // wrong serials.
            if (self.output.layout_demand == null) return;
            if (self.output.layout_demand.?.serial != req.serial) return;

            self.output.layout_demand.?.pushViewDimensions(req.x, req.y, req.width, req.height) catch {};
        },

        // We receive this event when the client wants to mark the proposed layout
        // of the layout demand matching the serial as done.
        .commit => |req| {
            log.debug(
                "layout '{}' on output '{}' commited",
                .{ self.namespace, self.output.wlr_output.name },
            );

            // Are we a valid layout?
            if (self.namespace == null) return;

            // Does the serial match?
            if (self.output.layout_demand == null) return;
            if (self.output.layout_demand.?.serial != req.serial) return;

            self.output.layout_demand.?.apply() catch {
                layout.postError(
                    .proposed_dimension_mismatch,
                    "the amount of proposed view dimensions needs to match the amount of views",
                );
            };
        },
    }
}

fn handleDestroy(layout: *zriver.LayoutV1, self: *Self) void {
    log.debug(
        "destroying layout '{}' on output '{}'",
        .{ self.namespace, self.output.wlr_output.name },
    );

    // Remove layout from the list
    const node = @fieldParentPtr(std.TailQueue(Self).Node, "data", self);
    self.output.layouts.remove(node);

    // If we are the current layout of an output, arrange it
    if (std.mem.eql(u8, self.namespace.?, self.output.layout_namespace.?)) {
        self.output.arrangeViews();
        self.output.root.startTransaction();
    }

    if (self.namespace) |namespace| util.gpa.free(namespace);

    util.gpa.destroy(node);
}
