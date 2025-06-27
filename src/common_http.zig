const std = @import("std");
const types = @import("core_types.zig");
const utils = @import("core_utils.zig");

pub const HttpClient = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !HttpClient {
        return HttpClient{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *HttpClient) void {
        _ = self;
    }

    pub fn makeRequest(self: *HttpClient, request: types.HttpRequest) !types.HttpResponse {
        // Build curl command arguments
        var curl_args = std.ArrayList([]const u8).init(self.allocator);
        defer curl_args.deinit();

        try curl_args.append("curl");
        try curl_args.append("-s"); // Silent mode
        try curl_args.append("-L"); // Follow redirects
        try curl_args.append("-w"); // Write format string
        try curl_args.append("HTTP_STATUS:%{http_code}\\nCONTENT_TYPE:%{content_type}\\n");

        // Add method
        const method_str = switch (request.method) {
            .GET => "GET",
            .POST => "POST",
            .PUT => "PUT",
            .DELETE => "DELETE",
        };
        try curl_args.append("-X");
        try curl_args.append(method_str);

        // Add headers with proper validation
        for (request.headers) |header| {
            // Validate header name and value to prevent injection
            if (!utils.ValidationUtils.isValidHeaderName(header.name) or !utils.ValidationUtils.isValidHeaderValue(header.value)) {
                utils.ErrorUtils.logWarning("HTTP Client", "Skipping invalid header");
                continue;
            }
            
            const header_str = try std.fmt.allocPrint(self.allocator, "{s}: {s}", .{ header.name, header.value });
            defer self.allocator.free(header_str);
            try curl_args.append("-H");
            try curl_args.append(try self.allocator.dupe(u8, header_str));
        }

        // Add body if POST/PUT
        if (request.body) |body| {
            try curl_args.append("-d");
            try curl_args.append(body);
        }

        // Add URL with validation
        if (!utils.ValidationUtils.isValidUrl(request.url)) {
            utils.ErrorUtils.logError("HTTP Client", types.AppError.HttpError, "Invalid URL provided");
            return types.AppError.HttpError;
        }
        try curl_args.append(request.url);

        // Execute curl command
        var child = std.process.Child.init(curl_args.items, self.allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        try child.spawn();

        const stdout = child.stdout.?.readToEndAlloc(self.allocator, 10 * 1024 * 1024) catch |err| {
            std.log.err("Failed to read curl stdout: {}", .{err});
            return types.AppError.HttpError;
        };
        defer self.allocator.free(stdout);

        const stderr = child.stderr.?.readToEndAlloc(self.allocator, 1024 * 1024) catch |err| {
            std.log.err("Failed to read curl stderr: {}", .{err});
            self.allocator.free(stdout);
            return types.AppError.HttpError;
        };
        defer self.allocator.free(stderr);

        const exit_code = child.wait() catch |err| {
            std.log.err("Failed to wait for curl process: {}", .{err});
            return types.AppError.HttpError;
        };

        // Free allocated header strings
        var i: usize = 0;
        while (i < curl_args.items.len) : (i += 1) {
            const arg = curl_args.items[i];
            if (std.mem.eql(u8, arg, "-H") and i + 1 < curl_args.items.len) {
                // Next item is a header string we allocated
                i += 1;
                self.allocator.free(curl_args.items[i]);
            }
        }

        if (exit_code != .Exited or exit_code.Exited != 0) {
            std.log.err("Curl command failed with exit code: {}", .{exit_code});
            std.log.err("Stderr: {s}", .{stderr});
            return types.AppError.HttpError;
        }

        // Parse curl output
        return try parseCurlResponse(self.allocator, stdout);
    }
    

    pub fn get(self: *HttpClient, url: []const u8, headers: []types.HttpRequest.Header) !types.HttpResponse {
        const request = types.HttpRequest{
            .method = .GET,
            .url = try self.allocator.dupe(u8, url),
            .headers = try self.allocator.dupe(types.HttpRequest.Header, headers),
            .body = null,
        };
        defer request.deinit(self.allocator);

        return try self.makeRequest(request);
    }

    pub fn post(self: *HttpClient, url: []const u8, headers: []types.HttpRequest.Header, body: []const u8) !types.HttpResponse {
        const request = types.HttpRequest{
            .method = .POST,
            .url = url,
            .headers = headers,
            .body = body,
        };

        return try self.makeRequest(request);
    }
};

const ParsedUrl = struct {
    scheme: []const u8,
    host: []const u8,
    port: u16,
    path: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: ParsedUrl) void {
        self.allocator.free(self.scheme);
        self.allocator.free(self.host);
        self.allocator.free(self.path);
    }
};

fn parseUrl(allocator: std.mem.Allocator, url: []const u8) !ParsedUrl {
    // Simple URL parsing - assumes https:// format
    if (url.len == 0) {
        std.log.err("Empty URL provided", .{});
        return types.AppError.InvalidInput;
    }

    if (!std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://")) {
        std.log.err("Invalid URL scheme. Must start with http:// or https://", .{});
        return types.AppError.InvalidInput;
    }

    const is_https = std.mem.startsWith(u8, url, "https://");
    const scheme_end: usize = if (is_https) 8 else 7;
    const default_port: u16 = if (is_https) 443 else 80;

    const rest = url[scheme_end..];
    const path_start = std.mem.indexOf(u8, rest, "/") orelse rest.len;
    const host_port = rest[0..path_start];
    const path = if (path_start < rest.len) rest[path_start..] else "/";

    // Check for port in host
    var host: []const u8 = host_port;
    var port: u16 = default_port;

    if (std.mem.indexOf(u8, host_port, ":")) |colon_pos| {
        host = host_port[0..colon_pos];
        const port_str = host_port[colon_pos + 1 ..];
        port = std.fmt.parseInt(u16, port_str, 10) catch default_port;
    }

    return ParsedUrl{
        .scheme = try allocator.dupe(u8, if (is_https) "https" else "http"),
        .host = try allocator.dupe(u8, host),
        .port = port,
        .path = try allocator.dupe(u8, path),
        .allocator = allocator,
    };
}

fn buildHttpRequest(allocator: std.mem.Allocator, request: types.HttpRequest, path: []const u8) ![]const u8 {
    var request_lines = std.ArrayList([]const u8).init(allocator);
    defer {
        for (request_lines.items) |line| {
            allocator.free(line);
        }
        request_lines.deinit();
    }

    // Request line
    const method_str = switch (request.method) {
        .GET => "GET",
        .POST => "POST",
        .PUT => "PUT",
        .DELETE => "DELETE",
    };

    const request_line = try std.fmt.allocPrint(allocator, "{s} {s} HTTP/1.1", .{ method_str, path });
    try request_lines.append(request_line);

    // Headers
    for (request.headers) |header| {
        const header_line = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ header.name, header.value });
        try request_lines.append(header_line);
    }

    // Add required headers if not present
    var has_host = false;
    var has_user_agent = false;
    var has_content_length = false;

    for (request.headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "host")) has_host = true;
        if (std.ascii.eqlIgnoreCase(header.name, "user-agent")) has_user_agent = true;
        if (std.ascii.eqlIgnoreCase(header.name, "content-length")) has_content_length = true;
    }

    if (!has_user_agent) {
        const ua_line = try allocator.dupe(u8, "User-Agent: AI-News-Generator/1.0");
        try request_lines.append(ua_line);
    }

    if (request.body != null and !has_content_length) {
        const content_length = try std.fmt.allocPrint(allocator, "Content-Length: {d}", .{request.body.?.len});
        try request_lines.append(content_length);
    }

    // Connection header
    const connection_line = try allocator.dupe(u8, "Connection: close");
    try request_lines.append(connection_line);

    // Empty line before body
    const empty_line = try allocator.dupe(u8, "");
    try request_lines.append(empty_line);

    // Join all lines
    const joined = try std.mem.join(allocator, "\r\n", request_lines.items);

    // Add body if present
    if (request.body) |body| {
        const with_body = try std.fmt.allocPrint(allocator, "{s}{s}", .{ joined, body });
        allocator.free(joined);
        return with_body;
    }

    return joined;
}

fn parseCurlResponse(allocator: std.mem.Allocator, curl_output: []const u8) !types.HttpResponse {
    // Find the status info which curl appends at the END
    var status_code: u16 = 200;
    var content_type: ?[]const u8 = null;

    // Look for the status markers at the end of the output
    if (std.mem.indexOf(u8, curl_output, "HTTP_STATUS:")) |status_pos| {
        const status_line_end = std.mem.indexOf(u8, curl_output[status_pos..], "\n") orelse
            std.mem.indexOf(u8, curl_output[status_pos..], "CONTENT_TYPE:") orelse
            (curl_output.len - status_pos);

        const status_str = curl_output[status_pos + 12 .. status_pos + status_line_end]; // Skip "HTTP_STATUS:"
        status_code = std.fmt.parseInt(u16, status_str, 10) catch 200;
    }

    if (std.mem.indexOf(u8, curl_output, "CONTENT_TYPE:")) |ct_pos| {
        const ct_start = ct_pos + 13; // Skip "CONTENT_TYPE:"
        const ct_end = std.mem.indexOf(u8, curl_output[ct_start..], "\n") orelse (curl_output.len - ct_start);

        if (ct_end > 0) {
            const content_type_str = curl_output[ct_start .. ct_start + ct_end];
            content_type = try allocator.dupe(u8, content_type_str);
        }
    }

    // Extract the body (everything before the status lines)
    var body_end: usize = curl_output.len;

    // Find where the status info starts and cut it off
    if (std.mem.indexOf(u8, curl_output, "HTTP_STATUS:")) |status_pos| {
        body_end = status_pos;
    }

    const body_content = try allocator.dupe(u8, curl_output[0..body_end]);

    // Create minimal headers
    var headers = std.ArrayList(types.HttpRequest.Header).init(allocator);
    if (content_type) |ct| {
        try headers.append(.{ .name = try allocator.dupe(u8, "Content-Type"), .value = ct });
    }

    return types.HttpResponse{
        .status_code = status_code,
        .headers = try headers.toOwnedSlice(),
        .body = body_content,
    };
}

// Helper function to create common headers
pub fn createHeaders(allocator: std.mem.Allocator, headers_map: []const struct { []const u8, []const u8 }) ![]types.HttpRequest.Header {
    var headers = std.ArrayList(types.HttpRequest.Header).init(allocator);

    for (headers_map) |header_pair| {
        try headers.append(.{
            .name = try allocator.dupe(u8, header_pair[0]),
            .value = try allocator.dupe(u8, header_pair[1]),
        });
    }

    return try headers.toOwnedSlice();
}

// Test function
test "HTTP client basic functionality" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = try HttpClient.init(allocator);
    defer client.deinit();

    // This would require a running HTTP server to test properly
    // For now, just test URL parsing
    const parsed = try parseUrl(allocator, "https://example.com:8080/path/to/resource");
    defer parsed.deinit();

    try std.testing.expect(std.mem.eql(u8, parsed.scheme, "https"));
    try std.testing.expect(std.mem.eql(u8, parsed.host, "example.com"));
    try std.testing.expect(parsed.port == 8080);
    try std.testing.expect(std.mem.eql(u8, parsed.path, "/path/to/resource"));
}
