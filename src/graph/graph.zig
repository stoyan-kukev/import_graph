const std = @import("std");

pub fn Graph() type {
    return struct {
        const Self = @This();
        const NodeSet = std.StringHashMap(void);
        const AdjList = std.StringHashMap(NodeSet);
        const ImportCount = std.StringHashMap(usize);

        allocator: std.mem.Allocator,
        nodes: AdjList,
        import_count: ImportCount,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .nodes = AdjList.init(allocator),
                .import_count = ImportCount.init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            var it = self.nodes.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.deinit();
            }
            self.nodes.deinit();
            self.import_count.deinit();
        }

        pub fn addNode(self: *Self, node: []const u8) !void {
            if (!self.nodes.contains(node)) {
                const set = NodeSet.init(self.allocator);
                try self.nodes.put(node, set);
                try self.import_count.put(node, 0);
            }
        }

        pub fn addEdge(self: *Self, from: []const u8, to: []const u8) !void {
            try self.addNode(from);
            try self.addNode(to);
            var set = self.nodes.getPtr(from).?;
            try set.put(to, {});

            const count = self.import_count.getPtr(to).?;
            count.* += 1;
        }

        pub fn getImportCount(self: *Self, node: []const u8) usize {
            return self.import_count.get(node) orelse 0;
        }

        pub fn removeNode(self: *Self, node: []const u8) void {
            if (self.nodes.fetchRemove(node)) |kv| {
                kv.value.deinit();
            }

            var it = self.nodes.iterator();
            while (it.next()) |entry| {
                _ = entry.value_ptr.remove(node);
            }
        }

        pub fn removeEdge(self: *Self, from: []const u8, to: []const u8) void {
            if (self.nodes.getPtr(from)) |set| {
                _ = set.remove(to);
            }
        }

        pub fn getAdjacentNodes(self: *Self, node: []const u8) ?NodeSet {
            return self.nodes.get(node);
        }

        pub fn getAllNodes(self: *Self) AdjList.KeyIterator {
            return self.nodes.keyIterator();
        }

        pub fn hasNode(self: *Self, node: []const u8) bool {
            return self.nodes.contains(node);
        }

        pub fn hasEdge(self: *Self, from: []const u8, to: []const u8) bool {
            if (self.nodes.get(from)) |set| {
                return set.contains(to);
            }
            return false;
        }
    };
}
