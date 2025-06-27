const std = @import("std");
const yazap = @import("yazap");
const config = @import("core_config.zig");
const types = @import("core_types.zig");

const App = yazap.App;
const Arg = yazap.Arg;

pub const CliConfig = struct {
    output_dir: []const u8,
    claude_model: []const u8,
    verbose: bool,
    sources: SourceFilter,
    
    pub const SourceFilter = struct {
        reddit: bool = true,
        youtube: bool = true,
        tiktok: bool = true,
        research: bool = true,
        blogs: bool = true,
        news: bool = true,
        rss: bool = true,
        github: bool = true,
        
        pub fn isEnabled(self: SourceFilter, source_type: types.SourceType) bool {
            const info = source_type.getInfo();
            if (std.mem.eql(u8, info.name, "reddit")) return self.reddit;
            if (std.mem.eql(u8, info.name, "youtube")) return self.youtube;
            if (std.mem.eql(u8, info.name, "tiktok")) return self.tiktok;
            if (std.mem.eql(u8, info.name, "research")) return self.research;
            if (std.mem.eql(u8, info.name, "blogs")) return self.blogs;
            if (std.mem.eql(u8, info.name, "news")) return self.news;
            if (std.mem.eql(u8, info.name, "rss")) return self.rss;
            if (std.mem.eql(u8, info.name, "github")) return self.github;
            return false;
        }
    };
    
    pub fn deinit(self: CliConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.output_dir);
        allocator.free(self.claude_model);
    }
};

pub fn parseArgs(allocator: std.mem.Allocator) anyerror!CliConfig {
    // Create arena allocator for temporary CLI parsing strings
    var cli_arena = std.heap.ArenaAllocator.init(allocator);
    defer cli_arena.deinit();
    const temp_allocator = cli_arena.allocator();
    
    var app = App.init(temp_allocator, "daily_ai", "AI News Generator - Scrape and curate AI news from multiple sources");
    defer app.deinit();
    
    var root_cmd = app.rootCommand();
    
    // Output directory option
    try root_cmd.addArg(Arg.singleValueOption("output", 'o', "Output directory for generated files (default: ./output)"));
    
    // Claude model option
    try root_cmd.addArg(Arg.singleValueOption("model", 'm', "Claude model to use (default: sonnet)"));
    
    // Verbose output
    try root_cmd.addArg(Arg.booleanOption("verbose", 'v', "Enable verbose output"));
    
    // Auto-generate source filter arguments from SourceType enum
    const all_source_types = types.SourceType.getAllSourceTypes();
    for (all_source_types) |source_type| {
        const info = source_type.getInfo();
        
        // "no-" flags (using temp allocator)
        const no_flag = try std.fmt.allocPrint(temp_allocator, "no-{s}", .{info.cli_flag});
        const no_desc = try std.fmt.allocPrint(temp_allocator, "Skip {s}", .{info.description});
        try root_cmd.addArg(Arg.booleanOption(no_flag, null, no_desc));
        
        // "-only" flags (using temp allocator)
        const only_flag = try std.fmt.allocPrint(temp_allocator, "{s}-only", .{info.cli_flag});
        const only_desc = try std.fmt.allocPrint(temp_allocator, "Only process {s}", .{info.description});
        try root_cmd.addArg(Arg.booleanOption(only_flag, null, only_desc));
    }
    
    // Note: Local LLM options removed to simplify system
    
    const matches = app.parseProcess() catch |err| {
        if (err == error.HelpShown) {
            return error.ShowHelpAndExit;
        }
        return err;
    };
    
    // Get output directory
    const output_dir = if (matches.getSingleValue("output")) |output|
        try allocator.dupe(u8, output)
    else
        try allocator.dupe(u8, "./output");
    
    // Get Claude model
    const claude_model = if (matches.getSingleValue("model")) |model|
        try allocator.dupe(u8, model)
    else
        try allocator.dupe(u8, "sonnet");
    
    // Get verbose flag
    const verbose = matches.containsArg("verbose");
    
    // Determine source filters using auto-generated logic
    var sources = CliConfig.SourceFilter{};
    
    // Check for "only" flags first - if any are set, disable all others
    var only_flag_found = false;
    
    for (all_source_types) |source_type| {
        const info = source_type.getInfo();
        const only_flag = try std.fmt.allocPrint(allocator, "{s}-only", .{info.cli_flag});
        defer allocator.free(only_flag);
        
        if (matches.containsArg(only_flag)) {
            // Disable all sources first
            sources = .{ .reddit = false, .youtube = false, .tiktok = false, .research = false, .blogs = false, .news = false, .rss = false, .github = false };
            
            // Enable only the specified source
            if (std.mem.eql(u8, info.name, "reddit")) sources.reddit = true;
            if (std.mem.eql(u8, info.name, "youtube")) sources.youtube = true;
            if (std.mem.eql(u8, info.name, "tiktok")) sources.tiktok = true;
            if (std.mem.eql(u8, info.name, "research")) sources.research = true;
            if (std.mem.eql(u8, info.name, "blogs")) sources.blogs = true;
            if (std.mem.eql(u8, info.name, "news")) sources.news = true;
            if (std.mem.eql(u8, info.name, "rss")) sources.rss = true;
            if (std.mem.eql(u8, info.name, "github")) sources.github = true;
            
            only_flag_found = true;
            break;
        }
    }
    
    // If no "only" flag was found, apply "no-" flags to disable specific sources
    if (!only_flag_found) {
        for (all_source_types) |source_type| {
            const info = source_type.getInfo();
            const no_flag = try std.fmt.allocPrint(allocator, "no-{s}", .{info.cli_flag});
            defer allocator.free(no_flag);
            
            if (matches.containsArg(no_flag)) {
                if (std.mem.eql(u8, info.name, "reddit")) sources.reddit = false;
                if (std.mem.eql(u8, info.name, "youtube")) sources.youtube = false;
                if (std.mem.eql(u8, info.name, "tiktok")) sources.tiktok = false;
                if (std.mem.eql(u8, info.name, "research")) sources.research = false;
                if (std.mem.eql(u8, info.name, "blogs")) sources.blogs = false;
                if (std.mem.eql(u8, info.name, "news")) sources.news = false;
                if (std.mem.eql(u8, info.name, "rss")) sources.rss = false;
                if (std.mem.eql(u8, info.name, "github")) sources.github = false;
            }
        }
    }
    
    // Note: LLM configuration parsing removed to simplify system
    
    return CliConfig{
        .output_dir = output_dir,
        .claude_model = claude_model,
        .verbose = verbose,
        .sources = sources,
    };
}

pub fn printUsage(allocator: std.mem.Allocator) !void {
    var app = App.init(allocator, "daily_ai", "AI News Generator - Scrape and curate AI news from multiple sources");
    defer app.deinit();
    
    // Add the same arguments as above for help generation
    var root_cmd = app.rootCommand();
    try root_cmd.addArg(Arg.singleValueOption("output", 'o', "Output directory for generated files (default: ./output)"));
    try root_cmd.addArg(Arg.singleValueOption("model", 'm', "Claude model to use (default: sonnet)"));
    try root_cmd.addArg(Arg.booleanOption("verbose", 'v', "Enable verbose output"));
    
    // Auto-generate source filter arguments for help
    const all_source_types = types.SourceType.getAllSourceTypes();
    for (all_source_types) |source_type| {
        const info = source_type.getInfo();
        
        // "no-" flags
        const no_flag = try std.fmt.allocPrint(allocator, "no-{s}", .{info.cli_flag});
        const no_desc = try std.fmt.allocPrint(allocator, "Skip {s}", .{info.description});
        try root_cmd.addArg(Arg.booleanOption(no_flag, null, no_desc));
        
        // "-only" flags
        const only_flag = try std.fmt.allocPrint(allocator, "{s}-only", .{info.cli_flag});
        const only_desc = try std.fmt.allocPrint(allocator, "Only process {s}", .{info.description});
        try root_cmd.addArg(Arg.booleanOption(only_flag, null, only_desc));
    }
    
    // Note: Local LLM options removed to simplify system
    
    try app.displayHelp();
}

test "CLI argument parsing" {
    const allocator = std.testing.allocator;
    
    // This would require setting up mock command line arguments
    // For now, we'll just test that the CLI module compiles
    _ = allocator;
}