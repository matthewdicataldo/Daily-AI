const std = @import("std");
const types = @import("core_types.zig");
const config = @import("core_config.zig");

pub const TikTokClient = struct {
    allocator: std.mem.Allocator,
    yt_dlp_path: []const u8,
    
    pub fn init(allocator: std.mem.Allocator) TikTokClient {
        return TikTokClient{
            .allocator = allocator,
            .yt_dlp_path = "./yt-dlp", // Reuse from build.zig
        };
    }
    
    /// Extract latest videos from a TikTok user using yt-dlp
    pub fn extractUserVideos(self: *TikTokClient, source: config.TikTokSource) ![]types.NewsItem {
        const user_url = try std.fmt.allocPrint(self.allocator, "https://www.tiktok.com/@{s}", .{source.handle});
        defer self.allocator.free(user_url);
        
        std.log.info("🎵 Extracting TikTok videos from @{s} using yt-dlp...", .{source.handle});
        
        // Use yt-dlp to get TikTok video metadata as JSON
        var yt_dlp_args = std.ArrayList([]const u8).init(self.allocator);
        defer yt_dlp_args.deinit();
        
        const max_videos_str = try std.fmt.allocPrint(self.allocator, "{d}", .{source.max_videos});
        defer self.allocator.free(max_videos_str);
        
        try yt_dlp_args.append(self.yt_dlp_path);
        try yt_dlp_args.append("--dump-json");
        try yt_dlp_args.append("--playlist-end");
        try yt_dlp_args.append(max_videos_str);
        try yt_dlp_args.append("--no-warnings");
        try yt_dlp_args.append("--write-auto-sub");
        try yt_dlp_args.append("--sub-format");
        try yt_dlp_args.append("vtt");
        try yt_dlp_args.append("--write-comments");
        try yt_dlp_args.append("--skip-download");
        try yt_dlp_args.append("--extractor-args");
        try yt_dlp_args.append("tiktok:webpage_download_timeout=30");
        try yt_dlp_args.append(user_url);
        
        // Execute yt-dlp command
        var child = std.process.Child.init(yt_dlp_args.items, self.allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        
        try child.spawn();
        
        const stdout = try child.stdout.?.readToEndAlloc(self.allocator, 10 * 1024 * 1024); // 10MB limit
        defer self.allocator.free(stdout);
        
        const stderr = try child.stderr.?.readToEndAlloc(self.allocator, 1024 * 1024); // 1MB limit
        defer self.allocator.free(stderr);
        
        const exit_code = try child.wait();
        
        if (exit_code != .Exited or exit_code.Exited != 0) {
            std.log.err("yt-dlp failed with exit code: {}", .{exit_code});
            std.log.err("stderr: {s}", .{stderr});
            return types.AppError.NetworkError;
        }
        
        // Parse JSON output from yt-dlp
        return try self.parseYtDlpOutput(stdout, source);
    }
    
    /// Parse yt-dlp JSON output to extract TikTok video information
    fn parseYtDlpOutput(self: *TikTokClient, json_output: []const u8, source: config.TikTokSource) ![]types.NewsItem {
        var videos = std.ArrayList(types.NewsItem).init(self.allocator);
        try videos.ensureTotalCapacity(source.max_videos);
        
        // Create arena for temporary JSON parsing
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const temp_allocator = arena.allocator();
        
        // Parse each line as separate JSON (yt-dlp outputs one JSON per line)
        var lines = std.mem.splitScalar(u8, json_output, '\n');
        var video_count: u32 = 0;
        
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;
            
            // Parse JSON for this video
            const video_json = std.json.parseFromSlice(std.json.Value, temp_allocator, trimmed, .{}) catch |err| {
                std.log.warn("Failed to parse yt-dlp JSON line: {}", .{err});
                continue;
            };
            defer video_json.deinit();
            
            const video_data = video_json.value;
            if (video_data != .object) continue;
            
            // Extract video information from JSON
            const news_item = self.createNewsItemFromJson(video_data.object, source) catch |err| {
                std.log.warn("Failed to create news item from TikTok JSON: {}", .{err});
                continue;
            };
            
            // Apply AI relevance filtering
            if (self.isAIRelatedVideo(news_item)) {
                try videos.append(news_item);
                video_count += 1;
                
                if (video_count >= source.max_videos) {
                    break;
                }
            } else {
                news_item.deinit(self.allocator);
            }
        }
        
        std.log.info("", .{});
        std.log.info("✅ ========================================", .{});
        std.log.info("✅ Extracted {d} AI-related TikTok videos from @{s}", .{ videos.items.len, source.handle });
        std.log.info("✅ ========================================", .{});
        std.log.info("", .{});
        return try videos.toOwnedSlice();
    }
    
    /// Create NewsItem from yt-dlp TikTok JSON data
    fn createNewsItemFromJson(self: *TikTokClient, json_obj: std.json.ObjectMap, source: config.TikTokSource) !types.NewsItem {
        // Extract title/description
        const title = if (json_obj.get("title")) |title_val|
            if (title_val == .string) try self.allocator.dupe(u8, title_val.string) else try self.allocator.dupe(u8, "TikTok Video")
        else if (json_obj.get("description")) |desc_val|
            if (desc_val == .string) try self.allocator.dupe(u8, desc_val.string) else try self.allocator.dupe(u8, "TikTok Video")
        else
            try self.allocator.dupe(u8, "TikTok Video");
        
        // Extract video ID and construct URL
        const video_id = if (json_obj.get("id")) |id_val|
            if (id_val == .string) try self.allocator.dupe(u8, id_val.string) else try self.allocator.dupe(u8, "unknown")
        else if (json_obj.get("url")) |url_val|
            if (url_val == .string) try self.extractVideoIdFromUrl(url_val.string) else try self.allocator.dupe(u8, "unknown")
        else
            try self.allocator.dupe(u8, "unknown");
        
        const video_url = if (json_obj.get("webpage_url")) |url_val|
            if (url_val == .string) try self.allocator.dupe(u8, url_val.string) 
            else try std.fmt.allocPrint(self.allocator, "https://www.tiktok.com/@{s}/video/{s}", .{ source.handle, video_id })
        else
            try std.fmt.allocPrint(self.allocator, "https://www.tiktok.com/@{s}/video/{s}", .{ source.handle, video_id });
        
        // Extract TikTok-specific metadata
        const username = if (json_obj.get("uploader")) |uploader_val|
            if (uploader_val == .string) try self.allocator.dupe(u8, uploader_val.string) else try self.allocator.dupe(u8, source.handle)
        else if (json_obj.get("creator")) |creator_val|
            if (creator_val == .string) try self.allocator.dupe(u8, creator_val.string) else try self.allocator.dupe(u8, source.handle)
        else
            try self.allocator.dupe(u8, source.handle);
        
        const duration = if (json_obj.get("duration")) |dur_val| blk: {
            switch (dur_val) {
                .float => break :blk @as(u32, @intFromFloat(dur_val.float)),
                .integer => break :blk @as(u32, @intCast(dur_val.integer)),
                else => break :blk 0,
            }
        } else 0;
        
        const view_count = if (json_obj.get("view_count")) |view_val| blk: {
            switch (view_val) {
                .float => break :blk @as(u64, @intFromFloat(view_val.float)),
                .integer => break :blk @as(u64, @intCast(view_val.integer)),
                else => break :blk 0,
            }
        } else 0;
        
        const like_count = if (json_obj.get("like_count")) |like_val| blk: {
            switch (like_val) {
                .float => break :blk @as(u64, @intFromFloat(like_val.float)),
                .integer => break :blk @as(u64, @intCast(like_val.integer)),
                else => break :blk 0,
            }
        } else 0;
        
        const comment_count = if (json_obj.get("comment_count")) |comment_val| blk: {
            switch (comment_val) {
                .float => break :blk @as(u64, @intFromFloat(comment_val.float)),
                .integer => break :blk @as(u64, @intCast(comment_val.integer)),
                else => break :blk 0,
            }
        } else 0;
        
        const upload_date = if (json_obj.get("upload_date")) |date_val|
            if (date_val == .string) try self.allocator.dupe(u8, date_val.string) else try self.allocator.dupe(u8, "")
        else
            try self.allocator.dupe(u8, "");
        
        // Extract description/caption
        const description = if (json_obj.get("description")) |desc_val|
            if (desc_val == .string) desc_val.string else ""
        else if (json_obj.get("caption")) |caption_val|
            if (caption_val == .string) caption_val.string else ""
        else
            "";
        
        // Extract transcript if available
        const transcript = try self.extractTranscriptFromJson(json_obj, video_id);
        
        // Extract top comments if available
        const top_comments = try self.extractCommentsFromJson(json_obj);
        
        // Build comprehensive summary including description, transcript, and top comments
        const summary = try self.buildComprehensiveSummary(description, transcript, top_comments);
        
        // Create TikTok metadata with full transcript and comments
        const tiktok_metadata = types.YouTubeMetadata{
            .video_id = video_id,
            .channel_name = username,
            .duration = try std.fmt.allocPrint(self.allocator, "{d}s", .{duration}),
            .view_count = view_count,
            .like_count = @as(u32, @intCast(@min(like_count, std.math.maxInt(u32)))),
            .comment_count = @as(u32, @intCast(@min(comment_count, std.math.maxInt(u32)))),
            .upload_date = upload_date,
            .has_transcript = transcript != null,
            .transcript = transcript,
            .top_comments = top_comments,
        };
        
        // Calculate relevance score based on engagement
        const relevance_score = self.calculateRelevanceScore(title, description, view_count, like_count);
        
        return types.NewsItem{
            .title = title,
            .summary = summary,
            .url = video_url,
            .source = try std.fmt.allocPrint(self.allocator, "TikTok (@{s})", .{source.handle}),
            .source_type = .youtube, // Reuse YouTube type for now
            .timestamp = types.getCurrentTimestamp(),
            .relevance_score = relevance_score,
            .reddit_metadata = null,
            .youtube_metadata = tiktok_metadata,
            .huggingface_metadata = null,
            .blog_metadata = null,
            .github_metadata = null,
        };
    }
    
    /// Extract video ID from TikTok URL
    fn extractVideoIdFromUrl(self: *TikTokClient, url: []const u8) ![]const u8 {
        if (std.mem.indexOf(u8, url, "/video/")) |pos| {
            const id_start = pos + 7;
            const id_end = std.mem.indexOf(u8, url[id_start..], "?") orelse (url.len - id_start);
            return self.allocator.dupe(u8, url[id_start..id_start + id_end]);
        } else if (std.mem.indexOf(u8, url, "tiktok.com/")) |pos| {
            // Extract from various TikTok URL formats
            var id_start = pos + 11;
            while (id_start < url.len and url[id_start] != '/') id_start += 1;
            if (id_start < url.len) id_start += 1;
            
            const id_end = std.mem.indexOf(u8, url[id_start..], "/") orelse 
                          std.mem.indexOf(u8, url[id_start..], "?") orelse 
                          (url.len - id_start);
            return self.allocator.dupe(u8, url[id_start..id_start + id_end]);
        }
        return self.allocator.dupe(u8, "unknown");
    }
    
    /// Check if TikTok video is AI-related based on title and description
    fn isAIRelatedVideo(self: *TikTokClient, news_item: types.NewsItem) bool {
        _ = self;
        
        const ai_keywords = [_][]const u8{
            "AI", "artificial intelligence", "machine learning", "ML", "neural", "deep learning",
            "GPT", "LLM", "transformer", "ChatGPT", "Claude", "OpenAI", "Anthropic", "ollama",
            "computer vision", "NLP", "natural language", "algorithm", "model", "training",
            "inference", "embedding", "vector", "AGI", "automation", "coding", "programming",
            "data science", "analytics", "prediction", "classification", "PyTorch", "TensorFlow",
            "stable diffusion", "midjourney", "DALL-E", "diffusion", "generative", "chatbot",
            "fine-tuning", "RAG", "retrieval", "prompt", "tokens", "attention", "BERT",
            "tech", "technology", "software", "development", "tutorial", "guide", "howto"
        };
        
        const combined_text_stack = std.fmt.allocPrint(std.heap.page_allocator, "{s} {s}", .{ news_item.title, news_item.summary }) catch return false;
        defer std.heap.page_allocator.free(combined_text_stack);
        
        const lower_text = std.ascii.allocLowerString(std.heap.page_allocator, combined_text_stack) catch return false;
        defer std.heap.page_allocator.free(lower_text);
        
        for (ai_keywords) |keyword| {
            const lower_keyword = std.ascii.allocLowerString(std.heap.page_allocator, keyword) catch continue;
            defer std.heap.page_allocator.free(lower_keyword);
            
            if (std.mem.indexOf(u8, lower_text, lower_keyword) != null) {
                return true;
            }
        }
        
        return false;
    }
    
    /// Calculate relevance score based on TikTok-specific factors
    fn calculateRelevanceScore(self: *TikTokClient, title: []const u8, description: []const u8, view_count: u64, like_count: u64) f32 {
        _ = self;
        _ = description;
        
        var score: f32 = 0.3; // Base score
        
        // View count boost (logarithmic scale, TikTok has different scale than YouTube)
        if (view_count > 0) {
            const log_views = @log(@as(f32, @floatFromInt(view_count)));
            score += @min(log_views / 25.0, 0.3); // Max 0.3 boost from views
        }
        
        // Like count boost (important metric for TikTok)
        if (like_count > 0) {
            const log_likes = @log(@as(f32, @floatFromInt(like_count)));
            score += @min(log_likes / 15.0, 0.3); // Max 0.3 boost from likes
        }
        
        // High-value keywords in title boost
        const high_value_keywords = [_][]const u8{ "AI", "tutorial", "coding", "tech", "programming", "how to", "guide" };
        for (high_value_keywords) |keyword| {
            const lower_keyword = std.ascii.allocLowerString(std.heap.page_allocator, keyword) catch continue;
            defer std.heap.page_allocator.free(lower_keyword);
            
            const lower_title = std.ascii.allocLowerString(std.heap.page_allocator, title) catch continue;
            defer std.heap.page_allocator.free(lower_title);
            
            if (std.mem.indexOf(u8, lower_title, lower_keyword) != null) {
                score += 0.1;
            }
        }
        
        return @min(score, 1.0);
    }
    
    /// Extract transcript from TikTok JSON data and subtitle files
    fn extractTranscriptFromJson(self: *TikTokClient, json_obj: std.json.ObjectMap, video_id: []const u8) !?[]const u8 {
        // First try to get transcript from JSON subtitles field
        if (json_obj.get("subtitles")) |subs_val| {
            if (subs_val == .object) {
                // Try various subtitle language codes
                const lang_codes = [_][]const u8{ "en", "en-US", "auto" };
                for (lang_codes) |lang| {
                    if (subs_val.object.get(lang)) |lang_subs| {
                        if (lang_subs == .array and lang_subs.array.items.len > 0) {
                            // Extract text from first subtitle format
                            const sub_info = lang_subs.array.items[0];
                            if (sub_info == .object) {
                                if (sub_info.object.get("url")) |url_val| {
                                    if (url_val == .string) {
                                        // We have subtitle URL but can't download it easily
                                        // For now, just note that subtitles are available
                                        return try self.allocator.dupe(u8, "[Subtitles available but not extracted]");
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        
        // Try to read VTT files that yt-dlp might have downloaded
        return try self.readTranscriptFile(video_id);
    }
    
    /// Read transcript from VTT file if available
    fn readTranscriptFile(self: *TikTokClient, video_id: []const u8) !?[]const u8 {
        const vtt_filename = try std.fmt.allocPrint(self.allocator, "{s}.en.vtt", .{video_id});
        defer self.allocator.free(vtt_filename);
        
        // Try to read the VTT file
        const vtt_content = std.fs.cwd().readFileAlloc(self.allocator, vtt_filename, 1 * 1024 * 1024) catch |err| {
            // VTT file not found, try other variants
            const auto_vtt_filename = try std.fmt.allocPrint(self.allocator, "{s}.en-US.vtt", .{video_id});
            defer self.allocator.free(auto_vtt_filename);
            
            const auto_content = std.fs.cwd().readFileAlloc(self.allocator, auto_vtt_filename, 1 * 1024 * 1024) catch {
                std.log.debug("No transcript files found for TikTok video {s}: {}", .{ video_id, err });
                return null;
            };
            return try self.cleanVttContent(auto_content);
        };
        
        return try self.cleanVttContent(vtt_content);
    }
    
    /// Clean VTT subtitle content to extract just the spoken text
    fn cleanVttContent(self: *TikTokClient, vtt_content: []const u8) ![]const u8 {
        defer self.allocator.free(vtt_content);
        
        var cleaned = std.ArrayList(u8).init(self.allocator);
        defer cleaned.deinit();
        
        var lines = std.mem.splitScalar(u8, vtt_content, '\n');
        var in_cue = false;
        
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            
            // Skip WEBVTT header and NOTE lines
            if (std.mem.startsWith(u8, trimmed, "WEBVTT") or std.mem.startsWith(u8, trimmed, "NOTE")) {
                continue;
            }
            
            // Check if this is a timestamp line (contains -->)
            if (std.mem.indexOf(u8, trimmed, "-->") != null) {
                in_cue = true;
                continue;
            }
            
            // Empty line marks end of cue
            if (trimmed.len == 0) {
                in_cue = false;
                continue;
            }
            
            // If we're in a cue and this isn't a timestamp, it's subtitle text
            if (in_cue) {
                // Remove HTML tags and clean the text
                var clean_line = std.ArrayList(u8).init(self.allocator);
                defer clean_line.deinit();
                
                var i: usize = 0;
                var in_tag = false;
                while (i < trimmed.len) {
                    if (trimmed[i] == '<') {
                        in_tag = true;
                    } else if (trimmed[i] == '>') {
                        in_tag = false;
                    } else if (!in_tag) {
                        try clean_line.append(trimmed[i]);
                    }
                    i += 1;
                }
                
                if (clean_line.items.len > 0) {
                    try cleaned.appendSlice(clean_line.items);
                    try cleaned.append(' ');
                }
            }
        }
        
        return try cleaned.toOwnedSlice();
    }
    
    /// Extract top comments from TikTok JSON data
    fn extractCommentsFromJson(self: *TikTokClient, json_obj: std.json.ObjectMap) !?[]types.YouTubeMetadata.Comment {
        if (json_obj.get("comments")) |comments_val| {
            if (comments_val == .array) {
                const comments_array = comments_val.array;
                if (comments_array.items.len == 0) return null;
                
                // Limit to top 5 comments
                const max_comments = @min(comments_array.items.len, 5);
                var comments = try self.allocator.alloc(types.YouTubeMetadata.Comment, max_comments);
                
                for (comments_array.items[0..max_comments], 0..) |comment_val, i| {
                    if (comment_val == .object) {
                        const comment_obj = comment_val.object;
                        
                        const author = if (comment_obj.get("author")) |author_val|
                            if (author_val == .string) try self.allocator.dupe(u8, author_val.string) else try self.allocator.dupe(u8, "Unknown")
                        else
                            try self.allocator.dupe(u8, "Unknown");
                        
                        const text = if (comment_obj.get("text")) |text_val|
                            if (text_val == .string) try self.allocator.dupe(u8, text_val.string) else try self.allocator.dupe(u8, "")
                        else
                            try self.allocator.dupe(u8, "");
                        
                        const likes = if (comment_obj.get("like_count")) |like_val| blk: {
                            switch (like_val) {
                                .float => break :blk @as(u32, @intFromFloat(like_val.float)),
                                .integer => break :blk @as(u32, @intCast(like_val.integer)),
                                else => break :blk 0,
                            }
                        } else 0;
                        
                        comments[i] = types.YouTubeMetadata.Comment{
                            .author = author,
                            .text = text,
                            .likes = likes,
                        };
                    }
                }
                
                return comments;
            }
        }
        
        return null;
    }
    
    /// Build comprehensive summary including description, transcript, and top comments
    fn buildComprehensiveSummary(self: *TikTokClient, description: []const u8, transcript: ?[]const u8, top_comments: ?[]types.YouTubeMetadata.Comment) ![]const u8 {
        var summary_parts = std.ArrayList(u8).init(self.allocator);
        defer summary_parts.deinit();
        
        const writer = summary_parts.writer();
        
        // Add description/caption
        if (description.len > 0) {
            try writer.print("**Description:** {s}\n\n", .{description});
        }
        
        // Add full transcript if available
        if (transcript) |trans| {
            try writer.print("**Transcript:**\n{s}\n\n", .{trans});
        }
        
        // Add top comments if available
        if (top_comments) |comments| {
            try writer.print("**Top Comments ({d}):**\n", .{comments.len});
            for (comments, 0..) |comment, i| {
                try writer.print("{d}. **@{s}** ({d} likes): {s}\n", .{ i + 1, comment.author, comment.likes, comment.text });
            }
            try writer.print("\n", .{});
        }
        
        return try summary_parts.toOwnedSlice();
    }
};

/// Extract all TikTok videos from configured sources
pub fn extractAllTikTokVideos(allocator: std.mem.Allocator, _: anytype) ![]types.NewsItem {
    var tiktok_client = TikTokClient.init(allocator);
    
    var all_videos = std.ArrayList(types.NewsItem).init(allocator);
    defer {
        for (all_videos.items) |video| {
            video.deinit(allocator);
        }
        all_videos.deinit();
    }
    
    for (config.Config.tiktok_sources) |source| {
        const videos = tiktok_client.extractUserVideos(source) catch |err| {
            std.log.err("Failed to extract from @{s}: {}", .{ source.handle, err });
            continue;
        };
        defer allocator.free(videos);
        
        for (videos) |video| {
            try all_videos.append(video);
        }
    }
    
    const result = try all_videos.toOwnedSlice();
    all_videos = std.ArrayList(types.NewsItem).init(allocator); // Prevent cleanup
    return result;
}

// Test function
test "TikTok client video ID extraction" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var tiktok_client = TikTokClient.init(allocator);
    
    // Test video ID extraction
    const video_id = try tiktok_client.extractVideoIdFromUrl("https://www.tiktok.com/@user/video/1234567890");
    defer allocator.free(video_id);
    
    try std.testing.expect(std.mem.eql(u8, video_id, "1234567890"));
}