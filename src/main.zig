const std = @import("std");
const rl = @import("raylib");
const Graph = @import("graph/graph.zig").Graph;

fn normalizePath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    // Remove the file extension
    const without_ext = std.fs.path.stem(path);

    // Split the path into components
    var iter = std.mem.split(u8, without_ext, "/");
    var components = std.ArrayList([]const u8).init(allocator);
    defer components.deinit();

    while (iter.next()) |component| {
        try components.append(component);
    }

    // Join the last two components (or just the last if there's only one)
    const num_components = components.items.len;
    if (num_components > 1) {
        return try std.fmt.allocPrint(allocator, "{s}/{s}", .{
            components.items[num_components - 2],
            components.items[num_components - 1],
        });
    } else {
        return try allocator.dupe(u8, components.items[0]);
    }
}

pub fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    std.debug.print("READING FILE: {s}\n", .{path});
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const file_size = try file.getEndPos();
    const buffer = try allocator.alloc(u8, file_size);
    errdefer allocator.free(buffer);

    const bytes_read = try file.readAll(buffer);
    if (bytes_read != file_size) return error.IncompleteRead;

    return buffer;
}

pub fn parseImports(allocator: std.mem.Allocator, contents: []const u8) !std.ArrayList([]const u8) {
    var imports = std.ArrayList([]const u8).init(allocator);
    errdefer {
        for (imports.items) |item| {
            allocator.free(item);
        }
        imports.deinit();
    }

    const window = "@import(\"";

    var i: usize = 0;
    while (i < contents.len - window.len) : (i += 1) {
        const slice = contents[i .. i + window.len];
        if (std.mem.eql(u8, slice, window)) {
            i += window.len;
            var j: usize = i;
            while (contents[j] != '"') : (j += 1) {}

            try imports.append(try allocator.dupe(u8, contents[i..j]));
        }
    }

    return imports;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var importGraph = Graph().init(allocator);
    defer importGraph.deinit();

    var dir = try std.fs.cwd().openDir(".", .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer _ = arena.deinit();
    const arena_alloc = arena.allocator();

    while (try walker.next()) |entry| {
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;

        if (entry.kind == .file) {
            const file_contents = try readFile(arena_alloc, entry.path);
            if (file_contents.len == 0) continue;
            defer arena_alloc.free(file_contents);

            const imports = try parseImports(arena_alloc, file_contents);

            const normalized_file_name = try normalizePath(arena_alloc, entry.path);

            for (imports.items) |import_item| {
                const normalized_import = try normalizePath(arena_alloc, import_item);
                std.debug.print("{s} imports {s}\n", .{ normalized_file_name, normalized_import });
                try importGraph.addEdge(normalized_import, normalized_file_name);
            }
        }
    }

    const screenWidth = 1920;
    const screenHeight = 1080;

    rl.initWindow(screenWidth, screenHeight, "Dependency Graph Visualization");
    defer rl.closeWindow();

    rl.setTargetFPS(60);

    const node_radius = 20;
    var node_positions = std.StringHashMap(rl.Vector2).init(allocator);
    defer node_positions.deinit();

    // Calculate dependency levels and total import count
    var dependency_levels = std.StringHashMap(usize).init(allocator);
    defer dependency_levels.deinit();
    var max_level: usize = 0;

    var iter = importGraph.getAllNodes();
    while (iter.next()) |node_name| {
        const import_count = importGraph.getImportCount(node_name.*);
        try dependency_levels.put(node_name.*, import_count);
        if (import_count > max_level) max_level = import_count;
    }

    // Calculate node positions based on dependency levels
    const vertical_spacing = (screenHeight - 100) / @as(f32, @floatFromInt(max_level + 1));
    const horizontal_margin = 100;

    iter = importGraph.getAllNodes();
    var level_counts = try allocator.alloc(usize, max_level + 1);
    defer allocator.free(level_counts);
    @memset(level_counts, 0);

    while (iter.next()) |node_name| {
        const level = dependency_levels.get(node_name.*) orelse 0;
        const y = screenHeight - 50 - vertical_spacing * @as(f32, @floatFromInt(level));
        const nodes_at_level = blk: {
            var count: usize = 0;
            var it = dependency_levels.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.* == level) count += 1;
            }
            break :blk count;
        };
        const horizontal_spacing = (screenWidth - 2 * horizontal_margin) / @as(f32, @floatFromInt(nodes_at_level + 1));
        const x = horizontal_margin + horizontal_spacing * (@as(f32, @floatFromInt(level_counts[level] + 1)));
        try node_positions.put(node_name.*, rl.Vector2.init(x, y));
        level_counts[level] += 1;
    }

    while (!rl.windowShouldClose()) {
        rl.beginDrawing();
        defer rl.endDrawing();

        rl.clearBackground(rl.Color.white);

        // Draw edges
        var edge_iter = importGraph.nodes.iterator();
        while (edge_iter.next()) |entry| {
            const from_node = entry.key_ptr.*;
            const from_pos = node_positions.get(from_node) orelse continue;

            var adj_set = entry.value_ptr;
            var adj_iter = adj_set.keyIterator();
            while (adj_iter.next()) |to_node| {
                const to_pos = node_positions.get(to_node.*) orelse continue;

                // Calculate direction vector
                const dir_x = to_pos.x - from_pos.x;
                const dir_y = to_pos.y - from_pos.y;
                const length = @sqrt(dir_x * dir_x + dir_y * dir_y);
                const unit_x = dir_x / length;
                const unit_y = dir_y / length;

                // Calculate start and end points, leaving space for nodes
                const start_x = from_pos.x + unit_x * node_radius;
                const start_y = from_pos.y + unit_y * node_radius;
                const end_x = to_pos.x - unit_x * node_radius;
                const end_y = to_pos.y - unit_y * node_radius;

                // Calculate control point for curved edges
                const ctrl_x = (start_x + end_x) / 2 + (end_y - start_y) / 4;
                const ctrl_y = (start_y + end_y) / 2 - (end_x - start_x) / 4;

                // Draw curved edge
                rl.drawSplineBezierQuadratic(&.{ rl.Vector2.init(start_x, start_y), rl.Vector2.init(ctrl_x, ctrl_y), rl.Vector2.init(end_x, end_y) }, 2, rl.Color.light_gray);

                // Draw arrowhead
                const arrow_size: f32 = 10;
                const arrow_angle: f32 = std.math.pi / @as(f32, 6); // 30 degrees

                const tangent_x = end_x - ctrl_x;
                const tangent_y = end_y - ctrl_y;
                const tangent_length = @sqrt(tangent_x * tangent_x + tangent_y * tangent_y);
                const arrow_unit_x = tangent_x / tangent_length;
                const arrow_unit_y = tangent_y / tangent_length;

                const arrow_x1 = end_x - arrow_size * (@cos(arrow_angle) * arrow_unit_x + @sin(arrow_angle) * arrow_unit_y);
                const arrow_y1 = end_y - arrow_size * (@cos(arrow_angle) * arrow_unit_y - @sin(arrow_angle) * arrow_unit_x);
                const arrow_x2 = end_x - arrow_size * (@cos(arrow_angle) * arrow_unit_x - @sin(arrow_angle) * arrow_unit_y);
                const arrow_y2 = end_y - arrow_size * (@cos(arrow_angle) * arrow_unit_y + @sin(arrow_angle) * arrow_unit_x);

                rl.drawLineEx(rl.Vector2.init(end_x, end_y), rl.Vector2.init(arrow_x1, arrow_y1), 2, rl.Color.gray);
                rl.drawLineEx(rl.Vector2.init(end_x, end_y), rl.Vector2.init(arrow_x2, arrow_y2), 2, rl.Color.gray);
            }
        }

        // Draw nodes and labels
        var node_iter = node_positions.iterator();
        while (node_iter.next()) |entry| {
            const node_name = entry.key_ptr.*;
            const node_pos = entry.value_ptr.*;
            const import_count = importGraph.getImportCount(node_name);

            const node_color = if (import_count > 0)
                rl.Color.init(@intFromFloat(255 * (1 - @as(f32, @floatFromInt(import_count)) / @as(f32, @floatFromInt(max_level)))), @intFromFloat(255 * @as(f32, @floatFromInt(import_count)) / @as(f32, @floatFromInt(max_level))), 0, 255)
            else
                rl.Color.sky_blue;

            rl.drawCircleV(node_pos, node_radius, node_color);

            const label = try std.fmt.allocPrintZ(allocator, "{s} ({d})", .{ node_name, import_count });
            defer allocator.free(label);

            const text_width = rl.measureText(label, 10);
            const x: i32 = @intFromFloat(node_pos.x - @as(f32, @floatFromInt(text_width)) / 2);
            const y: i32 = @intFromFloat(node_pos.y + @as(f32, node_radius) + 5);
            rl.drawText(label, x, y, 20, rl.Color.dark_gray);
        }

        rl.drawText("Dependency Graph - Arrows point from imported files", 10, 10, 30, rl.Color.dark_gray);
    }
}
