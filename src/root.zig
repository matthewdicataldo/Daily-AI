//! By convention, root.zig is the root source file when making a library. If
//! you are making an executable, the convention is to delete this file and
//! start with main.zig instead.
const std = @import("std");
const testing = std.testing;

// Re-export modules for library users with logical organization

// Core modules
pub const config = @import("core_config.zig");
pub const types = @import("core_types.zig");
pub const utils = @import("core_utils.zig");

// Common utilities
pub const http = @import("common_http.zig");
pub const dotenv = @import("common_dotenv.zig");

// External integrations
pub const firecrawl = @import("external_firecrawl.zig");
pub const gitingest = @import("external_gitingest.zig");
pub const mcp_client = @import("external_mcp_client.zig");

// Content extractors
pub const reddit = @import("extract_reddit.zig");
pub const reddit_api = @import("extract_reddit_api.zig");
pub const youtube = @import("extract_youtube.zig");
pub const youtube_transcript = @import("extract_youtube_transcript.zig");
pub const huggingface = @import("extract_huggingface.zig");
pub const blog = @import("extract_blog.zig");
pub const hackernews = @import("extract_hackernews.zig");
pub const tiktok = @import("extract_tiktok.zig");
pub const tiktok_transcript = @import("extract_tiktok_transcript.zig");
pub const rss = @import("extract_rss.zig");
pub const web_crawler = @import("extract_web_crawler.zig");
pub const content_source = @import("extract_content_source.zig");

// AI processing modules
pub const processor = @import("ai_processor.zig");
pub const claude = @import("ai_claude.zig");
pub const claude_research = @import("ai_claude_research.zig");
pub const llm = @import("ai_llm.zig");
pub const llm_first_search = @import("ai_llm_first_search.zig");
pub const deep_research = @import("ai_deep_research.zig");
pub const simple_research = @import("ai_simple_research.zig");
pub const json_processor = @import("ai_json_processor.zig");
pub const model_downloader = @import("ai_model_downloader.zig");

// Output generation
pub const generator = @import("output_generator.zig");

// CLI and progress
pub const cli = @import("cli_args.zig");
pub const progress = @import("cli_progress.zig");
pub const progress_stream = @import("cli_progress_stream.zig");

// Caching systems
pub const cache = @import("cache_main.zig");
pub const simple_cache = @import("cache_simple.zig");
pub const json_cache = @import("cache_json.zig");
pub const memory_pools = @import("cache_memory_pools.zig");
pub const hot_cold_storage = @import("cache_hot_cold.zig");
pub const skytable_client = @import("cache_skytable_client.zig");
pub const skytable_hot_cold_adapter = @import("cache_skytable_adapter.zig");
pub const unified_skytable_system = @import("cache_unified_skytable.zig");

// New consolidated abstractions
pub const ai_relevance_filter = @import("ai_relevance_filter.zig");
pub const cache_unified = @import("cache_unified.zig");
pub const extract_base = @import("extract_base.zig");

// Integration demos (keep in src root for now)
pub const integration = @import("integration.zig");

// Library version
pub const version = "0.1.0";

/// Library initialization function
pub fn init() !void {
    std.log.info("Daily AI News Generator Library v{s} initialized", .{version});
}

pub export fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "basic add functionality" {
    try testing.expect(add(3, 7) == 10);
}

test "library modules" {
    // Test that all modules can be imported successfully
    // Core modules
    _ = config;
    _ = types;
    _ = utils;
    
    // Common utilities
    _ = http;
    _ = dotenv;
    
    // External integrations
    _ = firecrawl;
    _ = gitingest;
    _ = mcp_client;
    
    // Content extractors
    _ = reddit;
    _ = reddit_api;
    _ = youtube;
    _ = youtube_transcript;
    _ = huggingface;
    _ = blog;
    _ = hackernews;
    _ = tiktok;
    _ = tiktok_transcript;
    _ = rss;
    _ = web_crawler;
    _ = content_source;
    
    // AI processing modules
    _ = processor;
    _ = claude;
    _ = claude_research;
    _ = llm;
    _ = llm_first_search;
    _ = deep_research;
    _ = simple_research;
    _ = json_processor;
    _ = model_downloader;
    
    // Output generation
    _ = generator;
    
    // CLI and progress
    _ = cli;
    _ = progress;
    _ = progress_stream;
    
    // Caching systems
    _ = cache;
    _ = simple_cache;
    _ = json_cache;
    _ = memory_pools;
    _ = hot_cold_storage;
    _ = skytable_client;
    _ = skytable_hot_cold_adapter;
    _ = unified_skytable_system;
    
    // New consolidated abstractions
    _ = ai_relevance_filter;
    _ = cache_unified;
    _ = extract_base;
    
    // Integration demos
    _ = integration;
}