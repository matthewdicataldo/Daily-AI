const std = @import("std");
const types = @import("core_types.zig");

/// Enhanced JSON cache implementation with proper serialization/deserialization
pub const JsonCache = struct {
    allocator: std.mem.Allocator,
    cache_dir: []const u8,
    
    pub fn init(allocator: std.mem.Allocator, cache_dir: []const u8) JsonCache {
        return JsonCache{
            .allocator = allocator,
            .cache_dir = cache_dir,
        };
    }
    
    pub fn deinit(self: *JsonCache) void {
        _ = self;
        // Nothing to clean up for now
    }
    
    /// Store NewsItems array in cache with proper JSON serialization
    pub fn storeNewsItems(self: *JsonCache, key: []const u8, items: []const types.NewsItem) !void {
        // Ensure cache directory exists
        try self.ensureCacheDir();
        
        // Create full cache file path
        const cache_file = try std.fmt.allocPrint(self.allocator, "{s}/{s}.json", .{ self.cache_dir, key });
        defer self.allocator.free(cache_file);
        
        // Serialize to JSON
        const json_data = try self.serializeNewsItems(items);
        defer self.allocator.free(json_data);
        
        // Write to file
        const file = try std.fs.cwd().createFile(cache_file, .{});
        defer file.close();
        
        try file.writeAll(json_data);
        std.log.debug("Cached {d} items to {s}", .{ items.len, cache_file });
    }
    
    /// Retrieve NewsItems array from cache with proper JSON deserialization
    pub fn getNewsItems(self: *JsonCache, key: []const u8) !?[]types.NewsItem {
        const cache_file = try std.fmt.allocPrint(self.allocator, "{s}/{s}.json", .{ self.cache_dir, key });
        defer self.allocator.free(cache_file);
        
        // Try to read cache file
        const json_data = std.fs.cwd().readFileAlloc(self.allocator, cache_file, 100 * 1024 * 1024) catch |err| {
            switch (err) {
                error.FileNotFound => {
                    std.log.debug("Cache miss for key: {s}", .{key});
                    return null;
                },
                else => return err,
            }
        };
        defer self.allocator.free(json_data);
        
        std.log.debug("Cache hit for key: {s}, size: {d} bytes", .{ key, json_data.len });
        return try self.deserializeNewsItems(json_data);
    }
    
    /// Check if cache entry exists and is still valid
    pub fn isValid(self: *JsonCache, key: []const u8, max_age_seconds: i64) !bool {
        const cache_file = try std.fmt.allocPrint(self.allocator, "{s}/{s}.json", .{ self.cache_dir, key });
        defer self.allocator.free(cache_file);
        
        const file_stat = std.fs.cwd().statFile(cache_file) catch |err| {
            switch (err) {
                error.FileNotFound => return false,
                else => return err,
            }
        };
        
        const file_age = types.getCurrentTimestamp() - @as(i64, @intCast(file_stat.mtime / 1_000_000_000));
        return file_age <= max_age_seconds;
    }
    
    /// Clear cache entry
    pub fn invalidate(self: *JsonCache, key: []const u8) !void {
        const cache_file = try std.fmt.allocPrint(self.allocator, "{s}/{s}.json", .{ self.cache_dir, key });
        defer self.allocator.free(cache_file);
        
        std.fs.cwd().deleteFile(cache_file) catch |err| {
            switch (err) {
                error.FileNotFound => {}, // Already doesn't exist
                else => return err,
            }
        };
        
        std.log.debug("Invalidated cache for key: {s}", .{key});
    }
    
    /// Serialize NewsItems to JSON format
    fn serializeNewsItems(self: *JsonCache, items: []const types.NewsItem) ![]const u8 {
        var buffer = std.ArrayList(u8).init(self.allocator);
        defer buffer.deinit();
        
        try buffer.append('[');
        
        for (items, 0..) |item, i| {
            if (i > 0) {
                try buffer.appendSlice(",\n");
            }
            
            try buffer.appendSlice("{\n");
            
            // Serialize basic fields
            try buffer.appendSlice("  \"title\": ");
            try self.writeJsonString(&buffer, item.title);
            try buffer.appendSlice(",\n");
            
            try buffer.appendSlice("  \"summary\": ");
            try self.writeJsonString(&buffer, item.summary);
            try buffer.appendSlice(",\n");
            
            try buffer.appendSlice("  \"url\": ");
            try self.writeJsonString(&buffer, item.url);
            try buffer.appendSlice(",\n");
            
            try buffer.appendSlice("  \"source\": ");
            try self.writeJsonString(&buffer, item.source);
            try buffer.appendSlice(",\n");
            
            // Serialize source_type as string
            try buffer.appendSlice("  \"source_type\": ");
            const source_type_str = switch (item.source_type) {
                .reddit => "reddit",
                .youtube => "youtube", 
                .tiktok => "tiktok",
                .research_hub => "research_hub",
                .blog => "blog",
                .web_crawl => "web_crawl",
                .github_repo => "github_repo",
            };
            try self.writeJsonString(&buffer, source_type_str);
            try buffer.appendSlice(",\n");
            
            // Serialize numeric fields
            try buffer.writer().print("  \"timestamp\": {d},\n", .{item.timestamp});
            try buffer.writer().print("  \"relevance_score\": {d}", .{item.relevance_score});
            
            // Serialize metadata if present
            if (item.reddit_metadata) |reddit| {
                try buffer.appendSlice(",\n  \"reddit_metadata\": ");
                try self.serializeRedditMetadata(&buffer, reddit);
            }
            
            if (item.youtube_metadata) |youtube| {
                try buffer.appendSlice(",\n  \"youtube_metadata\": ");
                try self.serializeYouTubeMetadata(&buffer, youtube);
            }
            
            if (item.huggingface_metadata) |hf| {
                try buffer.appendSlice(",\n  \"huggingface_metadata\": ");
                try self.serializeHuggingFaceMetadata(&buffer, hf);
            }
            
            // Add more metadata serialization as needed
            
            try buffer.appendSlice("\n}");
        }
        
        try buffer.append(']');
        return try buffer.toOwnedSlice();
    }
    
    /// Deserialize NewsItems from JSON format
    fn deserializeNewsItems(self: *JsonCache, json_data: []const u8) ![]types.NewsItem {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const temp_allocator = arena.allocator();
        
        const parsed = std.json.parseFromSlice(std.json.Value, temp_allocator, json_data, .{}) catch |err| {
            std.log.err("Failed to parse cached JSON: {}", .{err});
            return error.InvalidCacheEntry;
        };
        
        if (parsed.value != .array) {
            std.log.err("Expected JSON array in cache file");
            return error.InvalidCacheEntry;
        }
        
        const array = parsed.value.array;
        var items = try self.allocator.alloc(types.NewsItem, array.items.len);
        errdefer {
            // Clean up on error
            for (items[0..]) |item| {
                item.deinit(self.allocator);
            }
            self.allocator.free(items);
        }
        
        for (array.items, 0..) |item_val, i| {
            if (item_val != .object) {
                return error.InvalidCacheEntry;
            }
            
            items[i] = try self.deserializeNewsItem(item_val.object);
        }
        
        std.log.debug("Deserialized {d} NewsItems from cache", .{items.len});
        return items;
    }
    
    /// Deserialize a single NewsItem from JSON object
    fn deserializeNewsItem(self: *JsonCache, obj: std.json.ObjectMap) !types.NewsItem {
        // Extract required fields
        const title = try self.getJsonString(obj, "title");
        const summary = try self.getJsonString(obj, "summary");
        const url = try self.getJsonString(obj, "url");
        const source = try self.getJsonString(obj, "source");
        
        // Extract source_type
        const source_type_str = try self.getJsonString(obj, "source_type");
        defer self.allocator.free(source_type_str);
        
        const source_type = std.meta.stringToEnum(types.SourceType, source_type_str) orelse .web_crawl;
        
        // Extract numeric fields
        const timestamp = if (obj.get("timestamp")) |val|
            if (val == .integer) val.integer else types.getCurrentTimestamp()
        else
            types.getCurrentTimestamp();
            
        const relevance_score = if (obj.get("relevance_score")) |val| blk: {
            switch (val) {
                .float => break :blk @as(f32, @floatCast(val.float)),
                .integer => break :blk @as(f32, @floatFromInt(val.integer)),
                else => break :blk 0.5,
            }
        } else 0.5;
        
        // Deserialize metadata (simplified for now)
        const reddit_metadata = if (obj.get("reddit_metadata")) |meta_val|
            if (meta_val == .object) try self.deserializeRedditMetadata(meta_val.object) else null
        else
            null;
            
        const youtube_metadata = if (obj.get("youtube_metadata")) |meta_val|
            if (meta_val == .object) try self.deserializeYouTubeMetadata(meta_val.object) else null
        else
            null;
            
        const huggingface_metadata = if (obj.get("huggingface_metadata")) |meta_val|
            if (meta_val == .object) try self.deserializeHuggingFaceMetadata(meta_val.object) else null
        else
            null;
        
        return types.NewsItem{
            .title = title,
            .summary = summary,
            .url = url,
            .source = source,
            .source_type = source_type,
            .timestamp = timestamp,
            .relevance_score = relevance_score,
            .reddit_metadata = reddit_metadata,
            .youtube_metadata = youtube_metadata,
            .huggingface_metadata = huggingface_metadata,
            .blog_metadata = null,
            .github_metadata = null,
        };
    }
    
    /// Write a string as JSON with proper escaping
    fn writeJsonString(self: *JsonCache, buffer: *std.ArrayList(u8), str: []const u8) !void {
        _ = self;
        try buffer.append('"');
        
        for (str) |c| {
            switch (c) {
                '"' => try buffer.appendSlice("\\\""),
                '\\' => try buffer.appendSlice("\\\\"),
                '\n' => try buffer.appendSlice("\\n"),
                '\r' => try buffer.appendSlice("\\r"),
                '\t' => try buffer.appendSlice("\\t"),
                else => try buffer.append(c),
            }
        }
        
        try buffer.append('"');
    }
    
    /// Get string value from JSON object
    fn getJsonString(self: *JsonCache, obj: std.json.ObjectMap, key: []const u8) ![]const u8 {
        if (obj.get(key)) |val| {
            if (val == .string) {
                return try self.allocator.dupe(u8, val.string);
            }
        }
        return error.MissingField;
    }
    
    /// Serialize Reddit metadata to JSON
    fn serializeRedditMetadata(self: *JsonCache, buffer: *std.ArrayList(u8), metadata: types.RedditMetadata) !void {
        try buffer.appendSlice("{\n");
        try buffer.appendSlice("    \"post_id\": ");
        try self.writeJsonString(buffer, metadata.post_id);
        try buffer.appendSlice(",\n    \"author\": ");
        try self.writeJsonString(buffer, metadata.author);
        try buffer.appendSlice(",\n    \"subreddit\": ");
        try self.writeJsonString(buffer, metadata.subreddit);
        try buffer.writer().print(",\n    \"score\": {d}", .{metadata.score});
        try buffer.writer().print(",\n    \"comment_count\": {d}", .{metadata.comment_count});
        try buffer.writer().print(",\n    \"created_utc\": {d}", .{metadata.created_utc});
        try buffer.appendSlice("\n  }");
    }
    
    /// Serialize YouTube metadata to JSON
    fn serializeYouTubeMetadata(self: *JsonCache, buffer: *std.ArrayList(u8), metadata: types.YouTubeMetadata) !void {
        try buffer.appendSlice("{\n");
        try buffer.appendSlice("    \"video_id\": ");
        try self.writeJsonString(buffer, metadata.video_id);
        try buffer.appendSlice(",\n    \"channel_name\": ");
        try self.writeJsonString(buffer, metadata.channel_name);
        try buffer.appendSlice(",\n    \"duration\": ");
        try self.writeJsonString(buffer, metadata.duration);
        try buffer.writer().print(",\n    \"view_count\": {d}", .{metadata.view_count});
        try buffer.writer().print(",\n    \"has_transcript\": {}", .{metadata.has_transcript});
        if (metadata.transcript) |transcript| {
            try buffer.appendSlice(",\n    \"transcript\": ");
            try self.writeJsonString(buffer, transcript);
        }
        try buffer.appendSlice("\n  }");
    }
    
    /// Serialize HuggingFace metadata to JSON
    fn serializeHuggingFaceMetadata(self: *JsonCache, buffer: *std.ArrayList(u8), metadata: types.HuggingFaceMetadata) !void {
        try buffer.appendSlice("{\n");
        try buffer.appendSlice("    \"paper_id\": ");
        try self.writeJsonString(buffer, metadata.paper_id);
        try buffer.writer().print(",\n    \"likes\": {d}", .{metadata.likes});
        try buffer.writer().print(",\n    \"downloads\": {d}", .{metadata.downloads});
        
        if (metadata.authors.len > 0) {
            try buffer.appendSlice(",\n    \"authors\": [");
            for (metadata.authors, 0..) |author, i| {
                if (i > 0) try buffer.appendSlice(", ");
                try self.writeJsonString(buffer, author);
            }
            try buffer.appendSlice("]");
        }
        
        try buffer.appendSlice("\n  }");
    }
    
    /// Deserialize Reddit metadata from JSON
    fn deserializeRedditMetadata(self: *JsonCache, obj: std.json.ObjectMap) !types.RedditMetadata {
        const post_id = try self.getJsonString(obj, "post_id");
        const author = try self.getJsonString(obj, "author");
        const subreddit = try self.getJsonString(obj, "subreddit");
        
        const score = if (obj.get("score")) |val|
            if (val == .integer) @as(i32, @intCast(val.integer)) else 0
        else 0;
        
        const comment_count = if (obj.get("comment_count")) |val|
            if (val == .integer) @as(u32, @intCast(val.integer)) else 0
        else 0;
        
        const created_utc = if (obj.get("created_utc")) |val|
            if (val == .integer) val.integer else types.getCurrentTimestamp()
        else types.getCurrentTimestamp();
        
        return types.RedditMetadata{
            .post_id = post_id,
            .author = author,
            .subreddit = subreddit,
            .upvotes = score,
            .comment_count = comment_count,
            .created_utc = @floatFromInt(created_utc),
            .upvote_ratio = 0.5, // Default value
            .flair = null,
            .is_self_post = false,
            .permalink = try self.allocator.dupe(u8, ""),
            .selftext = null,
            .top_comments = null,
        };
    }
    
    /// Deserialize YouTube metadata from JSON
    fn deserializeYouTubeMetadata(self: *JsonCache, obj: std.json.ObjectMap) !types.YouTubeMetadata {
        const video_id = try self.getJsonString(obj, "video_id");
        const channel_name = try self.getJsonString(obj, "channel_name");
        const duration = try self.getJsonString(obj, "duration");
        
        const view_count = if (obj.get("view_count")) |val|
            if (val == .integer) @as(u64, @intCast(val.integer)) else 0
        else 0;
        
        const has_transcript = if (obj.get("has_transcript")) |val|
            if (val == .bool) val.bool else false
        else false;
        
        const transcript = if (obj.get("transcript")) |val|
            if (val == .string) try self.allocator.dupe(u8, val.string) else null
        else null;
        
        return types.YouTubeMetadata{
            .video_id = video_id,
            .channel_name = channel_name,
            .duration = duration,
            .view_count = view_count,
            .like_count = 0,
            .comment_count = 0,
            .upload_date = try self.allocator.dupe(u8, ""),
            .has_transcript = has_transcript,
            .transcript = transcript,
            .top_comments = null,
        };
    }
    
    /// Deserialize HuggingFace metadata from JSON
    fn deserializeHuggingFaceMetadata(self: *JsonCache, obj: std.json.ObjectMap) !types.HuggingFaceMetadata {
        const paper_id = try self.getJsonString(obj, "paper_id");
        
        const likes = if (obj.get("likes")) |val|
            if (val == .integer) @as(u32, @intCast(val.integer)) else 0
        else 0;
        
        const downloads = if (obj.get("downloads")) |val|
            if (val == .integer) @as(u64, @intCast(val.integer)) else 0
        else 0;
        
        // Parse authors array
        var authors = std.ArrayList([]const u8).init(self.allocator);
        defer authors.deinit();
        
        if (obj.get("authors")) |authors_val| {
            if (authors_val == .array) {
                for (authors_val.array.items) |author_val| {
                    if (author_val == .string) {
                        try authors.append(try self.allocator.dupe(u8, author_val.string));
                    }
                }
            }
        }
        
        return types.HuggingFaceMetadata{
            .paper_id = paper_id,
            .likes = likes,
            .downloads = downloads,
            .authors = try authors.toOwnedSlice(),
            .abstract = null,
            .published_date = null,
            .arxiv_id = null,
            .github_repo = null,
            .pdf_url = null,
            .tags = null,
        };
    }
    
    /// Ensure cache directory exists
    fn ensureCacheDir(self: *JsonCache) !void {
        std.fs.cwd().makeDir(self.cache_dir) catch |err| {
            switch (err) {
                error.PathAlreadyExists => {}, // Directory exists, that's fine
                else => return err,
            }
        };
    }
};