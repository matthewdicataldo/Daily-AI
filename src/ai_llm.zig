//! Unified LLM interface with automatic caching
//! Clean DX for all Claude API calls

const std = @import("std");
const simple_cache = @import("cache_simple.zig");
const claude = @import("ai_claude.zig");

/// Unified LLM client with caching
pub const LLMClient = struct {
    allocator: std.mem.Allocator,
    claude_client: claude.ClaudeClient,
    cache: *simple_cache.SimpleCache,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, claude_model: []const u8, cache: *simple_cache.SimpleCache) Self {
        return Self{
            .allocator = allocator,
            .claude_client = claude.ClaudeClient.init(allocator, claude_model),
            .cache = cache,
        };
    }
    
    pub fn deinit(self: *Self) void {
        // Claude client doesn't have deinit method
        _ = self;
    }
    
    /// Execute Claude prompt with automatic caching (1 hour TTL)
    pub fn prompt(self: *Self, prompt_text: []const u8) ![]const u8 {
        // Check cache first
        if (self.cache.getLlmResponse(prompt_text)) |cached_response| {
            std.log.info("💨 LLM cache hit for prompt", .{});
            return cached_response;
        }
        
        // Cache miss - call Claude API
        std.log.info("🤖 Calling Claude API (cache miss)", .{});
        const response = try self.claude_client.executeClaude(prompt_text);
        
        // Cache the response
        self.cache.cacheLlmResponse(prompt_text, response);
        
        return response;
    }
    
    /// Generate search queries from content
    pub fn generateSearchQueries(self: *Self, content_items: []const u8) ![][]const u8 {
        const search_prompt = try std.fmt.allocPrint(self.allocator,
            \\Generate 3 specific search terms for today's AI content based on these topics:
            \\
            \\{s}
            \\
            \\Return only the search terms, one per line:
        , .{content_items});
        defer self.allocator.free(search_prompt);
        
        const response = try self.prompt(search_prompt);
        defer self.allocator.free(response);
        
        // Parse response into search queries
        var queries = std.ArrayList([]const u8).init(self.allocator);
        var lines = std.mem.splitScalar(u8, response, '\n');
        
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r\n");
            if (trimmed.len >= 5 and trimmed.len <= 50) {
                try queries.append(try self.allocator.dupe(u8, trimmed));
                if (queries.items.len >= 3) break;
            }
        }
        
        return try queries.toOwnedSlice();
    }
    
    /// Analyze content for blog generation
    pub fn analyzeContent(self: *Self, content: anytype) ![]const u8 {
        // Create analysis prompt
        const analysis_prompt = try std.fmt.allocPrint(self.allocator,
            \\Analyze this AI news content and create a natural, engaging blog post in the style of Vox or NPR.
            \\
            \\Focus on:
            \\- Lead with the most newsworthy story
            \\- Use conversational, accessible language
            \\- Explain technical concepts clearly
            \\- Include context and implications
            \\- Group related stories together
            \\
            \\Content to analyze:
            \\{s}
            \\
            \\Write a complete blog post in markdown format:
        , .{content});
        defer self.allocator.free(analysis_prompt);
        
        return try self.prompt(analysis_prompt);
    }
    
    /// Generate blog title from content
    pub fn generateTitle(self: *Self, content: []const u8) ![]const u8 {
        const title_prompt = try std.fmt.allocPrint(self.allocator,
            \\Generate a compelling, news-style headline for this AI content.
            \\Style: Vox/NPR - informative but engaging.
            \\
            \\Content preview: {s}
            \\
            \\Return only the headline:
        , .{content[0..@min(500, content.len)]});
        defer self.allocator.free(title_prompt);
        
        const response = try self.prompt(title_prompt);
        const trimmed = std.mem.trim(u8, response, " \t\r\n\"");
        return try self.allocator.dupe(u8, trimmed);
    }
    
    /// Summarize content quickly
    pub fn summarize(self: *Self, content: []const u8, max_length: usize) ![]const u8 {
        const summary_prompt = try std.fmt.allocPrint(self.allocator,
            \\Summarize this content in {d} words or less:
            \\
            \\{s}
        , .{ max_length, content });
        defer self.allocator.free(summary_prompt);
        
        return try self.prompt(summary_prompt);
    }
};

/// Global LLM client - simple singleton
var global_llm: ?LLMClient = null;

pub fn getGlobalLLM(allocator: std.mem.Allocator, claude_model: []const u8) *LLMClient {
    if (global_llm == null) {
        const cache = simple_cache.getGlobalCache(allocator);
        global_llm = LLMClient.init(allocator, claude_model, cache);
    }
    return &global_llm.?;
}

pub fn deinitGlobalLLM() void {
    if (global_llm) |*llm| {
        llm.deinit();
        global_llm = null;
    }
}