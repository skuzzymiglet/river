// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020 The River Developers
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

const std = @import("std");
const wl = @import("wayland").server.wl;

const Direction = @import("../command.zig").Direction;
const Error = @import("../command.zig").Error;
const Output = @import("../Output.zig");
const Seat = @import("../Seat.zig");

/// Focus either the next or the previous output, depending on the bool passed.
/// Does nothing if there is only one output.
pub fn focusOutput(
    allocator: *std.mem.Allocator,
    seat: *Seat,
    args: []const []const u8,
    out: *?[]const u8,
) Error!void {
    if (args.len < 2) return Error.NotEnoughArguments;
    if (args.len > 2) return Error.TooManyArguments;

    const direction = std.meta.stringToEnum(Direction, args[1]) orelse return Error.InvalidDirection;
    const root = &seat.input_manager.server.root;

    // If the noop output is focused, there are no other outputs to switch to
    if (seat.focused_output == &root.noop_output) {
        std.debug.assert(root.output_layout.outputs.length() == 0);
        return;
    }

    // Focus the next/prev output in the list if there is one, else wrap
    switch (direction) {
        .next => {
            var it = root.outputLayoutIter(.forward);
            seat.focusOutput(while (it.next()) |output| {
                if (output == seat.focused_output)
                    break it.next() orelse root.outputLayoutIter(.forward).next().?;
            } else unreachable);
        },
        .previous => {
            var it = root.outputLayoutIter(.reverse);
            seat.focusOutput(while (it.next()) |output| {
                if (output == seat.focused_output)
                    break it.next() orelse root.outputLayoutIter(.reverse).next().?;
            } else unreachable);
        },
    }

    seat.focus(null);
    root.startTransaction();
}
