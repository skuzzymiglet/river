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
const Server = @import("Server.zig");
const Output = @import("Output.zig");

const log = std.log.scoped(.layout);

global: *wl.Global,
server_destroy: wl.Listener(*wl.Server) = wl.Listener(*wl.Server).init(handleServerDestroy),

pub fn init(self: *Self, server: *Server) !void {
    self.* = .{
        .global = try wl.Global.create(server.wl_server, zriver.LayoutManagerV1, 1, *Self, self, bind),
    };

    server.wl_server.addDestroyListener(&self.server_destroy);
}

fn handleServerDestroy(listener: *wl.Listener(*wl.Server), wl_server: *wl.Server) void {
    const self = @fieldParentPtr(Self, "server_destroy", listener);
    self.global.destroy();
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) callconv(.C) void {
    const layout_manager = zriver.LayoutManagerV1.create(client, version, id) catch {
        client.postNoMemory();
        log.crit("out of memory", .{});
        return;
    };
    layout_manager.setHandler(*Self, handleRequest, null, self);
}

fn handleRequest(layout_manager: *zriver.LayoutManagerV1, request: zriver.LayoutManagerV1.Request, self: *Self) void {
    switch (request) {
        .destroy => layout_manager.destroy(),

        .get_river_layout => |req| {
            // Ignore if the output is inert
            const wlr_output = wlr.Output.fromWlOutput(req.output) orelse return;
            const output = @intToPtr(*Output, wlr_output.data);

            log.debug("bind layout '{}' on output '{}'", .{ req.namespace, output.wlr_output.name });

            const node = util.gpa.create(std.TailQueue(Layout).Node) catch {
                layout_manager.getClient().postNoMemory();
                log.crit("out of memory", .{});
                return;
            };
            node.data.init(req.namespace, output, layout_manager.getClient(), 1, req.id) catch {
                layout_manager.getClient().postNoMemory();
                log.crit("out of memory", .{});
                util.gpa.destroy(node);
                return;
            };
            output.layouts.append(node);

            // If the namespace matches that of the output, it would affect the output
            // on the next arrange. We are triggering that now because otherwise there
            // would be, from the users point of view, an unexpected layout happening
            // at some point.
            if (std.mem.eql(u8, node.data.namespace.?, output.layout_namespace.?)) {
                output.arrangeViews();
                output.root.startTransaction();
            }
        },
    }
}
