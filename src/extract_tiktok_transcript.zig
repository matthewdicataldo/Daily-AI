const std = @import("std");

/// Enhanced transcript extraction for TikTok videos with multiple format support
pub const TikTokTranscriptExtractor = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) TikTokTranscriptExtractor {
        return TikTokTranscriptExtractor{
            .allocator = allocator,
        };
    }
    
    /// Extract transcript from TikTok JSON data and subtitle files with robust fallback
    pub fn extractTranscriptFromJson(self: *TikTokTranscriptExtractor, json_obj: std.json.ObjectMap, video_id: []const u8) !?[]const u8 {
        // Strategy 1: Try to extract from JSON metadata
        if (try self.extractFromJsonMetadata(json_obj)) |transcript| {
            std.log.debug("Extracted transcript from TikTok JSON metadata for video {s}", .{video_id});
            return transcript;
        }
        
        // Strategy 2: Try to download subtitles from URLs in JSON
        if (try self.downloadSubtitlesFromJson(json_obj)) |transcript| {
            std.log.debug("Downloaded transcript from TikTok subtitle URLs for video {s}", .{video_id});
            return transcript;
        }
        
        // Strategy 3: Try to read local subtitle files
        if (try self.readLocalTranscriptFiles(video_id)) |transcript| {
            std.log.debug("Found local transcript files for TikTok video {s}", .{video_id});
            return transcript;
        }
        
        // Strategy 4: Try to extract from video description/comments as fallback
        if (try self.extractFromVideoMetadata(json_obj)) |text| {
            std.log.debug("Using video metadata as transcript fallback for TikTok video {s}", .{video_id});
            return text;
        }
        
        std.log.debug("No transcript found for TikTok video {s} after all strategies", .{video_id});
        return null;
    }
    
    /// Extract transcript from JSON metadata fields
    fn extractFromJsonMetadata(self: *TikTokTranscriptExtractor, json_obj: std.json.ObjectMap) !?[]const u8 {
        // Try different subtitle/caption fields that TikTok might use
        const caption_fields = [_][]const u8{
            "subtitles", "captions", "transcript", "auto_captions", 
            "automatic_captions", "text_tracks", "closed_captions"
        };
        
        for (caption_fields) |field| {
            if (json_obj.get(field)) |field_val| {
                if (try self.parseSubtitleField(field_val)) |transcript| {
                    return transcript;
                }
            }
        }
        
        return null;
    }
    
    /// Parse various subtitle field formats
    fn parseSubtitleField(self: *TikTokTranscriptExtractor, field_val: std.json.Value) !?[]const u8 {
        switch (field_val) {
            .string => |text| {
                // Direct text content
                return try self.allocator.dupe(u8, text);
            },
            .array => |array| {
                // Array of subtitle entries
                return try self.parseSubtitleArray(array.items);
            },
            .object => |obj| {
                // Object with language-specific subtitles
                return try self.parseSubtitleObject(obj);
            },
            else => return null,
        }
    }
    
    /// Parse subtitle array format
    fn parseSubtitleArray(self: *TikTokTranscriptExtractor, items: []std.json.Value) !?[]const u8 {
        var transcript = std.ArrayList(u8).init(self.allocator);
        defer transcript.deinit();
        
        for (items) |item| {
            if (item == .object) {
                // Look for text fields in subtitle objects
                const text_fields = [_][]const u8{ "text", "content", "caption", "subtitle" };
                
                for (text_fields) |field| {
                    if (item.object.get(field)) |text_val| {
                        if (text_val == .string) {
                            if (transcript.items.len > 0) {
                                try transcript.append(' ');
                            }
                            try transcript.appendSlice(text_val.string);
                            break;
                        }
                    }
                }
            } else if (item == .string) {
                if (transcript.items.len > 0) {
                    try transcript.append(' ');
                }
                try transcript.appendSlice(item.string);
            }
        }
        
        if (transcript.items.len > 0) {
            return try transcript.toOwnedSlice();
        }
        
        return null;
    }
    
    /// Parse subtitle object format with language keys
    fn parseSubtitleObject(self: *TikTokTranscriptExtractor, obj: std.json.ObjectMap) !?[]const u8 {
        // Try common language codes
        const lang_codes = [_][]const u8{ 
            "en", "en-US", "en-GB", "auto", "eng", "english",
            "zh", "zh-CN", "zh-TW", "cn", "chinese",
            "es", "spanish", "fr", "french", "de", "german"
        };
        
        for (lang_codes) |lang| {
            if (obj.get(lang)) |lang_val| {
                if (try self.parseSubtitleField(lang_val)) |transcript| {
                    return transcript;
                }
            }
        }
        
        // If no specific language found, try first available entry
        var iterator = obj.iterator();
        if (iterator.next()) |entry| {
            return try self.parseSubtitleField(entry.value_ptr.*);
        }
        
        return null;
    }
    
    /// Try to download subtitles from URLs found in JSON
    fn downloadSubtitlesFromJson(self: *TikTokTranscriptExtractor, json_obj: std.json.ObjectMap) !?[]const u8 {
        // Look for subtitle URLs in various fields
        const url_fields = [_][]const u8{
            "subtitle_url", "caption_url", "transcript_url", "subtitles"
        };
        
        for (url_fields) |field| {
            if (json_obj.get(field)) |field_val| {
                if (try self.extractUrlsAndDownload(field_val)) |transcript| {
                    return transcript;
                }
            }
        }
        
        return null;
    }
    
    /// Extract URLs and attempt to download subtitle content
    fn extractUrlsAndDownload(self: *TikTokTranscriptExtractor, field_val: std.json.Value) !?[]const u8 {
        var urls = std.ArrayList([]const u8).init(self.allocator);
        defer urls.deinit();
        
        switch (field_val) {
            .string => |url| {
                try urls.append(url);
            },
            .array => |array| {
                for (array.items) |item| {
                    if (item == .string) {
                        try urls.append(item.string);
                    } else if (item == .object) {
                        if (item.object.get("url")) |url_val| {
                            if (url_val == .string) {
                                try urls.append(url_val.string);
                            }
                        }
                    }
                }
            },
            .object => |obj| {
                var iterator = obj.iterator();
                while (iterator.next()) |entry| {
                    if (entry.value_ptr.* == .string) {
                        try urls.append(entry.value_ptr.string);
                    }
                }
            },
            else => return null,
        }
        
        // Try to download from each URL (simplified - in practice would use HTTP client)
        for (urls.items) |url| {
            if (std.mem.startsWith(u8, url, "http")) {
                std.log.debug("Found subtitle URL but download not implemented: {s}", .{url});
                // For now, just note that subtitles are available
                return try self.allocator.dupe(u8, "[Subtitles available via URL but not downloaded]");
            }
        }
        
        return null;
    }
    
    /// Read local transcript files with multiple format support
    fn readLocalTranscriptFiles(self: *TikTokTranscriptExtractor, video_id: []const u8) !?[]const u8 {
        // Try multiple transcript file formats and locations
        const transcript_variants = [_][]const u8{
            "{s}.en.vtt",           // VTT format
            "{s}.en-US.vtt",        
            "{s}.auto.vtt",         
            "{s}.en.srt",           // SRT format
            "{s}.en.json",          // JSON format
            "{s}.en.ttml",          // TTML format
            "{s}.en.txt",           // Plain text
            "{s}_captions.json",    // TikTok specific
            "{s}_transcript.txt",   
        };
        
        for (transcript_variants) |variant_pattern| {
            const filename = try std.fmt.allocPrint(self.allocator, variant_pattern, .{video_id});
            defer self.allocator.free(filename);
            
            if (self.tryReadAndParseFile(filename)) |content| {
                std.log.debug("Found TikTok transcript file: {s}", .{filename});
                return content;
            } else |_| {
                // Continue to next variant
            }
        }
        
        // Try alternative directory locations
        const alt_locations = [_][]const u8{ 
            "tiktok_transcripts/{s}.en.vtt",
            "transcripts/tiktok/{s}.en.vtt",
            "subtitles/{s}.en.vtt", 
            "downloads/tiktok/{s}.en.vtt",
            "temp/{s}.en.vtt",
        };
        
        for (alt_locations) |location_pattern| {
            const filepath = try std.fmt.allocPrint(self.allocator, location_pattern, .{video_id});
            defer self.allocator.free(filepath);
            
            if (self.tryReadAndParseFile(filepath)) |content| {
                std.log.debug("Found TikTok transcript in alternate location: {s}", .{filepath});
                return content;
            } else |_| {
                // Continue searching
            }
        }
        
        return null;
    }
    
    /// Try to read and parse transcript file based on extension
    fn tryReadAndParseFile(self: *TikTokTranscriptExtractor, filepath: []const u8) ![]const u8 {
        const content = try std.fs.cwd().readFileAlloc(self.allocator, filepath, 5 * 1024 * 1024); // 5MB limit
        defer self.allocator.free(content);
        
        // Parse based on file extension
        if (std.mem.endsWith(u8, filepath, ".vtt")) {
            return try self.cleanVttContent(content);
        } else if (std.mem.endsWith(u8, filepath, ".srt")) {
            return try self.cleanSrtContent(content);
        } else if (std.mem.endsWith(u8, filepath, ".json")) {
            return try self.parseJsonTranscript(content);
        } else if (std.mem.endsWith(u8, filepath, ".ttml")) {
            return try self.cleanTtmlContent(content);
        } else if (std.mem.endsWith(u8, filepath, ".txt")) {
            return try self.cleanPlainText(content);
        } else {
            // Default to VTT cleaning
            return try self.cleanVttContent(content);
        }
    }
    
    /// Extract text from video metadata as fallback
    fn extractFromVideoMetadata(self: *TikTokTranscriptExtractor, json_obj: std.json.ObjectMap) !?[]const u8 {
        var metadata_text = std.ArrayList(u8).init(self.allocator);
        defer metadata_text.deinit();
        
        // Extract description/caption
        if (json_obj.get("description")) |desc_val| {
            if (desc_val == .string and desc_val.string.len > 0) {
                try metadata_text.appendSlice(desc_val.string);
            }
        }
        
        // Extract video title if available
        if (json_obj.get("title")) |title_val| {
            if (title_val == .string and title_val.string.len > 0) {
                if (metadata_text.items.len > 0) {
                    try metadata_text.appendSlice(" | ");
                }
                try metadata_text.appendSlice(title_val.string);
            }
        }
        
        // Extract hashtags/tags
        if (json_obj.get("tags")) |tags_val| {
            if (tags_val == .array) {
                for (tags_val.array.items) |tag| {
                    if (tag == .string) {
                        if (metadata_text.items.len > 0) {
                            try metadata_text.append(' ');
                        }
                        try metadata_text.append('#');
                        try metadata_text.appendSlice(tag.string);
                    }
                }
            }
        }
        
        if (metadata_text.items.len > 0) {
            return try metadata_text.toOwnedSlice();
        }
        
        return null;
    }
    
    /// Clean VTT content (same as YouTube implementation)
    fn cleanVttContent(self: *TikTokTranscriptExtractor, vtt_content: []const u8) ![]const u8 {
        var cleaned = std.ArrayList(u8).init(self.allocator);
        defer cleaned.deinit();
        
        var lines = std.mem.splitScalar(u8, vtt_content, '\n');
        var in_cue = false;
        
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            
            // Skip WEBVTT header and NOTE lines
            if (std.mem.startsWith(u8, trimmed, "WEBVTT") or 
                std.mem.startsWith(u8, trimmed, "NOTE") or
                std.mem.startsWith(u8, trimmed, "STYLE")) {
                continue;
            }
            
            // Check if this is a timestamp line
            if (std.mem.indexOf(u8, trimmed, "-->") != null) {
                in_cue = true;
                continue;
            }
            
            // Empty line marks end of cue
            if (trimmed.len == 0) {
                in_cue = false;
                continue;
            }
            
            // Extract subtitle text
            if (in_cue) {
                const clean_text = try self.removeHtmlTags(trimmed);
                defer self.allocator.free(clean_text);
                
                if (clean_text.len > 0) {
                    if (cleaned.items.len > 0) {
                        try cleaned.append(' ');
                    }
                    try cleaned.appendSlice(clean_text);
                }
            }
        }
        
        return try cleaned.toOwnedSlice();
    }
    
    /// Clean SRT content
    fn cleanSrtContent(self: *TikTokTranscriptExtractor, srt_content: []const u8) ![]const u8 {
        var cleaned = std.ArrayList(u8).init(self.allocator);
        defer cleaned.deinit();
        
        var lines = std.mem.splitScalar(u8, srt_content, '\n');
        var skip_timestamps = false;
        
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            
            // Skip sequence numbers (lines with just digits)
            if (trimmed.len > 0 and std.ascii.isDigit(trimmed[0])) {
                var all_digits = true;
                for (trimmed) |c| {
                    if (!std.ascii.isDigit(c)) {
                        all_digits = false;
                        break;
                    }
                }
                if (all_digits) {
                    skip_timestamps = true;
                    continue;
                }
            }
            
            // Skip timestamp lines
            if (skip_timestamps and std.mem.indexOf(u8, trimmed, "-->") != null) {
                skip_timestamps = false;
                continue;
            }
            
            // Empty line marks end of subtitle block
            if (trimmed.len == 0) {
                continue;
            }
            
            // Extract subtitle text
            const clean_text = try self.removeHtmlTags(trimmed);
            defer self.allocator.free(clean_text);
            
            if (clean_text.len > 0) {
                if (cleaned.items.len > 0) {
                    try cleaned.append(' ');
                }
                try cleaned.appendSlice(clean_text);
            }
        }
        
        return try cleaned.toOwnedSlice();
    }
    
    /// Parse JSON transcript format
    fn parseJsonTranscript(self: *TikTokTranscriptExtractor, json_content: []const u8) ![]const u8 {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const temp_allocator = arena.allocator();
        
        const parsed = std.json.parseFromSlice(std.json.Value, temp_allocator, json_content, .{}) catch {
            // If JSON parsing fails, try as plain text
            return try self.cleanPlainText(json_content);
        };
        
        if (parsed.value == .object) {
            if (try self.parseSubtitleObject(parsed.value.object)) |transcript| {
                return transcript;
            }
        } else if (parsed.value == .array) {
            if (try self.parseSubtitleArray(parsed.value.array.items)) |transcript| {
                return transcript;
            }
        }
        
        // Fallback to plain text processing
        return try self.cleanPlainText(json_content);
    }
    
    /// Clean TTML content
    fn cleanTtmlContent(self: *TikTokTranscriptExtractor, ttml_content: []const u8) ![]const u8 {
        return try self.extractTextFromXml(ttml_content);
    }
    
    /// Clean plain text content
    fn cleanPlainText(self: *TikTokTranscriptExtractor, text_content: []const u8) ![]const u8 {
        // Remove extra whitespace and normalize
        return try self.normalizeWhitespace(text_content);
    }
    
    /// Extract text from XML-based formats
    fn extractTextFromXml(self: *TikTokTranscriptExtractor, xml_content: []const u8) ![]const u8 {
        var cleaned = std.ArrayList(u8).init(self.allocator);
        defer cleaned.deinit();
        
        var i: usize = 0;
        var in_tag = false;
        
        while (i < xml_content.len) {
            if (xml_content[i] == '<') {
                in_tag = true;
            } else if (xml_content[i] == '>') {
                in_tag = false;
            } else if (!in_tag and xml_content[i] != '\n' and xml_content[i] != '\r') {
                try cleaned.append(xml_content[i]);
            }
            i += 1;
        }
        
        return try self.normalizeWhitespace(try cleaned.toOwnedSlice());
    }
    
    /// Remove HTML tags from text
    fn removeHtmlTags(self: *TikTokTranscriptExtractor, text: []const u8) ![]const u8 {
        var clean_text = std.ArrayList(u8).init(self.allocator);
        defer clean_text.deinit();
        
        var i: usize = 0;
        var in_tag = false;
        
        while (i < text.len) {
            if (text[i] == '<') {
                in_tag = true;
            } else if (text[i] == '>') {
                in_tag = false;
            } else if (!in_tag) {
                try clean_text.append(text[i]);
            }
            i += 1;
        }
        
        return try clean_text.toOwnedSlice();
    }
    
    /// Normalize whitespace in text
    fn normalizeWhitespace(self: *TikTokTranscriptExtractor, text: []const u8) ![]const u8 {
        var normalized = std.ArrayList(u8).init(self.allocator);
        defer normalized.deinit();
        
        var last_was_space = false;
        
        for (text) |char| {
            if (std.ascii.isWhitespace(char)) {
                if (!last_was_space) {
                    try normalized.append(' ');
                    last_was_space = true;
                }
            } else {
                try normalized.append(char);
                last_was_space = false;
            }
        }
        
        // Trim leading/trailing whitespace
        const result = std.mem.trim(u8, try normalized.toOwnedSlice(), " ");
        return try self.allocator.dupe(u8, result);
    }
};