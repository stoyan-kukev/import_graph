const std = @import("std");
const rl = @import("raylib");
const Graph = @import("graph/graph.zig").Graph;

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

    var importCounts = std.StringHashMap(usize).init(allocator);
    defer importCounts.deinit();

    while (try walker.next()) |entry| {
        // Only process files ending with `.zig`
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;

        if (entry.kind == .file) {
            const file_contents = try readFile(arena_alloc, entry.path);
            if (file_contents.len == 0) continue;
            defer arena_alloc.free(file_contents);

            const imports = try parseImports(arena_alloc, file_contents);

            // Extract file name from path and duplicate with the arena allocator
            const file_name = try arena_alloc.dupe(u8, std.fs.path.basename(entry.path));

            // Add nodes and edges to the graph
            for (imports.items) |import_item| {
                std.debug.print("{s} imports {s}\n", .{ file_name, import_item });
                try importGraph.addEdge(file_name, import_item);
            }

            // Track how many imports the file makes
            try importCounts.put(file_name, imports.items.len);
        }
    }

    const screenWidth = 800;
    const screenHeight = 600;

    rl.initWindow(screenWidth, screenHeight, "Dependency Graph Visualization");
    defer rl.closeWindow();

    rl.setTargetFPS(60);

    // Variables for graph layout
    const node_radius = 30;
    var node_positions = std.StringHashMap(rl.Vector2).init(allocator);
    defer node_positions.deinit();

    const node_offset = rl.Vector2.init(100.0, 100.0);

    // Calculate dependency levels
    var dependency_levels = std.StringHashMap(usize).init(allocator);
    defer dependency_levels.deinit();

    var iter = importGraph.getAllNodes();
    while (iter.next()) |node_name| {
        var level: usize = 0;
        if (importGraph.getAdjacentNodes(node_name.*)) |adjacent_nodes| {
            level = adjacent_nodes.count();
        }
        try dependency_levels.put(node_name.*, level);
    }

    // Find max dependency level
    var max_level: usize = 0;
    var level_iter = dependency_levels.iterator();
    while (level_iter.next()) |entry| {
        if (entry.value_ptr.* > max_level) {
            max_level = entry.value_ptr.*;
        }
    }

    // Calculate node positions based on dependency levels
    iter = importGraph.getAllNodes();
    while (iter.next()) |node_name| {
        const level = dependency_levels.get(node_name.*) orelse 0;
        const y_pos = @as(f32, @floatFromInt(max_level - level)) / @as(f32, @floatFromInt(max_level + 1)) * screenHeight;
        const offset = rl.Vector2.init(node_offset.x, y_pos);
        try node_positions.put(node_name.*, offset);
    }

    while (!rl.windowShouldClose()) { // Main game loop
        rl.beginDrawing();
        defer rl.endDrawing();

        rl.clearBackground(rl.Color.white);

        // Draw nodes and edges
        var iter_nodes = node_positions.iterator();
        while (iter_nodes.next()) |entry| {
            const node_name = try std.fmt.allocPrintZ(allocator, "{s}", .{entry.key_ptr.*});
            defer allocator.free(node_name);

            const node_pos = entry.value_ptr.*;

            // Draw node circle
            rl.drawCircleV(node_pos, node_radius, rl.Color.sky_blue);

            // Draw node name using null-terminated string
            const x: i32 = @intFromFloat(node_pos.x - 20);
            const y: i32 = @intFromFloat(node_pos.y - 10);
            rl.drawText(node_name, x, y, 10, rl.Color.dark_gray);

            // Get adjacent nodes and draw edges
            if (importGraph.getAdjacentNodes(node_name)) |adjacent_nodes| {
                var adj_iter = adjacent_nodes.iterator();
                while (adj_iter.next()) |adj_node| {
                    if (node_positions.get(adj_node.key_ptr.*)) |adj_pos| {
                        rl.drawLineV(node_pos, adj_pos, rl.Color.black); // Draw edge
                    }
                }
            }
        }

        rl.drawText("Dependency Graph", 10, 10, 20, rl.Color.dark_gray);
    }
}
