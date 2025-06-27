const std = @import("std");

/// Enhanced transcript extraction for YouTube videos with multiple format support
pub const TranscriptExtractor = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) TranscriptExtractor {
        return TranscriptExtractor{
            .allocator = allocator,
        };
    }
    
    /// Extract transcript for a specific video with robust fallback strategy
    pub fn extractTranscriptForVideo(self: *TranscriptExtractor, video_id: []const u8) !?[]const u8 {
        // Try multiple transcript file formats and locations
        const transcript_variants = [_][]const u8{
            "{s}.en.vtt",           // Manual English subtitles
            "{s}.en-US.vtt",        // Auto-generated US English
            "{s}.en-GB.vtt",        // Auto-generated UK English  
            "{s}.auto.vtt",         // Auto-generated any language
            "{s}.en.srv3",          // YouTube SRV3 format
            "{s}.en.ttml",          // TTML format
            "{s}.en.json3",         // JSON3 format
            "{s}.en.srt",           // SRT format
            "{s}.en.ass",           // ASS format
        };
        
        for (transcript_variants) |variant_pattern| {
            const filename = try std.fmt.allocPrint(self.allocator, variant_pattern, .{video_id});
            defer self.allocator.free(filename);
            
            if (self.tryReadTranscriptFile(filename)) |content| {
                std.log.info("", .{});
                std.log.info("📝 ========================================", .{});
                std.log.info("📝 Found transcript file: {s} for video {s}", .{ filename, video_id });
                std.log.info("📝 ========================================", .{});
                std.log.info("📄 Transcript content ({d} chars):", .{content.len});
                std.log.info("", .{});
                std.log.info("{s}", .{content[0..@min(content.len, 500)]});
                if (content.len > 500) {
                    std.log.info("", .{});
                    std.log.info("📄 ...transcript continues for {d} more characters", .{ content.len - 500 });
                }
                std.log.info("", .{});
                return content;
            } else |_| {
                std.log.debug("❌ Transcript file not found: {s}", .{filename});
            }
        }
        
        // Try alternative directory locations
        const alt_locations = [_][]const u8{ 
            "transcripts/{s}.en.vtt",
            "subtitles/{s}.en.vtt", 
            "downloads/{s}.en.vtt",
            "temp/{s}.en.vtt",
            "./output/{s}.en.vtt",
        };
        
        for (alt_locations) |location_pattern| {
            const filepath = try std.fmt.allocPrint(self.allocator, location_pattern, .{video_id});
            defer self.allocator.free(filepath);
            
            if (self.tryReadTranscriptFile(filepath)) |content| {
                std.log.debug("Found transcript in alternate location: {s}", .{filepath});
                return content;
            } else |_| {
                // Continue searching
            }
        }
        
        // Try with common video ID patterns
        const id_patterns = [_][]const u8{
            "{s}",              // Exact ID
            "{s}.f*",           // With format code
            "*{s}*",            // Partial match
        };
        
        for (id_patterns) |pattern| {
            const search_pattern = try std.fmt.allocPrint(self.allocator, pattern, .{video_id});
            defer self.allocator.free(search_pattern);
            
            if (self.findTranscriptByPattern(search_pattern)) |content| {
                std.log.debug("Found transcript by pattern: {s}", .{search_pattern});
                return content;
            } else |_| {
                // Continue searching
            }
        }
        
        std.log.debug("No transcript files found for video {s} after exhaustive search", .{video_id});
        return null;
    }
    
    /// Try to read and process a transcript file
    fn tryReadTranscriptFile(self: *TranscriptExtractor, filepath: []const u8) ![]const u8 {
        const content = try std.fs.cwd().readFileAlloc(self.allocator, filepath, 10 * 1024 * 1024);
        defer self.allocator.free(content);
        
        // Determine format and clean accordingly
        if (std.mem.endsWith(u8, filepath, ".vtt")) {
            return try self.cleanVttContent(content);
        } else if (std.mem.endsWith(u8, filepath, ".json3")) {
            return try self.cleanJson3Content(content);
        } else if (std.mem.endsWith(u8, filepath, ".srv3")) {
            return try self.cleanSrv3Content(content);
        } else if (std.mem.endsWith(u8, filepath, ".ttml")) {
            return try self.cleanTtmlContent(content);
        } else if (std.mem.endsWith(u8, filepath, ".srt")) {
            return try self.cleanSrtContent(content);
        } else if (std.mem.endsWith(u8, filepath, ".ass")) {
            return try self.cleanAssContent(content);
        } else {
            // Default to VTT cleaning for unknown formats
            return try self.cleanVttContent(content);
        }
    }
    
    /// Find transcript files by pattern matching
    fn findTranscriptByPattern(self: *TranscriptExtractor, pattern: []const u8) !?[]const u8 {
        _ = self;
        _ = pattern;
        // This would require directory scanning which is complex in Zig
        // For now, return null but this could be implemented with std.fs.Dir.iterate
        return null;
    }
    
    /// Clean VTT subtitle content to extract just the spoken text
    fn cleanVttContent(self: *TranscriptExtractor, vtt_content: []const u8) ![]const u8 {
        var cleaned = std.ArrayList(u8).init(self.allocator);
        defer cleaned.deinit();
        
        var lines = std.mem.splitScalar(u8, vtt_content, '\n');
        var in_cue = false;
        var last_text: ?[]const u8 = null;
        
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            
            // Skip WEBVTT header, NOTE lines, and style information
            if (std.mem.startsWith(u8, trimmed, "WEBVTT") or 
                std.mem.startsWith(u8, trimmed, "NOTE") or
                std.mem.startsWith(u8, trimmed, "STYLE")) {
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
                last_text = null;
                continue;
            }
            
            // If we're in a cue and this isn't a timestamp, it's subtitle text
            if (in_cue) {
                const clean_text = try self.removeHtmlTags(trimmed);
                defer self.allocator.free(clean_text);
                
                // Avoid duplicate text (common in auto-generated subtitles)
                if (last_text == null or !std.mem.eql(u8, clean_text, last_text.?)) {
                    if (cleaned.items.len > 0) {
                        try cleaned.append(' ');
                    }
                    try cleaned.appendSlice(clean_text);
                    last_text = try self.allocator.dupe(u8, clean_text);
                }
            }
        }
        
        // Clean up last_text if allocated
        if (last_text) |text| {
            self.allocator.free(text);
        }
        
        return try cleaned.toOwnedSlice();
    }
    
    /// Clean JSON3 format content
    fn cleanJson3Content(self: *TranscriptExtractor, json_content: []const u8) ![]const u8 {
        var cleaned = std.ArrayList(u8).init(self.allocator);
        defer cleaned.deinit();
        
        // Parse JSON3 format (YouTube's JSON subtitle format)
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const temp_allocator = arena.allocator();
        
        const parsed = std.json.parseFromSlice(std.json.Value, temp_allocator, json_content, .{}) catch |err| {
            std.log.warn("Failed to parse JSON3 content: {}", .{err});
            return try self.allocator.dupe(u8, "");
        };
        
        if (parsed.value != .object) return try self.allocator.dupe(u8, "");
        
        const root = parsed.value.object;
        if (root.get("events")) |events_val| {
            if (events_val == .array) {
                for (events_val.array.items) |event| {
                    if (event == .object) {
                        if (event.object.get("segs")) |segs_val| {
                            if (segs_val == .array) {
                                for (segs_val.array.items) |seg| {
                                    if (seg == .object) {
                                        if (seg.object.get("utf8")) |text_val| {
                                            if (text_val == .string) {
                                                if (cleaned.items.len > 0) {
                                                    try cleaned.append(' ');
                                                }
                                                try cleaned.appendSlice(text_val.string);
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        
        return try cleaned.toOwnedSlice();
    }
    
    /// Clean SRV3 format content  
    fn cleanSrv3Content(self: *TranscriptExtractor, srv3_content: []const u8) ![]const u8 {
        // SRV3 is XML-based format, simplified parsing
        return try self.extractTextFromXml(srv3_content);
    }
    
    /// Clean TTML format content
    fn cleanTtmlContent(self: *TranscriptExtractor, ttml_content: []const u8) ![]const u8 {
        // TTML is also XML-based
        return try self.extractTextFromXml(ttml_content);
    }
    
    /// Clean SRT format content
    fn cleanSrtContent(self: *TranscriptExtractor, srt_content: []const u8) ![]const u8 {
        var cleaned = std.ArrayList(u8).init(self.allocator);
        defer cleaned.deinit();
        
        var lines = std.mem.splitScalar(u8, srt_content, '\n');
        var skip_next = false;
        
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            
            // Skip sequence numbers
            if (std.ascii.isDigit(trimmed[0])) {
                skip_next = true;
                continue;
            }
            
            // Skip timestamp lines
            if (skip_next and std.mem.indexOf(u8, trimmed, "-->") != null) {
                skip_next = false;
                continue;
            }
            
            // Empty line marks end of subtitle block
            if (trimmed.len == 0) {
                continue;
            }
            
            // This should be subtitle text
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
    
    /// Clean ASS format content
    fn cleanAssContent(self: *TranscriptExtractor, ass_content: []const u8) ![]const u8 {
        var cleaned = std.ArrayList(u8).init(self.allocator);
        defer cleaned.deinit();
        
        var lines = std.mem.splitScalar(u8, ass_content, '\n');
        
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            
            // Look for dialogue lines
            if (std.mem.startsWith(u8, trimmed, "Dialogue:")) {
                // ASS format: Dialogue: Layer,Start,End,Style,Name,MarginL,MarginR,MarginV,Effect,Text
                var parts = std.mem.splitScalar(u8, trimmed, ',');
                var part_count: u32 = 0;
                
                while (parts.next()) |part| {
                    part_count += 1;
                    if (part_count >= 10) { // Text is the 10th field
                        const clean_text = try self.removeAssFormatting(part);
                        defer self.allocator.free(clean_text);
                        
                        if (clean_text.len > 0) {
                            if (cleaned.items.len > 0) {
                                try cleaned.append(' ');
                            }
                            try cleaned.appendSlice(clean_text);
                        }
                        break;
                    }
                }
            }
        }
        
        return try cleaned.toOwnedSlice();
    }
    
    /// Extract text content from XML-based formats
    fn extractTextFromXml(self: *TranscriptExtractor, xml_content: []const u8) ![]const u8 {
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
        
        // Clean up extra whitespace
        const result = try cleaned.toOwnedSlice();
        return try self.normalizeWhitespace(result);
    }
    
    /// Remove HTML tags from text
    fn removeHtmlTags(self: *TranscriptExtractor, text: []const u8) ![]const u8 {
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
    
    /// Remove ASS formatting codes
    fn removeAssFormatting(self: *TranscriptExtractor, text: []const u8) ![]const u8 {
        var clean_text = std.ArrayList(u8).init(self.allocator);
        defer clean_text.deinit();
        
        var i: usize = 0;
        var in_format = false;
        
        while (i < text.len) {
            if (text[i] == '{') {
                in_format = true;
            } else if (text[i] == '}') {
                in_format = false;
            } else if (!in_format) {
                try clean_text.append(text[i]);
            }
            i += 1;
        }
        
        return try clean_text.toOwnedSlice();
    }
    
    /// Normalize whitespace in text
    fn normalizeWhitespace(self: *TranscriptExtractor, text: []const u8) ![]const u8 {
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
        
        return try normalized.toOwnedSlice();
    }
};