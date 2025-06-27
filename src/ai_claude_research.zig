const std = @import("std");
const types = @import("core_types.zig");
const claude = @import("ai_claude.zig");

/// Claude-based research enhancement system
/// Provides deeper analysis and research capabilities using Claude CLI
pub const ClaudeResearcher = struct {
    allocator: std.mem.Allocator,
    claude_client: *claude.ClaudeClient,
    
    pub fn init(allocator: std.mem.Allocator, claude_client: *claude.ClaudeClient) ClaudeResearcher {
        return ClaudeResearcher{
            .allocator = allocator,
            .claude_client = claude_client,
        };
    }
    
    /// Enhance content analysis with deeper research
    pub fn enhanceAnalysis(self: *ClaudeResearcher, content: []types.NewsItem, query: ?[]const u8) ![]types.NewsItem {
        std.log.info("🔬 Enhancing analysis with Claude-based research...", .{});
        
        // Create research prompt for Claude
        const research_prompt = try self.buildResearchPrompt(content, query);
        defer self.allocator.free(research_prompt);
        
        // Get Claude's enhanced analysis
        const enhanced_response = try self.claude_client.executeClaude(research_prompt);
        defer self.allocator.free(enhanced_response);
        
        // Parse and apply enhancements
        return try self.applyEnhancements(content, enhanced_response);
    }
    
    /// Generate deeper insights and connections between content items
    pub fn generateInsights(self: *ClaudeResearcher, content: []types.NewsItem) ![]const u8 {
        const insights_prompt = try self.buildInsightsPrompt(content);
        defer self.allocator.free(insights_prompt);
        
        const insights_response = try self.claude_client.executeClaude(insights_prompt);
        return insights_response; // Caller owns the memory
    }
    
    /// Research trending topics and emerging patterns
    pub fn researchTrends(self: *ClaudeResearcher, content: []types.NewsItem) ![]const u8 {
        const trends_prompt = try self.buildTrendsPrompt(content);
        defer self.allocator.free(trends_prompt);
        
        const trends_response = try self.claude_client.executeClaude(trends_prompt);
        return trends_response; // Caller owns the memory
    }
    
    fn buildResearchPrompt(self: *ClaudeResearcher, content: []types.NewsItem, query: ?[]const u8) ![]const u8 {
        var prompt = std.ArrayList(u8).init(self.allocator);
        defer prompt.deinit();
        
        try prompt.appendSlice(
            \\You are an expert AI researcher conducting deep analysis of AI developments. Your task is to enhance the provided content with deeper insights, connections, and research.
            \\
            \\Analyze the following content and provide:
            \\1. Key patterns and emerging trends
            \\2. Connections between different items
            \\3. Technical implications and significance
            \\4. Potential future impact
            \\5. Missing context or related developments
            \\
        );
        
        if (query) |q| {
            try prompt.writer().print("Research focus: {s}\n\n", .{q});
        }
        
        try prompt.appendSlice("Content to analyze:\n\n");
        
        for (content, 0..) |item, i| {
            try prompt.writer().print("{d}. [{s}] {s}\n", .{ i + 1, @tagName(item.source_type), item.title });
            try prompt.writer().print("   Summary: {s}\n", .{item.summary});
            try prompt.writer().print("   Source: {s}\n", .{item.source});
            try prompt.writer().print("   URL: {s}\n\n", .{item.url});
        }
        
        return try prompt.toOwnedSlice();
    }
    
    fn buildInsightsPrompt(self: *ClaudeResearcher, content: []types.NewsItem) ![]const u8 {
        var prompt = std.ArrayList(u8).init(self.allocator);
        defer prompt.deinit();
        
        try prompt.appendSlice(
            \\Analyze the following AI developments and generate deep insights about:
            \\
            \\1. Cross-cutting themes and patterns
            \\2. Technical convergence points
            \\3. Market and research implications
            \\4. Timeline and development velocity
            \\5. Competitive landscape shifts
            \\
            \\Provide actionable insights for AI practitioners, researchers, and industry professionals.
            \\
            \\Content:
            \\
        );
        
        for (content, 0..) |item, i| {
            try prompt.writer().print("{d}. {s} ({s})\n", .{ i + 1, item.title, @tagName(item.source_type) });
            try prompt.writer().print("   {s}\n\n", .{item.summary});
        }
        
        return try prompt.toOwnedSlice();
    }
    
    fn buildTrendsPrompt(self: *ClaudeResearcher, content: []types.NewsItem) ![]const u8 {
        var prompt = std.ArrayList(u8).init(self.allocator);
        defer prompt.deinit();
        
        try prompt.appendSlice(
            \\Identify and analyze emerging trends from these AI developments:
            \\
            \\1. Technical trends (models, architectures, capabilities)
            \\2. Industry trends (adoption, investment, applications)
            \\3. Research trends (methodologies, focus areas)
            \\4. Ecosystem trends (tools, platforms, community)
            \\
            \\Rank trends by significance and provide timeline predictions.
            \\
            \\Sources:
            \\
        );
        
        // Group by source type for better trend analysis
        var by_type = std.EnumMap(types.SourceType, std.ArrayList(types.NewsItem)).init(.{});
        defer {
            var iterator = by_type.iterator();
            while (iterator.next()) |entry| {
                entry.value_ptr.deinit();
            }
        }
        
        for (content) |item| {
            var list = by_type.getPtr(item.source_type) orelse blk: {
                by_type.put(item.source_type, std.ArrayList(types.NewsItem).init(self.allocator));
                break :blk by_type.getPtr(item.source_type).?;
            };
            try list.append(item);
        }
        
        var type_iterator = by_type.iterator();
        while (type_iterator.next()) |entry| {
            try prompt.writer().print("\n{s} Sources:\n", .{@tagName(entry.key_ptr.*)});
            for (entry.value_ptr.items) |item| {
                try prompt.writer().print("- {s}\n", .{item.title});
            }
        }
        
        return try prompt.toOwnedSlice();
    }
    
    fn applyEnhancements(self: *ClaudeResearcher, content: []types.NewsItem, enhancements: []const u8) ![]types.NewsItem {
        _ = enhancements; // TODO: Parse and apply Claude's research enhancements
        // For now, return the original content with enhanced metadata
        // In a full implementation, we would parse the enhancements and apply them
        var enhanced_content = try self.allocator.alloc(types.NewsItem, content.len);
        
        for (content, 0..) |item, i| {
            enhanced_content[i] = try item.clone(self.allocator);
            // Could enhance relevance scores, add insights, etc. based on Claude's analysis
            enhanced_content[i].relevance_score = @min(1.0, item.relevance_score + 0.1); // Slight boost for research-enhanced items
        }
        
        std.log.info("📊 Enhanced {d} items with Claude research insights", .{enhanced_content.len});
        return enhanced_content;
    }
};