const std = @import("std");
const builtin = @import("builtin");
const http = @import("common_http.zig");
const claude = @import("ai_claude.zig");

/// MCP Protocol version
const MCP_VERSION = "2024-11-05";

/// MCP message types
pub const MessageType = enum {
    // Client to Server
    initialize,
    initialized,
    ping,
    
    // Resources
    resources_list,
    resources_read,
    resources_subscribe,
    resources_unsubscribe,
    
    // Tools
    tools_list,
    tools_call,
    
    // Prompts
    prompts_list,
    prompts_get,
    
    // Completions
    completion_complete,
    
    // Logging
    logging_setLevel,
    
    // Notifications
    notification_cancelled,
    notification_progress,
    notification_message,
    notification_resources_updated,
    notification_tools_updated,
    notification_prompts_updated,
    
    // Responses
    response,
    @"error",
};

/// MCP Client errors
pub const MCPError = error{
    ConnectionFailed,
    ProtocolError,
    AuthenticationFailed,
    InvalidMessage,
    ResourceNotFound,
    ToolNotFound,
    PromptNotFound,
    ExecutionFailed,
    TimeoutError,
    SerializationError,
};

/// Resource reference
pub const ResourceReference = struct {
    uri: []const u8,
    type: ?[]const u8 = null,
    
    pub fn deinit(self: ResourceReference, allocator: std.mem.Allocator) void {
        allocator.free(self.uri);
        if (self.type) |t| allocator.free(t);
    }
};

/// Tool parameter
pub const ToolParameter = struct {
    name: []const u8,
    value: std.json.Value,
    
    pub fn deinit(self: ToolParameter, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        // Note: std.json.Value cleanup handled by arena
    }
};

/// Resource content
pub const ResourceContent = struct {
    uri: []const u8,
    mimeType: ?[]const u8,
    text: ?[]const u8,
    blob: ?[]const u8,
    
    pub fn deinit(self: ResourceContent, allocator: std.mem.Allocator) void {
        allocator.free(self.uri);
        if (self.mimeType) |mime| allocator.free(mime);
        if (self.text) |text| allocator.free(text);
        if (self.blob) |blob| allocator.free(blob);
    }
};

/// Tool definition
pub const Tool = struct {
    name: []const u8,
    description: ?[]const u8,
    inputSchema: std.json.Value,
    
    pub fn deinit(self: Tool, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.description) |desc| allocator.free(desc);
        // inputSchema cleanup handled by arena
    }
};

/// Prompt definition
pub const Prompt = struct {
    name: []const u8,
    description: ?[]const u8,
    arguments: ?[]PromptArgument,
    
    pub fn deinit(self: Prompt, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.description) |desc| allocator.free(desc);
        if (self.arguments) |args| {
            for (args) |arg| arg.deinit(allocator);
            allocator.free(args);
        }
    }
};

/// Prompt argument
pub const PromptArgument = struct {
    name: []const u8,
    description: ?[]const u8,
    required: bool = false,
    
    pub fn deinit(self: PromptArgument, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.description) |desc| allocator.free(desc);
    }
};

/// Completion request
pub const CompletionRequest = struct {
    ref: ResourceReference,
    argument: ?ToolParameter,
    
    pub fn deinit(self: CompletionRequest, allocator: std.mem.Allocator) void {
        self.ref.deinit(allocator);
        if (self.argument) |arg| arg.deinit(allocator);
    }
};

/// MCP message structure
pub const MCPMessage = struct {
    jsonrpc: []const u8 = "2.0",
    id: ?std.json.Value = null,
    method: ?[]const u8 = null,
    params: ?std.json.Value = null,
    result: ?std.json.Value = null,
    @"error": ?MCPErrorInfo = null,
    
    pub fn deinit(self: MCPMessage, allocator: std.mem.Allocator) void {
        allocator.free(self.jsonrpc);
        if (self.method) |method| allocator.free(method);
        if (self.@"error") |err| err.deinit(allocator);
        // JSON values cleanup handled by arena
    }
};

/// MCP error information
pub const MCPErrorInfo = struct {
    code: i32,
    message: []const u8,
    data: ?std.json.Value = null,
    
    pub fn deinit(self: MCPErrorInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
        // data cleanup handled by arena
    }
};

/// Connection configuration for MCP client
pub const MCPConfig = struct {
    server_url: []const u8,
    client_name: []const u8 = "daily-ai-zig",
    client_version: []const u8 = "1.0.0",
    timeout_ms: u32 = 30000,
    max_retries: u8 = 3,
    
    // Capabilities
    experimental: bool = false,
    sampling: bool = true,
    roots: bool = true,
};

/// MCP Client implementation
pub const MCPClient = struct {
    allocator: std.mem.Allocator,
    http_client: *http.HttpClient,
    config: MCPConfig,
    claude_client: ?*claude.ClaudeClient,
    
    // Connection state
    connected: bool = false,
    initialized: bool = false,
    request_id: u64 = 1,
    
    // Cached capabilities
    server_capabilities: ?ServerCapabilities = null,
    available_resources: ?[]ResourceReference = null,
    available_tools: ?[]Tool = null,
    available_prompts: ?[]Prompt = null,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, http_client: *http.HttpClient, config: MCPConfig) Self {
        return Self{
            .allocator = allocator,
            .http_client = http_client,
            .config = config,
            .claude_client = null,
        };
    }
    
    pub fn deinit(self: *Self) void {
        if (self.server_capabilities) |caps| caps.deinit(self.allocator);
        if (self.available_resources) |resources| {
            for (resources) |resource| resource.deinit(self.allocator);
            self.allocator.free(resources);
        }
        if (self.available_tools) |tools| {
            for (tools) |tool| tool.deinit(self.allocator);
            self.allocator.free(tools);
        }
        if (self.available_prompts) |prompts| {
            for (prompts) |prompt| prompt.deinit(self.allocator);
            self.allocator.free(prompts);
        }
    }
    
    /// Connect and initialize MCP session
    pub fn connect(self: *Self) !void {
        std.log.info("🔌 Connecting to MCP server: {s}", .{self.config.server_url});
        
        // Send initialize request
        const init_params = try self.buildInitializeParams();
        const response = try self.sendRequest("initialize", init_params);
        defer response.deinit(self.allocator);
        
        if (response.@"error" != null) {
            std.log.err("MCP initialization failed: {s}", .{response.@"error".?.message});
            return MCPError.AuthenticationFailed;
        }
        
        // Parse server capabilities
        if (response.result) |result| {
            self.server_capabilities = try self.parseServerCapabilities(result);
        }
        
        // Send initialized notification
        try self.sendNotification("notifications/initialized", null);
        
        self.connected = true;
        self.initialized = true;
        
        std.log.info("✅ MCP client connected and initialized");
        
        // Cache available resources, tools, and prompts
        try self.refreshCapabilities();
    }
    
    /// Set Claude client for AI-powered operations
    pub fn setClaudeClient(self: *Self, client: *claude.ClaudeClient) void {
        self.claude_client = client;
    }
    
    /// List available resources
    pub fn listResources(self: *Self) ![]ResourceReference {
        if (!self.initialized) return MCPError.ConnectionFailed;
        
        const response = try self.sendRequest("resources/list", null);
        defer response.deinit(self.allocator);
        
        if (response.@"error" != null) {
            return MCPError.ResourceNotFound;
        }
        
        return try self.parseResourceList(response.result.?);
    }
    
    /// Read resource content
    pub fn readResource(self: *Self, uri: []const u8) !ResourceContent {
        if (!self.initialized) return MCPError.ConnectionFailed;
        
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const temp_allocator = arena.allocator();
        
        const params = try std.json.stringifyAlloc(temp_allocator, .{ .uri = uri }, .{});
        const parsed_params = try std.json.parseFromSlice(std.json.Value, temp_allocator, params, .{});
        
        const response = try self.sendRequest("resources/read", parsed_params.value);
        defer response.deinit(self.allocator);
        
        if (response.@"error" != null) {
            return MCPError.ResourceNotFound;
        }
        
        return try self.parseResourceContent(response.result.?);
    }
    
    /// List available tools
    pub fn listTools(self: *Self) ![]Tool {
        if (!self.initialized) return MCPError.ConnectionFailed;
        
        const response = try self.sendRequest("tools/list", null);
        defer response.deinit(self.allocator);
        
        if (response.@"error" != null) {
            return MCPError.ToolNotFound;
        }
        
        return try self.parseToolList(response.result.?);
    }
    
    /// Call a tool
    pub fn callTool(self: *Self, tool_name: []const u8, arguments: []ToolParameter) !std.json.Value {
        if (!self.initialized) return MCPError.ConnectionFailed;
        
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const temp_allocator = arena.allocator();
        
        // Build tool call parameters
        var params_obj = std.json.ObjectMap.init(temp_allocator);
        try params_obj.put("name", .{ .string = tool_name });
        
        var args_obj = std.json.ObjectMap.init(temp_allocator);
        for (arguments) |arg| {
            try args_obj.put(arg.name, arg.value);
        }
        try params_obj.put("arguments", .{ .object = args_obj });
        
        const params = std.json.Value{ .object = params_obj };
        const response = try self.sendRequest("tools/call", params);
        defer response.deinit(self.allocator);
        
        if (response.@"error" != null) {
            std.log.err("Tool call failed: {s}", .{response.@"error".?.message});
            return MCPError.ExecutionFailed;
        }
        
        return response.result.?; // Caller owns this value
    }
    
    /// Get available prompts
    pub fn listPrompts(self: *Self) ![]Prompt {
        if (!self.initialized) return MCPError.ConnectionFailed;
        
        const response = try self.sendRequest("prompts/list", null);
        defer response.deinit(self.allocator);
        
        if (response.@"error" != null) {
            return MCPError.PromptNotFound;
        }
        
        return try self.parsePromptList(response.result.?);
    }
    
    /// Get a prompt template
    pub fn getPrompt(self: *Self, prompt_name: []const u8, arguments: ?[]ToolParameter) ![]const u8 {
        if (!self.initialized) return MCPError.ConnectionFailed;
        
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const temp_allocator = arena.allocator();
        
        var params_obj = std.json.ObjectMap.init(temp_allocator);
        try params_obj.put("name", .{ .string = prompt_name });
        
        if (arguments) |args| {
            var args_obj = std.json.ObjectMap.init(temp_allocator);
            for (args) |arg| {
                try args_obj.put(arg.name, arg.value);
            }
            try params_obj.put("arguments", .{ .object = args_obj });
        }
        
        const params = std.json.Value{ .object = params_obj };
        const response = try self.sendRequest("prompts/get", params);
        defer response.deinit(self.allocator);
        
        if (response.@"error" != null) {
            return MCPError.PromptNotFound;
        }
        
        return try self.parsePromptContent(response.result.?);
    }
    
    /// AI-powered completion using LLM backend
    pub fn completeWithAI(self: *Self, context: []const u8, completion_request: CompletionRequest) ![]const u8 {
        if (self.claude_client == null) {
            std.log.warn("No LLM backend available for AI completion");
            return try self.allocator.dupe(u8, context); // Fallback: return original context
        }
        
        // Read resource for context
        const resource_content = try self.readResource(completion_request.ref.uri);
        defer resource_content.deinit(self.allocator);
        
        // Build completion prompt
        const completion_prompt = try std.fmt.allocPrint(self.allocator, 
            \\Context: {s}
            \\
            \\Resource: {s}
            \\Content: {s}
            \\
            \\Complete this text with relevant information:
        , .{ context, completion_request.ref.uri, resource_content.text orelse "" });
        defer self.allocator.free(completion_prompt);
        
        // Generate completion using Claude
        const completion = try self.claude_client.?.executeClaude(completion_prompt);
        
        std.log.info("🤖 AI completion generated ({d} chars)", .{completion.len});
        return completion;
    }
    
    // Private implementation methods
    fn buildInitializeParams(self: *Self) !std.json.Value {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const temp_allocator = arena.allocator();
        
        var params_obj = std.json.ObjectMap.init(temp_allocator);
        try params_obj.put("protocolVersion", .{ .string = MCP_VERSION });
        
        var capabilities_obj = std.json.ObjectMap.init(temp_allocator);
        try capabilities_obj.put("experimental", .{ .bool = self.config.experimental });
        try capabilities_obj.put("sampling", .{ .bool = self.config.sampling });
        try capabilities_obj.put("roots", .{ .bool = self.config.roots });
        try params_obj.put("capabilities", .{ .object = capabilities_obj });
        
        var client_info_obj = std.json.ObjectMap.init(temp_allocator);
        try client_info_obj.put("name", .{ .string = self.config.client_name });
        try client_info_obj.put("version", .{ .string = self.config.client_version });
        try params_obj.put("clientInfo", .{ .object = client_info_obj });
        
        return std.json.Value{ .object = params_obj };
    }
    
    fn sendRequest(self: *Self, method: []const u8, params: ?std.json.Value) !MCPMessage {
        const request_id = self.request_id;
        self.request_id += 1;
        
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const temp_allocator = arena.allocator();
        
        var message_obj = std.json.ObjectMap.init(temp_allocator);
        try message_obj.put("jsonrpc", .{ .string = "2.0" });
        try message_obj.put("id", .{ .integer = @intCast(request_id) });
        try message_obj.put("method", .{ .string = method });
        
        if (params) |p| {
            try message_obj.put("params", p);
        }
        
        const message = std.json.Value{ .object = message_obj };
        const json_request = try std.json.stringifyAlloc(temp_allocator, message, .{});
        
        // Send HTTP request to MCP server
        var headers = std.ArrayList(http.Header).init(temp_allocator);
        try headers.append(http.Header{
            .name = "Content-Type",
            .value = "application/json",
        });
        
        const response = try self.http_client.post(self.config.server_url, json_request, headers.items);
        defer response.deinit(self.allocator);
        
        if (response.status_code != 200) {
            return MCPError.ProtocolError;
        }
        
        // Parse JSON response
        const parsed = try std.json.parseFromSlice(MCPMessage, self.allocator, response.body, .{});
        return parsed.value;
    }
    
    fn sendNotification(self: *Self, method: []const u8, params: ?std.json.Value) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const temp_allocator = arena.allocator();
        
        var message_obj = std.json.ObjectMap.init(temp_allocator);
        try message_obj.put("jsonrpc", .{ .string = "2.0" });
        try message_obj.put("method", .{ .string = method });
        
        if (params) |p| {
            try message_obj.put("params", p);
        }
        
        const message = std.json.Value{ .object = message_obj };
        const json_request = try std.json.stringifyAlloc(temp_allocator, message, .{});
        
        var headers = std.ArrayList(http.Header).init(temp_allocator);
        try headers.append(http.Header{
            .name = "Content-Type",
            .value = "application/json",
        });
        
        const response = try self.http_client.post(self.config.server_url, json_request, headers.items);
        defer response.deinit(self.allocator);
        
        // Notifications don't expect responses
    }
    
    fn refreshCapabilities(self: *Self) !void {
        // Cache available resources
        if (self.available_resources) |resources| {
            for (resources) |resource| resource.deinit(self.allocator);
            self.allocator.free(resources);
        }
        self.available_resources = self.listResources() catch null;
        
        // Cache available tools
        if (self.available_tools) |tools| {
            for (tools) |tool| tool.deinit(self.allocator);
            self.allocator.free(tools);
        }
        self.available_tools = self.listTools() catch null;
        
        // Cache available prompts
        if (self.available_prompts) |prompts| {
            for (prompts) |prompt| prompt.deinit(self.allocator);
            self.allocator.free(prompts);
        }
        self.available_prompts = self.listPrompts() catch null;
        
        std.log.info("📋 MCP capabilities cached: {d} resources, {d} tools, {d} prompts", .{
            if (self.available_resources) |r| r.len else 0,
            if (self.available_tools) |t| t.len else 0,
            if (self.available_prompts) |p| p.len else 0,
        });
    }
    
    // Parsing methods (simplified implementations)
    fn parseServerCapabilities(self: *Self, result: std.json.Value) !ServerCapabilities {
        _ = self;
        _ = result;
        // Simplified - would parse actual server capabilities
        return ServerCapabilities{
            .experimental = false,
            .sampling = true,
            .roots = true,
        };
    }
    
    fn parseResourceList(self: *Self, result: std.json.Value) ![]ResourceReference {
        _ = self;
        _ = result;
        // Simplified - would parse actual resource list
        return &[_]ResourceReference{};
    }
    
    fn parseResourceContent(self: *Self, result: std.json.Value) !ResourceContent {
        _ = result;
        return ResourceContent{
            .uri = try self.allocator.dupe(u8, "example://resource"),
            .mimeType = try self.allocator.dupe(u8, "text/plain"),
            .text = try self.allocator.dupe(u8, "Example content"),
            .blob = null,
        };
    }
    
    fn parseToolList(self: *Self, result: std.json.Value) ![]Tool {
        _ = self;
        _ = result;
        // Simplified - would parse actual tool list
        return &[_]Tool{};
    }
    
    fn parsePromptList(self: *Self, result: std.json.Value) ![]Prompt {
        _ = self;
        _ = result;
        // Simplified - would parse actual prompt list
        return &[_]Prompt{};
    }
    
    fn parsePromptContent(self: *Self, result: std.json.Value) ![]const u8 {
        _ = result;
        return try self.allocator.dupe(u8, "Example prompt content");
    }
};

/// Server capabilities
const ServerCapabilities = struct {
    experimental: bool,
    sampling: bool,
    roots: bool,
    
    fn deinit(self: ServerCapabilities, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
    }
};

/// Create MCP client with default configuration
pub fn createMCPClient(allocator: std.mem.Allocator, http_client: *http.HttpClient, server_url: []const u8) !MCPClient {
    const config = MCPConfig{
        .server_url = server_url,
        .client_name = "daily-ai-zig",
        .client_version = "1.0.0",
    };
    
    return MCPClient.init(allocator, http_client, config);
}

// Test function
test "MCP client initialization" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var http_client = try http.HttpClient.init(allocator);
    defer http_client.deinit();
    
    var mcp_client = try createMCPClient(allocator, &http_client, "http://localhost:3000/mcp");
    defer mcp_client.deinit();
    
    try std.testing.expect(!mcp_client.connected);
    try std.testing.expect(!mcp_client.initialized);
}