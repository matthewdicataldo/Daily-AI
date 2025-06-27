const std = @import("std");
const types = @import("core_types.zig");

/// Generic cloning utilities to reduce code duplication
pub const CloneUtils = struct {
    /// Generic function to clone any type that has a clone method
    pub fn cloneMetadata(comptime T: type, allocator: std.mem.Allocator, metadata: T) !T {
        return metadata.clone(allocator);
    }
    
    /// Clone an array of strings
    pub fn cloneStringArray(allocator: std.mem.Allocator, strings: []const []const u8) ![][]const u8 {
        var cloned = try allocator.alloc([]const u8, strings.len);
        for (strings, 0..) |string, i| {
            cloned[i] = try allocator.dupe(u8, string);
        }
        return cloned;
    }
    
    /// Clone an optional string
    pub fn cloneOptionalString(allocator: std.mem.Allocator, opt_string: ?[]const u8) !?[]const u8 {
        if (opt_string) |string| {
            return try allocator.dupe(u8, string);
        }
        return null;
    }
    
    /// Generic NewsItem cloning with reduced duplication
    pub fn cloneNewsItem(allocator: std.mem.Allocator, item: types.NewsItem) !types.NewsItem {
        return types.NewsItem{
            .title = try allocator.dupe(u8, item.title),
            .summary = try allocator.dupe(u8, item.summary),
            .url = try allocator.dupe(u8, item.url),
            .source = try allocator.dupe(u8, item.source),
            .source_type = item.source_type,
            .timestamp = item.timestamp,
            .relevance_score = item.relevance_score,
            .reddit_metadata = if (item.reddit_metadata) |metadata| try cloneMetadata(types.RedditMetadata, allocator, metadata) else null,
            .youtube_metadata = if (item.youtube_metadata) |metadata| try cloneMetadata(types.YouTubeMetadata, allocator, metadata) else null,
            .huggingface_metadata = if (item.huggingface_metadata) |metadata| try cloneMetadata(types.HuggingFaceMetadata, allocator, metadata) else null,
            .blog_metadata = if (item.blog_metadata) |metadata| try cloneMetadata(types.BlogMetadata, allocator, metadata) else null,
            .github_metadata = if (item.github_metadata) |metadata| try cloneMetadata(types.GitHubRepoMetadata, allocator, metadata) else null,
        };
    }
};

/// Common error handling utilities
pub const ErrorUtils = struct {
    /// Standard error logging with context
    pub fn logError(comptime context: []const u8, err: anyerror, details: ?[]const u8) void {
        if (details) |d| {
            std.log.err("❌ {s}: {} - {s}", .{ context, err, d });
        } else {
            std.log.err("❌ {s}: {}", .{ context, err });
        }
    }
    
    /// Log warning with context
    pub fn logWarning(comptime context: []const u8, message: []const u8) void {
        std.log.warn("⚠️ {s}: {s}", .{ context, message });
    }
    
    /// Log success with context
    pub fn logSuccess(comptime context: []const u8, message: []const u8) void {
        std.log.info("✅ {s}: {s}", .{ context, message });
    }
    
    /// Generic error wrapper for client operations
    pub fn wrapClientError(comptime ClientType: type, comptime operation: []const u8) type {
        return struct {
            pub fn execute(client: *ClientType, args: anytype) !ClientType.ResultType {
                return client.operation(args) catch |err| {
                    logError(operation, err, null);
                    return err;
                };
            }
        };
    }
};

/// Text processing utilities used across multiple modules
pub const TextUtils = struct {
    /// Normalize text for comparison (lowercase, remove punctuation, compress whitespace)
    pub fn normalizeText(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
        var normalized = std.ArrayList(u8).init(allocator);
        var prev_was_space = true;
        
        for (text) |char| {
            if (std.ascii.isAlphanumeric(char)) {
                try normalized.append(std.ascii.toLower(char));
                prev_was_space = false;
            } else if (!prev_was_space and std.ascii.isWhitespace(char)) {
                try normalized.append(' ');
                prev_was_space = true;
            }
        }
        
        // Remove trailing space
        if (normalized.items.len > 0 and normalized.items[normalized.items.len - 1] == ' ') {
            _ = normalized.pop();
        }
        
        return try normalized.toOwnedSlice();
    }
    
    /// Check if text contains any of the provided keywords (case-insensitive)
    pub fn containsKeywords(allocator: std.mem.Allocator, text: []const u8, keywords: []const []const u8) bool {
        const lower_text = std.ascii.allocLowerString(allocator, text) catch return false;
        defer allocator.free(lower_text);
        
        for (keywords) |keyword| {
            const lower_keyword = std.ascii.allocLowerString(allocator, keyword) catch continue;
            defer allocator.free(lower_keyword);
            
            if (std.mem.indexOf(u8, lower_text, lower_keyword) != null) {
                return true;
            }
        }
        return false;
    }
    
    /// Calculate similarity between two texts using normalized edit distance
    pub fn calculateSimilarity(text1: []const u8, text2: []const u8) f32 {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        
        const normalized1 = normalizeText(allocator, text1) catch return 0.0;
        const normalized2 = normalizeText(allocator, text2) catch return 0.0;
        
        const edit_distance = calculateEditDistance(normalized1, normalized2);
        const max_len = @max(normalized1.len, normalized2.len);
        
        if (max_len == 0) return 1.0;
        return 1.0 - (@as(f32, @floatFromInt(edit_distance)) / @as(f32, @floatFromInt(max_len)));
    }
    
    /// Extract number from text near a keyword
    pub fn extractNumberNearKeyword(text: []const u8, keyword: []const u8) ?u32 {
        const keyword_pos = std.mem.indexOf(u8, text, keyword) orelse return null;
        
        // Look backwards from keyword to find the number
        var i = keyword_pos;
        while (i > 0) {
            i -= 1;
            if (std.ascii.isDigit(text[i])) {
                // Found a digit, find the start of the number
                var num_start = i;
                while (num_start > 0 and (std.ascii.isDigit(text[num_start - 1]) or text[num_start - 1] == ',')) {
                    num_start -= 1;
                }
                
                // Extract and parse the number, removing commas
                const num_str = text[num_start..i + 1];
                var clean_num = std.ArrayList(u8).init(std.heap.page_allocator);
                defer clean_num.deinit();
                
                for (num_str) |char| {
                    if (std.ascii.isDigit(char)) {
                        clean_num.append(char) catch continue;
                    }
                }
                
                if (clean_num.items.len > 0) {
                    return std.fmt.parseInt(u32, clean_num.items, 10) catch null;
                }
            }
        }
        return null;
    }
    
    /// Calculate edit distance using dynamic programming
    fn calculateEditDistance(str1: []const u8, str2: []const u8) usize {
        const len1 = str1.len;
        const len2 = str2.len;
        
        if (len1 == 0) return len2;
        if (len2 == 0) return len1;
        
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        
        const matrix = allocator.alloc([]usize, len1 + 1) catch {
            // Fallback to simple calculation on allocation failure
            var matches: usize = 0;
            const min_len = @min(len1, len2);
            for (0..min_len) |i| {
                if (str1[i] == str2[i]) matches += 1;
            }
            return @max(len1, len2) - matches;
        };
        
        for (matrix) |*row| {
            row.* = allocator.alloc(usize, len2 + 1) catch {
                var matches: usize = 0;
                const min_len = @min(len1, len2);
                for (0..min_len) |i| {
                    if (str1[i] == str2[i]) matches += 1;
                }
                return @max(len1, len2) - matches;
            };
        }
        
        // Initialize first row and column
        for (0..len1 + 1) |i| {
            matrix[i][0] = i;
        }
        for (0..len2 + 1) |j| {
            matrix[0][j] = j;
        }
        
        // Fill the matrix
        for (1..len1 + 1) |i| {
            for (1..len2 + 1) |j| {
                const cost: usize = if (str1[i - 1] == str2[j - 1]) 0 else 1;
                matrix[i][j] = @min(
                    @min(matrix[i - 1][j] + 1, matrix[i][j - 1] + 1),
                    matrix[i - 1][j - 1] + cost
                );
            }
        }
        
        return matrix[len1][len2];
    }
};

/// Memory management utilities for data-oriented design
pub const MemoryUtils = struct {
    /// Batch allocate multiple arrays of the same size
    pub fn batchAllocate(comptime T: type, allocator: std.mem.Allocator, count: usize, num_arrays: usize) ![][]T {
        var arrays = try allocator.alloc([]T, num_arrays);
        errdefer {
            for (arrays[0..]) |array| {
                if (array.len > 0) allocator.free(array);
            }
            allocator.free(arrays);
        }
        
        for (arrays) |*array| {
            array.* = try allocator.alloc(T, count);
        }
        
        return arrays;
    }
    
    /// Efficiently copy array slices with bounds checking
    pub fn safeCopySlice(comptime T: type, dest: []T, src: []const T) usize {
        const copy_len = @min(dest.len, src.len);
        @memcpy(dest[0..copy_len], src[0..copy_len]);
        return copy_len;
    }
};

/// Input validation utilities
pub const ValidationUtils = struct {
    /// Validate URL format and prevent injection
    pub fn isValidUrl(url: []const u8) bool {
        if (url.len == 0) return false;
        
        // Must start with http:// or https://
        if (!std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://")) {
            return false;
        }
        
        // Check for dangerous characters
        for (url) |c| {
            if (c == '\n' or c == '\r' or c == 0 or c == ';' or c == '`' or c == '$') {
                return false;
            }
        }
        
        return true;
    }
    
    /// Validate header name according to RFC 7230
    pub fn isValidHeaderName(name: []const u8) bool {
        if (name.len == 0) return false;
        
        for (name) |c| {
            if (c < 33 or c > 126) return false;
            if (c == '(' or c == ')' or c == '<' or c == '>' or c == '@' or
                c == ',' or c == ';' or c == ':' or c == '\\' or c == '"' or
                c == '/' or c == '[' or c == ']' or c == '?' or c == '=' or
                c == '{' or c == '}' or c == ' ' or c == '\t') {
                return false;
            }
        }
        return true;
    }
    
    /// Validate header value according to RFC 7230
    pub fn isValidHeaderValue(value: []const u8) bool {
        for (value) |c| {
            if ((c < 32 and c != '\t') or c == 127) return false;
            if (c == 0 or c == '\n' or c == '\r') return false;
        }
        return true;
    }
};