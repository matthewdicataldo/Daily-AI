const std = @import("std");
const claude = @import("ai_claude.zig");
const types = @import("core_types.zig");

/// Search strategy determined by the LLM
pub const SearchStrategy = enum {
    breadth_first,
    depth_first,
    best_first,
    adaptive,
    exploration,
    exploitation,

    // Paper-inspired simple mode
    simple_binary,

    pub fn toString(self: SearchStrategy) []const u8 {
        return switch (self) {
            .breadth_first => "breadth_first",
            .depth_first => "depth_first",
            .best_first => "best_first",
            .adaptive => "adaptive",
            .exploration => "exploration",
            .exploitation => "exploitation",
            .simple_binary => "simple_binary",
        };
    }
};

/// Search decision made by the LLM
pub const SearchDecision = struct {
    action: SearchAction,
    strategy: SearchStrategy,
    confidence: f32,
    reasoning: []const u8,
    next_queries: [][]const u8,

    pub fn deinit(self: SearchDecision, allocator: std.mem.Allocator) void {
        allocator.free(self.reasoning);
        for (self.next_queries) |query| {
            allocator.free(query);
        }
        allocator.free(self.next_queries);
    }
};

/// Search action determined by LLM
pub const SearchAction = enum {
    continue_path,
    explore_alternative,
    backtrack,
    terminate_success,
    terminate_failure,
    split_search,
    merge_results,

    // Paper-inspired simple actions
    simple_continue,
    simple_explore,
};

/// Search node in the LLM-guided search tree
pub const SearchNode = struct {
    id: u64,
    query: []const u8,
    results: []types.NewsItem,
    parent: ?*SearchNode,
    children: std.ArrayList(*SearchNode),

    // LLM-evaluated metrics
    relevance_score: f32,
    information_value: f32,
    exploration_potential: f32,
    confidence: f32,

    // Search metadata
    depth: u32,
    visited: bool,
    expanded: bool,
    timestamp: i64,

    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, id: u64, query: []const u8, parent: ?*SearchNode) !Self {
        return Self{
            .id = id,
            .query = try allocator.dupe(u8, query),
            .results = &[_]types.NewsItem{},
            .parent = parent,
            .children = std.ArrayList(*SearchNode).init(allocator),
            .relevance_score = 0.0,
            .information_value = 0.0,
            .exploration_potential = 0.5,
            .confidence = 0.0,
            .depth = if (parent) |p| p.depth + 1 else 0,
            .visited = false,
            .expanded = false,
            .timestamp = std.time.milliTimestamp(),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.query);
        for (self.results) |result| {
            result.deinit(self.allocator);
        }
        self.allocator.free(self.results);

        for (self.children.items) |child| {
            child.deinit();
            self.allocator.destroy(child);
        }
        self.children.deinit();
    }

    pub fn addChild(self: *Self, child: *SearchNode) !void {
        try self.children.append(child);
    }

    pub fn setResults(self: *Self, results: []types.NewsItem) !void {
        // Free previous results
        for (self.results) |result| {
            result.deinit(self.allocator);
        }
        self.allocator.free(self.results);

        // Set new results
        self.results = try self.allocator.dupe(types.NewsItem, results);
    }
};

/// Priority queue entry for paper-inspired simple search mode
pub const QueueEntry = struct {
    value: f32,
    query: []const u8,
    depth: u32,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, value: f32, query: []const u8, depth: u32) !QueueEntry {
        return QueueEntry{
            .value = value,
            .query = try allocator.dupe(u8, query),
            .depth = depth,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *QueueEntry) void {
        self.allocator.free(self.query);
    }

    pub fn lessThan(_: void, a: QueueEntry, b: QueueEntry) std.math.Order {
        if (a.value > b.value) return .lt; // Higher values have higher priority
        if (a.value < b.value) return .gt;
        return .eq;
    }
};

/// LLM-First Search Engine implementation
pub const LLMFirstSearchEngine = struct {
    allocator: std.mem.Allocator,
    claude_client: *claude.ClaudeClient,

    // Search state
    search_tree: std.ArrayList(*SearchNode),
    current_node: ?*SearchNode,
    node_counter: u64,
    max_depth: u32,
    max_nodes: u32,

    // Paper-inspired simple search mode
    priority_queue: std.PriorityQueue(QueueEntry, void, QueueEntry.lessThan),
    simple_mode: bool,

    // Search statistics
    total_queries: u32,
    llm_decisions: u32,
    successful_paths: u32,
    backtrack_count: u32,

    // Performance tracking (inspired by original implementation)
    token_usage: u32,
    search_start_time: i64,
    total_search_time: i64,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, claude_client: *claude.ClaudeClient) Self {
        return Self{
            .allocator = allocator,
            .claude_client = claude_client,
            .search_tree = std.ArrayList(*SearchNode).init(allocator),
            .current_node = null,
            .node_counter = 0,
            .max_depth = 10,
            .max_nodes = 100,
            .priority_queue = std.PriorityQueue(QueueEntry, void, QueueEntry.lessThan).init(allocator, {}),
            .simple_mode = false,
            .total_queries = 0,
            .llm_decisions = 0,
            .successful_paths = 0,
            .backtrack_count = 0,
            .token_usage = 0,
            .search_start_time = 0,
            .total_search_time = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.search_tree.items) |node| {
            node.deinit();
            self.allocator.destroy(node);
        }
        self.search_tree.deinit();

        // Clean up priority queue
        while (self.priority_queue.removeOrNull()) |entry| {
            var mutable_entry = entry;
            mutable_entry.deinit();
        }
        self.priority_queue.deinit();
    }

    /// Enable simple binary mode (inspired by original paper)
    pub fn enableSimpleMode(self: *Self) void {
        self.simple_mode = true;
        std.log.info("🔄 Enabled simple binary search mode (paper-inspired)", .{});
    }

    /// Execute simplified LLM-guided search with timeouts and circuit breakers
    pub fn search(self: *Self, initial_query: []const u8, search_interface: anytype) ![]types.NewsItem {
        std.log.info("🔍 Starting Simplified LLM-First Search for: {s}", .{initial_query});

        // Track search timing and add timeout
        self.search_start_time = std.time.milliTimestamp();
        const search_timeout_ms = 30000; // 30 second timeout

        // Create root node
        const root_node = try self.allocator.create(SearchNode);
        root_node.* = try SearchNode.init(self.allocator, self.getNextNodeId(), initial_query, null);
        try self.search_tree.append(root_node);
        self.current_node = root_node;

        // Execute initial search
        try self.executeSearchAtNode(root_node, search_interface);

        // Simplified search loop with strict limits
        var iteration: u32 = 0;
        const max_iterations = 3; // Reduced from 20 to 3
        const max_llm_calls = 2; // Limit expensive LLM decision calls

        while (iteration < max_iterations and self.llm_decisions < max_llm_calls) {
            defer iteration += 1;

            // Check timeout
            const elapsed = std.time.milliTimestamp() - self.search_start_time;
            if (elapsed > search_timeout_ms) {
                std.log.warn("⏰ LLM-First Search timeout ({d}ms), terminating early", .{elapsed});
                break;
            }

            // Quick evaluation instead of complex LLM decision
            if (root_node.results.len > 0) {
                std.log.info("✅ Found {d} results, terminating search early", .{root_node.results.len});
                break;
            }

            // Simplified decision making - only do one LLM call if needed
            if (self.llm_decisions == 0 and root_node.results.len == 0) {
                const decision = self.getSimplifiedLLMDecision() catch |err| {
                    std.log.warn("⚠️ LLM decision failed: {}, using fallback", .{err});
                    break;
                };
                defer decision.deinit(self.allocator);

                std.log.info("🤖 Simplified Decision: {s}", .{@tagName(decision.action)});
                
                const should_continue = try self.executeSimplifiedDecision(decision, search_interface);
                if (!should_continue) break;
            } else {
                break; // Exit after first iteration if we have results or already made a decision
            }
        }

        // Collect results without expensive LLM ranking
        const final_results = try self.collectResultsSimple();

        // Calculate total search time
        self.total_search_time = std.time.milliTimestamp() - self.search_start_time;

        std.log.info("✅ Simplified LLM-First Search completed: {d} queries, {d} LLM decisions, {d} results in {d}ms", .{ self.total_queries, self.llm_decisions, final_results.len, self.total_search_time });

        return final_results;
    }

    /// Execute search at a specific node
    fn executeSearchAtNode(self: *Self, node: *SearchNode, search_interface: anytype) !void {
        if (node.visited) return;

        std.log.info("🎯 Executing search: {s} (depth: {d})", .{ node.query, node.depth });

        // Perform the actual search using the provided interface
        const results = try search_interface.search(node.query);
        try node.setResults(results);

        node.visited = true;
        self.total_queries += 1;

        // Let LLM evaluate the results
        try self.evaluateNodeWithLLM(node);
    }

    /// Get simplified LLM decision with timeout
    fn getSimplifiedLLMDecision(self: *Self) !SearchDecision {
        // Skip complex context building for speed
        const simple_prompt = try std.fmt.allocPrint(self.allocator,
            \\Current search has {d} results. Should I:
            \\A) terminate_success - Results are sufficient
            \\B) simple_explore - Try one more search term
            \\C) terminate_failure - Stop searching
            \\
            \\Respond with just: {{"action": "terminate_success"}}
        , .{if (self.current_node) |node| node.results.len else 0});
        defer self.allocator.free(simple_prompt);

        const llm_response = self.claude_client.executeClaude(simple_prompt) catch |err| {
            std.log.warn("⚠️ LLM call failed: {}, using fallback decision", .{err});
            // Return fallback decision
            return SearchDecision{
                .action = .terminate_success,
                .strategy = .simple_binary,
                .confidence = 0.5,
                .reasoning = try self.allocator.dupe(u8, "Fallback decision due to LLM failure"),
                .next_queries = &[_][]const u8{},
            };
        };
        defer self.allocator.free(llm_response);

        self.llm_decisions += 1;
        self.token_usage += @as(u32, @intCast(llm_response.len / 4));

        return try self.parseSimpleDecision(llm_response);
    }

    /// Get original LLM decision for next search action (kept for compatibility)
    fn getLLMSearchDecision(self: *Self) !SearchDecision {
        const context = try self.buildSearchContext();
        defer self.allocator.free(context);

        const decision_prompt = if (self.simple_mode)
            try std.fmt.allocPrint(self.allocator,
                \\You are an AI search strategist using simple binary decisions (inspired by LLM-First Search paper).
                \\
                \\Current Search Context:
                \\{s}
                \\
                \\Simple Binary Decision:
                \\1. simple_continue - Continue with current path and add alternatives to queue
                \\2. simple_explore - Explore alternative from priority queue
                \\
                \\Respond in JSON format:
                \\{{
                \\  "action": "simple_continue|simple_explore",
                \\  "strategy": "simple_binary",
                \\  "confidence": 0.0-1.0,
                \\  "reasoning": "Brief explanation of binary decision",
                \\  "next_queries": ["query1", "query2", ...]
                \\}}
            , .{context})
        else
            try std.fmt.allocPrint(self.allocator,
                \\You are an AI search strategist. Analyze the current search state and decide the next action.
                \\
                \\Current Search Context:
                \\{s}
                \\
                \\Available Actions:
                \\1. continue_path - Continue expanding current promising path
                \\2. explore_alternative - Try a different search direction
                \\3. backtrack - Go back to previous node and try different path
                \\4. terminate_success - Search found sufficient results
                \\5. terminate_failure - Search should stop due to poor results
                \\6. split_search - Split query into multiple parallel searches
                \\7. merge_results - Combine results from different paths
                \\
                \\Respond in JSON format:
                \\{{
                \\  "action": "action_name",
                \\  "strategy": "breadth_first|depth_first|best_first|adaptive|exploration|exploitation|simple_binary",
                \\  "confidence": 0.0-1.0,
                \\  "reasoning": "Brief explanation of decision",
                \\  "next_queries": ["query1", "query2", ...]
                \\}}
            , .{context});
        defer self.allocator.free(decision_prompt);

        const llm_response = try self.claude_client.executeClaude(decision_prompt);
        defer self.allocator.free(llm_response);

        self.llm_decisions += 1;

        // Track token usage (estimate based on response length)
        self.token_usage += @as(u32, @intCast(llm_response.len / 4)); // Rough approximation

        return try self.parseSearchDecision(llm_response);
    }

    /// Build context string for LLM decision making
    fn buildSearchContext(self: *Self) ![]const u8 {
        var context = std.ArrayList(u8).init(self.allocator);
        defer context.deinit();

        const writer = context.writer();

        try writer.print("Search Tree State:\n", .{});
        try writer.print("- Total nodes: {d}\n", .{self.search_tree.items.len});
        try writer.print("- Current depth: {d}\n", .{if (self.current_node) |node| node.depth else 0});
        try writer.print("- Total queries executed: {d}\n", .{self.total_queries});

        if (self.current_node) |node| {
            try writer.print("\nCurrent Node:\n", .{});
            try writer.print("- Query: {s}\n", .{node.query});
            try writer.print("- Results count: {d}\n", .{node.results.len});
            try writer.print("- Relevance score: {d:.2}\n", .{node.relevance_score});
            try writer.print("- Information value: {d:.2}\n", .{node.information_value});
            try writer.print("- Exploration potential: {d:.2}\n", .{node.exploration_potential});

            // Sample some results for context
            if (node.results.len > 0) {
                try writer.print("\nSample Results:\n", .{});
                const sample_count = @min(node.results.len, 3);
                for (node.results[0..sample_count]) |result| {
                    try writer.print("- {s} (score: {d:.2})\n", .{ result.title, result.relevance_score });
                }
            }
        }

        // Add information about other promising nodes or priority queue
        if (self.simple_mode) {
            try writer.print("\nPriority Queue Status:\n", .{});
            try writer.print("- Queue size: {d}\n", .{self.priority_queue.count()});
            if (self.priority_queue.count() > 0) {
                try writer.print("- Has alternatives available for exploration\n", .{});
            } else {
                try writer.print("- No alternatives in queue\n", .{});
            }
        } else {
            try writer.print("\nOther Nodes:\n", .{});
            var node_count: u32 = 0;
            for (self.search_tree.items) |node| {
                if (node == self.current_node) continue;
                if (node_count >= 5) break; // Limit context size

                try writer.print("- \"{s}\" (depth: {d}, score: {d:.2})\n", .{ node.query, node.depth, node.relevance_score });
                node_count += 1;
            }
        }

        return try context.toOwnedSlice();
    }

    /// Parse LLM response into SearchDecision
    fn parseSearchDecision(self: *Self, llm_response: []const u8) !SearchDecision {
        // Extract JSON from LLM response (simplified parsing)
        const json_start = std.mem.indexOf(u8, llm_response, "{") orelse 0;
        const json_end = std.mem.lastIndexOf(u8, llm_response, "}") orelse llm_response.len - 1;

        if (json_end <= json_start) {
            // Fallback decision if parsing fails
            return SearchDecision{
                .action = .continue_path,
                .strategy = .adaptive,
                .confidence = 0.5,
                .reasoning = try self.allocator.dupe(u8, "Fallback decision due to parsing error"),
                .next_queries = &[_][]const u8{},
            };
        }

        const json_slice = llm_response[json_start .. json_end + 1];

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const temp_allocator = arena.allocator();

        const parsed = std.json.parseFromSlice(std.json.Value, temp_allocator, json_slice, .{}) catch {
            // Fallback decision
            return SearchDecision{
                .action = .continue_path,
                .strategy = .adaptive,
                .confidence = 0.5,
                .reasoning = try self.allocator.dupe(u8, "Fallback decision due to JSON parsing error"),
                .next_queries = &[_][]const u8{},
            };
        };
        defer parsed.deinit();

        const json_obj = parsed.value.object;

        // Parse action
        const action = if (json_obj.get("action")) |action_val| blk: {
            if (action_val == .string) {
                const action_str = action_val.string;
                if (std.mem.eql(u8, action_str, "continue_path")) break :blk SearchAction.continue_path;
                if (std.mem.eql(u8, action_str, "explore_alternative")) break :blk SearchAction.explore_alternative;
                if (std.mem.eql(u8, action_str, "backtrack")) break :blk SearchAction.backtrack;
                if (std.mem.eql(u8, action_str, "terminate_success")) break :blk SearchAction.terminate_success;
                if (std.mem.eql(u8, action_str, "terminate_failure")) break :blk SearchAction.terminate_failure;
                if (std.mem.eql(u8, action_str, "split_search")) break :blk SearchAction.split_search;
                if (std.mem.eql(u8, action_str, "merge_results")) break :blk SearchAction.merge_results;
                if (std.mem.eql(u8, action_str, "simple_continue")) break :blk SearchAction.simple_continue;
                if (std.mem.eql(u8, action_str, "simple_explore")) break :blk SearchAction.simple_explore;
            }
            break :blk SearchAction.continue_path;
        } else SearchAction.continue_path;

        // Parse strategy
        const strategy = if (json_obj.get("strategy")) |strategy_val| blk: {
            if (strategy_val == .string) {
                const strategy_str = strategy_val.string;
                if (std.mem.eql(u8, strategy_str, "breadth_first")) break :blk SearchStrategy.breadth_first;
                if (std.mem.eql(u8, strategy_str, "depth_first")) break :blk SearchStrategy.depth_first;
                if (std.mem.eql(u8, strategy_str, "best_first")) break :blk SearchStrategy.best_first;
                if (std.mem.eql(u8, strategy_str, "adaptive")) break :blk SearchStrategy.adaptive;
                if (std.mem.eql(u8, strategy_str, "exploration")) break :blk SearchStrategy.exploration;
                if (std.mem.eql(u8, strategy_str, "exploitation")) break :blk SearchStrategy.exploitation;
                if (std.mem.eql(u8, strategy_str, "simple_binary")) break :blk SearchStrategy.simple_binary;
            }
            break :blk SearchStrategy.adaptive;
        } else SearchStrategy.adaptive;

        // Parse confidence
        const confidence = if (json_obj.get("confidence")) |conf_val| blk: {
            switch (conf_val) {
                .float => break :blk @as(f32, @floatCast(conf_val.float)),
                .integer => break :blk @as(f32, @floatFromInt(conf_val.integer)),
                else => break :blk 0.5,
            }
        } else 0.5;

        // Parse reasoning
        const reasoning = if (json_obj.get("reasoning")) |reason_val|
            if (reason_val == .string) try self.allocator.dupe(u8, reason_val.string) else try self.allocator.dupe(u8, "No reasoning provided")
        else
            try self.allocator.dupe(u8, "No reasoning provided");

        // Parse next queries
        var next_queries = std.ArrayList([]const u8).init(self.allocator);
        if (json_obj.get("next_queries")) |queries_val| {
            if (queries_val == .array) {
                for (queries_val.array.items) |query_val| {
                    if (query_val == .string) {
                        const query = try self.allocator.dupe(u8, query_val.string);
                        try next_queries.append(query);
                    }
                }
            }
        }

        return SearchDecision{
            .action = action,
            .strategy = strategy,
            .confidence = confidence,
            .reasoning = reasoning,
            .next_queries = try next_queries.toOwnedSlice(),
        };
    }

    /// Execute a search decision
    fn executeSearchDecision(self: *Self, decision: SearchDecision, search_interface: anytype) !bool {
        switch (decision.action) {
            .continue_path => {
                if (decision.next_queries.len > 0) {
                    for (decision.next_queries) |query| {
                        const new_node = try self.createChildNode(query);
                        try self.executeSearchAtNode(new_node, search_interface);
                        self.current_node = new_node;
                    }
                }
                return true;
            },

            .explore_alternative => {
                if (decision.next_queries.len > 0) {
                    // Create alternative search paths
                    for (decision.next_queries) |query| {
                        const new_node = try self.createSiblingNode(query);
                        try self.executeSearchAtNode(new_node, search_interface);
                    }
                    // Move to most promising alternative
                    self.current_node = try self.findMostPromisingNode();
                }
                return true;
            },

            .backtrack => {
                if (self.current_node) |node| {
                    if (node.parent) |parent| {
                        self.current_node = parent;
                        self.backtrack_count += 1;
                        std.log.info("⬅️ Backtracked to: {s}", .{parent.query});
                    }
                }
                return true;
            },

            .terminate_success => {
                std.log.info("✅ Search terminated successfully by LLM", .{});
                self.successful_paths += 1;
                return false;
            },

            .terminate_failure => {
                std.log.info("❌ Search terminated (insufficient results)", .{});
                return false;
            },

            .split_search => {
                // Create multiple parallel search branches
                for (decision.next_queries) |query| {
                    const new_node = try self.createChildNode(query);
                    try self.executeSearchAtNode(new_node, search_interface);
                }
                return true;
            },

            .merge_results => {
                // Merge results from different branches (handled in final collection)
                return false;
            },

            // Paper-inspired simple actions
            .simple_continue => {
                // Simple continue: evaluate current actions and continue with best
                if (decision.next_queries.len > 0) {
                    const query = decision.next_queries[0];
                    const new_node = try self.createChildNode(query);
                    try self.executeSearchAtNode(new_node, search_interface);
                    self.current_node = new_node;

                    // Add remaining queries to priority queue
                    for (decision.next_queries[1..]) |alt_query| {
                        const entry = try QueueEntry.init(self.allocator, 0.5, alt_query, new_node.depth);
                        try self.priority_queue.add(entry);
                    }
                }
                return true;
            },

            .simple_explore => {
                // Simple explore: pop from priority queue and execute
                if (self.priority_queue.removeOrNull()) |entry| {
                    var mutable_entry = entry;
                    defer mutable_entry.deinit();
                    const new_node = try self.createChildNode(entry.query);
                    try self.executeSearchAtNode(new_node, search_interface);
                    self.current_node = new_node;
                }
                return true;
            },
        }
    }

    /// Evaluate a search node using LLM
    fn evaluateNodeWithLLM(self: *Self, node: *SearchNode) !void {
        if (node.results.len == 0) {
            node.relevance_score = 0.0;
            node.information_value = 0.0;
            node.exploration_potential = 0.1;
            node.confidence = 0.0;
            return;
        }

        // Build evaluation prompt
        var results_summary = std.ArrayList(u8).init(self.allocator);
        defer results_summary.deinit();

        const writer = results_summary.writer();
        try writer.print("Query: {s}\nResults:\n", .{node.query});

        const sample_count = @min(node.results.len, 5);
        for (node.results[0..sample_count]) |result| {
            try writer.print("- {s} (score: {d:.2})\n", .{ result.title, result.relevance_score });
        }

        const evaluation_prompt = try std.fmt.allocPrint(self.allocator,
            \\Evaluate these search results on a scale of 0.0 to 1.0:
            \\
            \\{s}
            \\
            \\Provide scores for:
            \\- relevance_score: How relevant are results to the query?
            \\- information_value: How much new information do they provide?
            \\- exploration_potential: How likely are they to lead to better results?
            \\- confidence: How confident are you in the quality?
            \\
            \\Respond in JSON format:
            \\{{"relevance_score": 0.0, "information_value": 0.0, "exploration_potential": 0.0, "confidence": 0.0}}
        , .{results_summary.items});
        defer self.allocator.free(evaluation_prompt);

        const llm_response = try self.claude_client.executeClaude(evaluation_prompt);
        defer self.allocator.free(llm_response);

        // Track token usage for evaluation
        self.token_usage += @as(u32, @intCast(llm_response.len / 4));

        // Parse evaluation scores (simplified)
        node.relevance_score = self.extractScoreFromResponse(llm_response, "relevance_score") orelse 0.5;
        node.information_value = self.extractScoreFromResponse(llm_response, "information_value") orelse 0.5;
        node.exploration_potential = self.extractScoreFromResponse(llm_response, "exploration_potential") orelse 0.5;
        node.confidence = self.extractScoreFromResponse(llm_response, "confidence") orelse 0.5;

        std.log.info("📊 Node evaluation - Relevance: {d:.2}, Info: {d:.2}, Potential: {d:.2}", .{ node.relevance_score, node.information_value, node.exploration_potential });
    }

    /// Extract score from LLM response
    fn extractScoreFromResponse(self: *Self, response: []const u8, score_name: []const u8) ?f32 {
        _ = self;

        const pattern = std.fmt.allocPrint(std.heap.page_allocator, "\"{s}\":", .{score_name}) catch return null;
        defer std.heap.page_allocator.free(pattern);

        if (std.mem.indexOf(u8, response, pattern)) |start| {
            const value_start = start + pattern.len;
            var i = value_start;

            // Skip whitespace
            while (i < response.len and (response[i] == ' ' or response[i] == '\t')) i += 1;

            // Find end of number
            const num_start = i;
            while (i < response.len and (std.ascii.isDigit(response[i]) or response[i] == '.')) i += 1;

            if (i > num_start) {
                const num_str = response[num_start..i];
                return std.fmt.parseFloat(f32, num_str) catch null;
            }
        }

        return null;
    }

    /// Helper methods for node management
    fn getNextNodeId(self: *Self) u64 {
        const id = self.node_counter;
        self.node_counter += 1;
        return id;
    }

    fn createChildNode(self: *Self, query: []const u8) !*SearchNode {
        const node = try self.allocator.create(SearchNode);
        node.* = try SearchNode.init(self.allocator, self.getNextNodeId(), query, self.current_node);

        if (self.current_node) |parent| {
            try parent.addChild(node);
        }

        try self.search_tree.append(node);
        return node;
    }

    fn createSiblingNode(self: *Self, query: []const u8) !*SearchNode {
        const parent = if (self.current_node) |node| node.parent else null;

        const node = try self.allocator.create(SearchNode);
        node.* = try SearchNode.init(self.allocator, self.getNextNodeId(), query, parent);

        if (parent) |p| {
            try p.addChild(node);
        }

        try self.search_tree.append(node);
        return node;
    }

    fn findMostPromisingNode(self: *Self) !*SearchNode {
        var best_node = self.search_tree.items[0];
        var best_score: f32 = 0.0;

        for (self.search_tree.items) |node| {
            const combined_score = (node.relevance_score + node.information_value + node.exploration_potential) / 3.0;
            if (combined_score > best_score) {
                best_score = combined_score;
                best_node = node;
            }
        }

        return best_node;
    }

    /// Collect results without expensive LLM ranking
    fn collectResultsSimple(self: *Self) ![]types.NewsItem {
        var all_results = std.ArrayList(types.NewsItem).init(self.allocator);
        defer all_results.deinit();

        // Collect results from all nodes
        for (self.search_tree.items) |node| {
            for (node.results) |result| {
                try all_results.append(try result.clone(self.allocator));
            }
        }

        // Remove duplicates and sort by simple relevance score
        const unique_results = try self.removeDuplicates(all_results.items);
        try self.sortBySimpleScore(unique_results);

        return unique_results;
    }

    /// Collect and rank final results using LLM (original method, kept for compatibility)
    fn collectAndRankResults(self: *Self) ![]types.NewsItem {
        var all_results = std.ArrayList(types.NewsItem).init(self.allocator);
        defer all_results.deinit();

        // Collect results from all nodes
        for (self.search_tree.items) |node| {
            for (node.results) |result| {
                try all_results.append(try result.clone(self.allocator));
            }
        }

        // Remove duplicates and sort by LLM-evaluated combined score
        const unique_results = try self.removeDuplicates(all_results.items);
        try self.sortByLLMScore(unique_results);

        return unique_results;
    }

    fn removeDuplicates(self: *Self, results: []types.NewsItem) ![]types.NewsItem {
        var unique = std.ArrayList(types.NewsItem).init(self.allocator);
        defer unique.deinit();

        for (results) |result| {
            var is_duplicate = false;
            for (unique.items) |existing| {
                if (std.mem.eql(u8, result.url, existing.url)) {
                    is_duplicate = true;
                    break;
                }
            }

            if (!is_duplicate) {
                try unique.append(try result.clone(self.allocator));
            }
        }

        return try unique.toOwnedSlice();
    }

    fn sortBySimpleScore(self: *Self, results: []types.NewsItem) !void {
        _ = self;

        // Sort by relevance score (descending) - simple version without LLM
        std.sort.insertion(types.NewsItem, results, {}, struct {
            fn lessThan(_: void, a: types.NewsItem, b: types.NewsItem) bool {
                return a.relevance_score > b.relevance_score;
            }
        }.lessThan);
    }

    fn sortByLLMScore(self: *Self, results: []types.NewsItem) !void {
        _ = self;

        // Sort by relevance score (descending)
        std.sort.insertion(types.NewsItem, results, {}, struct {
            fn lessThan(_: void, a: types.NewsItem, b: types.NewsItem) bool {
                return a.relevance_score > b.relevance_score;
            }
        }.lessThan);
    }

    /// Parse simplified LLM response into SearchDecision
    fn parseSimpleDecision(self: *Self, llm_response: []const u8) !SearchDecision {
        // Simple parsing - look for action keywords
        const action = if (std.mem.indexOf(u8, llm_response, "terminate_success") != null)
            SearchAction.terminate_success
        else if (std.mem.indexOf(u8, llm_response, "simple_explore") != null)
            SearchAction.simple_explore
        else if (std.mem.indexOf(u8, llm_response, "terminate_failure") != null)
            SearchAction.terminate_failure
        else
            SearchAction.terminate_success; // Default to terminating

        return SearchDecision{
            .action = action,
            .strategy = .simple_binary,
            .confidence = 0.8,
            .reasoning = try self.allocator.dupe(u8, "Simplified decision"),
            .next_queries = &[_][]const u8{},
        };
    }

    /// Execute simplified search decision
    fn executeSimplifiedDecision(self: *Self, decision: SearchDecision, search_interface: anytype) !bool {
        switch (decision.action) {
            .terminate_success => {
                std.log.info("✅ Search terminated successfully (simplified)", .{});
                return false;
            },
            .terminate_failure => {
                std.log.info("❌ Search terminated (insufficient results)", .{});
                return false;
            },
            .simple_explore => {
                // Try one more basic search if we have no results
                if (self.current_node) |node| {
                    if (node.results.len == 0) {
                        const fallback_query = "AI news today";
                        const new_node = try self.createChildNode(fallback_query);
                        try self.executeSearchAtNode(new_node, search_interface);
                        self.current_node = new_node;
                    }
                }
                return false; // Don't continue after exploration
            },
            else => {
                return false; // Terminate for any other action
            },
        }
    }
};

/// Create LLM-First Search Engine
pub fn createLLMFirstSearchEngine(allocator: std.mem.Allocator, claude_client: *claude.ClaudeClient) LLMFirstSearchEngine {
    return LLMFirstSearchEngine.init(allocator, claude_client);
}

// Test function
test "LLM-First Search initialization" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var claude_client = claude.ClaudeClient.init(allocator, "sonnet");

    var search_engine = createLLMFirstSearchEngine(allocator, &claude_client);
    defer search_engine.deinit();

    try std.testing.expect(search_engine.search_tree.items.len == 0);
    try std.testing.expect(search_engine.total_queries == 0);
}
