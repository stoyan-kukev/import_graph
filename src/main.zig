const std = @import("std");
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

    // Output the import counts, indicating how many imports each file makes
    var iter = importCounts.iterator();
    while (iter.next()) |entry| {
        std.debug.print("{s} imports {d} components\n", .{ entry.key_ptr.*, entry.value_ptr.* });
    }
}
