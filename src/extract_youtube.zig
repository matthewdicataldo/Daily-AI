const std = @import("std");
const types = @import("core_types.zig");
const config = @import("core_config.zig");
const utils = @import("core_utils.zig");

// Comptime constant arrays for performance
const AI_KEYWORDS = [_][]const u8{
    "AI", "artificial intelligence", "machine learning", "ML", "neural", "deep learning",
    "GPT", "LLM", "transformer", "ChatGPT", "Claude", "OpenAI", "Anthropic", "ollama",
    "computer vision", "NLP", "natural language", "algorithm", "model", "training",
    "inference", "embedding", "vector", "AGI", "automation", "coding", "programming",
    "data science", "analytics", "prediction", "classification", "PyTorch", "TensorFlow",
    "stable diffusion", "midjourney", "DALL-E", "diffusion", "generative", "chatbot",
    "fine-tuning", "RAG", "retrieval", "prompt", "tokens", "attention", "BERT"
};

// Pre-computed lowercase keywords for efficient matching
const AI_KEYWORDS_LOWER = [_][]const u8{
    "ai", "artificial intelligence", "machine learning", "ml", "neural", "deep learning",
    "gpt", "llm", "transformer", "chatgpt", "claude", "openai", "anthropic", "ollama",
    "computer vision", "nlp", "natural language", "algorithm", "model", "training",
    "inference", "embedding", "vector", "agi", "automation", "coding", "programming",
    "data science", "analytics", "prediction", "classification", "pytorch", "tensorflow",
    "stable diffusion", "midjourney", "dall-e", "diffusion", "generative", "chatbot",
    "fine-tuning", "rag", "retrieval", "prompt", "tokens", "attention", "bert"
};

pub const YouTubeClient = struct {
    allocator: std.mem.Allocator,
    yt_dlp_path: []const u8,
    
    pub fn init(allocator: std.mem.Allocator) YouTubeClient {
        return YouTubeClient{
            .allocator = allocator,
            .yt_dlp_path = "./yt-dlp", // Will be managed by build.zig
        };
    }
    
    /// Extract latest videos from a YouTube channel using yt-dlp
    pub fn extractChannelVideos(self: *YouTubeClient, source: config.YouTubeSource) ![]types.NewsItem {
        // Validate YouTube handle format to prevent injection
        if (!isValidYouTubeHandle(source.handle)) {
            std.log.err("Invalid YouTube handle format: {s}", .{source.handle});
            return &[_]types.NewsItem{};
        }
        
        const channel_url = try std.fmt.allocPrint(self.allocator, "https://www.youtube.com/{s}/videos", .{source.handle});
        defer self.allocator.free(channel_url);
        
        std.log.info("🎥 Extracting videos from {s} using yt-dlp...", .{source.handle});
        
        // Use yt-dlp to get channel video metadata as JSON
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
        try yt_dlp_args.append("--skip-download");
        try yt_dlp_args.append(channel_url);
        
        // Validate all arguments before execution to prevent injection
        for (yt_dlp_args.items) |arg| {
            if (!isValidYtDlpArgument(arg)) {
                std.log.err("Potentially dangerous yt-dlp argument detected: {s}", .{arg});
                return &[_]types.NewsItem{};
            }
        }
        
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
    
    /// Parse yt-dlp JSON output to extract video information
    fn parseYtDlpOutput(self: *YouTubeClient, json_output: []const u8, source: config.YouTubeSource) ![]types.NewsItem {
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
                std.log.warn("Failed to create news item from video JSON: {}", .{err});
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
        std.log.info("✅ Extracted {d} AI-related videos from {s}", .{ videos.items.len, source.handle });
        std.log.info("✅ ========================================", .{});
        std.log.info("", .{});
        return try videos.toOwnedSlice();
    }
    
    /// Create NewsItem from yt-dlp JSON data
    fn createNewsItemFromJson(self: *YouTubeClient, json_obj: std.json.ObjectMap, source: config.YouTubeSource) !types.NewsItem {
        // Extract title
        const title = if (json_obj.get("title")) |title_val|
            if (title_val == .string) try self.allocator.dupe(u8, title_val.string) else try self.allocator.dupe(u8, "Unknown Title")
        else
            try self.allocator.dupe(u8, "Unknown Title");
        
        // Extract video ID and construct URL
        const video_id = if (json_obj.get("id")) |id_val|
            if (id_val == .string) try self.allocator.dupe(u8, id_val.string) else try self.allocator.dupe(u8, "unknown")
        else if (json_obj.get("url")) |url_val|
            if (url_val == .string) try self.extractVideoIdFromUrl(url_val.string) else try self.allocator.dupe(u8, "unknown")
        else
            try self.allocator.dupe(u8, "unknown");
        
        const video_url = try std.fmt.allocPrint(self.allocator, "https://www.youtube.com/watch?v={s}", .{video_id});
        
        // Extract other metadata - safely handle null values
        const channel_name = blk: {
            if (json_obj.get("uploader")) |uploader_val| {
                if (uploader_val == .string) {
                    break :blk try self.allocator.dupe(u8, uploader_val.string);
                }
            }
            if (json_obj.get("channel")) |channel_val| {
                if (channel_val == .string) {
                    break :blk try self.allocator.dupe(u8, channel_val.string);
                }
            }
            if (json_obj.get("playlist_uploader")) |playlist_val| {
                if (playlist_val == .string) {
                    break :blk try self.allocator.dupe(u8, playlist_val.string);
                }
            }
            break :blk try self.allocator.dupe(u8, source.handle);
        };
        
        const duration = if (json_obj.get("duration_string")) |dur_val|
            if (dur_val == .string) try self.allocator.dupe(u8, dur_val.string) else try self.allocator.dupe(u8, "")
        else
            try self.allocator.dupe(u8, "");
        
        const view_count = if (json_obj.get("view_count")) |view_val| blk: {
            switch (view_val) {
                .float => break :blk @as(u64, @intFromFloat(view_val.float)),
                .integer => break :blk @as(u64, @intCast(view_val.integer)),
                else => break :blk 0,
            }
        } else 0;
        
        const upload_date = if (json_obj.get("upload_date")) |date_val|
            if (date_val == .string) try self.allocator.dupe(u8, date_val.string) else try self.allocator.dupe(u8, "")
        else
            try self.allocator.dupe(u8, "");
        
        // Try to extract transcript first, fallback to description
        const transcript = try self.extractTranscriptForVideo(video_id);
        
        const summary = if (transcript) |t| blk: {
            // Use full transcript as summary instead of description
            break :blk try self.allocator.dupe(u8, t);
        } else blk: {
            // Fallback to description if transcript not available
            const description = if (json_obj.get("description")) |desc_val|
                if (desc_val == .string) desc_val.string else ""
            else
                "";
            
            if (description.len > 300) {
                break :blk try std.fmt.allocPrint(self.allocator, "{s}...", .{description[0..300]});
            } else {
                break :blk try self.allocator.dupe(u8, description);
            }
        };
        
        // Create YouTube metadata
        const youtube_metadata = types.YouTubeMetadata{
            .video_id = video_id,
            .channel_name = channel_name,
            .duration = duration,
            .view_count = view_count,
            .like_count = 0, // Not available in flat playlist mode
            .comment_count = 0, // Not available in flat playlist mode
            .upload_date = upload_date,
            .has_transcript = transcript != null,
            .transcript = transcript,
            .top_comments = null,
        };
        
        // Calculate relevance score based on view count and recency (use summary which may be transcript or description)
        const relevance_score = self.calculateRelevanceScore(title, summary, view_count);
        
        return types.NewsItem{
            .title = title,
            .summary = summary,
            .url = video_url,
            .source = try std.fmt.allocPrint(self.allocator, "YouTube ({s})", .{source.handle}),
            .source_type = .youtube,
            .timestamp = types.getCurrentTimestamp(),
            .relevance_score = relevance_score,
            .reddit_metadata = null,
            .youtube_metadata = youtube_metadata,
            .huggingface_metadata = null,
            .blog_metadata = null,
            .github_metadata = null,
        };
    }
    
    /// Extract video ID from YouTube URL
    fn extractVideoIdFromUrl(self: *YouTubeClient, url: []const u8) ![]const u8 {
        if (std.mem.indexOf(u8, url, "v=")) |v_pos| {
            const id_start = v_pos + 2;
            const id_end = std.mem.indexOf(u8, url[id_start..], "&") orelse (url.len - id_start);
            return self.allocator.dupe(u8, url[id_start..id_start + id_end]);
        } else if (std.mem.indexOf(u8, url, "youtu.be/")) |be_pos| {
            const id_start = be_pos + 9;
            const id_end = std.mem.indexOf(u8, url[id_start..], "?") orelse (url.len - id_start);
            return self.allocator.dupe(u8, url[id_start..id_start + id_end]);
        }
        return self.allocator.dupe(u8, "unknown");
    }
    
    /// Extract transcript for a specific video
    fn extractTranscriptForVideo(self: *YouTubeClient, video_id: []const u8) !?[]const u8 {
        // Look for VTT subtitle files that yt-dlp might have downloaded
        const vtt_filename = try std.fmt.allocPrint(self.allocator, "{s}.en.vtt", .{video_id});
        defer self.allocator.free(vtt_filename);
        
        // Try to read the VTT file
        const vtt_content = std.fs.cwd().readFileAlloc(self.allocator, vtt_filename, 10 * 1024 * 1024) catch |err| {
            // VTT file not found, try auto-generated subtitles
            const auto_vtt_filename = try std.fmt.allocPrint(self.allocator, "{s}.en-US.vtt", .{video_id});
            defer self.allocator.free(auto_vtt_filename);
            
            const auto_content = std.fs.cwd().readFileAlloc(self.allocator, auto_vtt_filename, 10 * 1024 * 1024) catch {
                std.log.debug("No transcript files found for video {s}: {}", .{ video_id, err });
                return null;
            };
            return auto_content;
        };
        
        // Parse VTT content to extract just the text (remove timestamps and formatting)
        const cleaned_transcript = try self.cleanVttContent(vtt_content);
        self.allocator.free(vtt_content);
        
        return cleaned_transcript;
    }
    
    /// Clean VTT subtitle content to extract just the spoken text
    fn cleanVttContent(self: *YouTubeClient, vtt_content: []const u8) ![]const u8 {
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
    
    /// Check if video is AI-related based on title and description
    fn isAIRelatedVideo(self: *YouTubeClient, news_item: types.NewsItem) bool {
        const combined_text_stack = std.fmt.allocPrint(self.allocator, "{s} {s}", .{ news_item.title, news_item.summary }) catch return false;
        defer self.allocator.free(combined_text_stack);
        
        return utils.TextUtils.containsKeywords(self.allocator, combined_text_stack, &AI_KEYWORDS_LOWER);
    }
    
    /// Calculate relevance score based on multiple factors
    fn calculateRelevanceScore(self: *YouTubeClient, title: []const u8, description: []const u8, view_count: u64) f32 {
        _ = self;
        _ = description;
        
        var score: f32 = 0.3; // Base score
        
        // View count boost (logarithmic scale)
        if (view_count > 0) {
            const log_views = @log(@as(f32, @floatFromInt(view_count)));
            score += @min(log_views / 20.0, 0.4); // Max 0.4 boost from views
        }
        
        // High-value keywords in title boost
        const high_value_keywords = [_][]const u8{ "GPT", "Claude", "OpenAI", "AI", "tutorial", "guide", "how to" };
        for (high_value_keywords) |keyword| {
            const lower_keyword = std.ascii.allocLowerString(std.heap.page_allocator, keyword) catch continue;
            defer std.heap.page_allocator.free(lower_keyword);
            
            const lower_title = std.ascii.allocLowerString(std.heap.page_allocator, title) catch continue;
            defer std.heap.page_allocator.free(lower_title);
            
            if (std.mem.indexOf(u8, lower_title, lower_keyword) != null) {
                score += 0.2;
            }
        }
        
        return @min(score, 1.0);
    }
};

/// Extract all YouTube videos from configured sources
pub fn extractAllYouTubeVideos(allocator: std.mem.Allocator, _: anytype) ![]types.NewsItem {
    var youtube_client = YouTubeClient.init(allocator);
    
    var all_videos = std.ArrayList(types.NewsItem).init(allocator);
    errdefer {
        for (all_videos.items) |video| {
            video.deinit(allocator);
        }
        all_videos.deinit();
    }
    
    for (config.Config.youtube_sources) |source| {
        const videos = youtube_client.extractChannelVideos(source) catch |err| {
            std.log.err("Failed to extract from {s}: {}", .{ source.handle, err });
            continue;
        };
        defer allocator.free(videos);
        
        for (videos) |video| {
            try all_videos.append(video);
        }
    }
    
    return try all_videos.toOwnedSlice();
}

// Test function
test "YouTube client yt-dlp integration" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var youtube_client = YouTubeClient.init(allocator);
    
    // Test video ID extraction
    const video_id = try youtube_client.extractVideoIdFromUrl("https://www.youtube.com/watch?v=dQw4w9WgXcQ");
    defer allocator.free(video_id);
    
    try std.testing.expect(std.mem.eql(u8, video_id, "dQw4w9WgXcQ"));
}

/// Validate YouTube handle format (should start with @ and contain only safe characters)
fn isValidYouTubeHandle(handle: []const u8) bool {
    if (handle.len == 0) return false;
    
    // Should start with @ for user handles or be a channel ID
    if (!std.mem.startsWith(u8, handle, "@") and !std.mem.startsWith(u8, handle, "c/") and !std.mem.startsWith(u8, handle, "channel/")) {
        return false;
    }
    
    // Check for dangerous characters that could be used for injection
    for (handle) |c| {
        if (c == ';' or c == '&' or c == '|' or c == '`' or c == '$' or c == '\n' or c == '\r' or c == 0) {
            return false;
        }
        // Only allow alphanumeric, underscore, hyphen, slash, and @
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-' and c != '/' and c != '@') {
            return false;
        }
    }
    
    return true;
}

/// Validate yt-dlp argument to prevent command injection
fn isValidYtDlpArgument(arg: []const u8) bool {
    // Check for dangerous characters and command injection patterns
    for (arg) |c| {
        if (c == ';' or c == '&' or c == '|' or c == '`' or c == '$' or c == '\n' or c == '\r' or c == 0) {
            return false;
        }
    }
    
    // Reject arguments that look like shell commands or redirections
    if (std.mem.startsWith(u8, arg, "rm ") or std.mem.startsWith(u8, arg, "curl ") or 
        std.mem.indexOf(u8, arg, "> ") != null or std.mem.indexOf(u8, arg, "< ") != null) {
        return false;
    }
    
    return true;
}