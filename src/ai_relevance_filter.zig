const std = @import("std");

/// Centralized AI relevance filtering system
/// Consolidates keyword matching logic that was duplicated across all extractors
pub const AIRelevanceFilter = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    // Consolidated AI keywords with scoring weights
    const HIGH_VALUE_KEYWORDS = [_][]const u8{
        "GPT", "Claude", "OpenAI", "Anthropic", "ChatGPT", "Bard", "Gemini",
        "transformer", "attention mechanism", "neural architecture",
        "large language model", "LLM", "foundation model",
        "AGI", "artificial general intelligence",
        "reinforcement learning from human feedback", "RLHF",
        "constitutional AI", "AI safety", "alignment",
    };

    const MEDIUM_VALUE_KEYWORDS = [_][]const u8{
        "AI", "artificial intelligence", "machine learning", "ML", "deep learning",
        "neural network", "neural net", "CNN", "RNN", "LSTM", "GRU",
        "computer vision", "natural language processing", "NLP",
        "generative AI", "diffusion model", "autoregressive",
        "fine-tuning", "pre-training", "training", "inference",
        "embeddings", "vector database", "RAG", "retrieval augmented",
        "AI model", "AI system", "AI research", "AI development",
        "prompt engineering", "few-shot", "zero-shot", "in-context learning",
        "multimodal", "vision-language", "text-to-image", "text-to-speech",
    };

    const LOW_VALUE_KEYWORDS = [_][]const u8{
        "algorithm", "data science", "analytics", "automation",
        "prediction", "classification", "regression", "clustering",
        "supervised", "unsupervised", "reinforcement learning",
        "gradient descent", "backpropagation", "optimization",
        "feature engineering", "model evaluation", "cross-validation",
        "overfitting", "underfitting", "bias", "variance",
        "pytorch", "tensorflow", "hugging face", "keras",
        "jupyter", "pandas", "numpy", "scikit-learn",
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    /// Check if content is AI-related using comprehensive keyword matching
    pub fn isAIRelated(self: *Self, title: []const u8, content: []const u8) bool {
        _ = self;
        
        // Convert to lowercase for case-insensitive matching
        const title_lower = std.ascii.allocLowerString(std.heap.page_allocator, title) catch return false;
        defer std.heap.page_allocator.free(title_lower);
        
        const content_lower = std.ascii.allocLowerString(std.heap.page_allocator, content) catch return false;
        defer std.heap.page_allocator.free(content_lower);

        // Check high-value keywords first (more restrictive)
        for (HIGH_VALUE_KEYWORDS) |keyword| {
            const keyword_lower = std.ascii.allocLowerString(std.heap.page_allocator, keyword) catch continue;
            defer std.heap.page_allocator.free(keyword_lower);
            
            if (std.mem.indexOf(u8, title_lower, keyword_lower) != null or
                std.mem.indexOf(u8, content_lower, keyword_lower) != null) {
                return true;
            }
        }

        // Check medium-value keywords with additional context validation
        var medium_matches: u32 = 0;
        for (MEDIUM_VALUE_KEYWORDS) |keyword| {
            const keyword_lower = std.ascii.allocLowerString(std.heap.page_allocator, keyword) catch continue;
            defer std.heap.page_allocator.free(keyword_lower);
            
            if (std.mem.indexOf(u8, title_lower, keyword_lower) != null or
                std.mem.indexOf(u8, content_lower, keyword_lower) != null) {
                medium_matches += 1;
                if (medium_matches >= 2) return true; // Require multiple medium-value matches
            }
        }

        // Check low-value keywords with stricter requirements
        var low_matches: u32 = 0;
        for (LOW_VALUE_KEYWORDS) |keyword| {
            const keyword_lower = std.ascii.allocLowerString(std.heap.page_allocator, keyword) catch continue;
            defer std.heap.page_allocator.free(keyword_lower);
            
            if (std.mem.indexOf(u8, title_lower, keyword_lower) != null) {
                low_matches += 1;
                if (low_matches >= 3) return true; // Require multiple low-value matches in title
            }
        }

        return false;
    }

    /// Calculate a relevance score from 0.0 to 1.0
    pub fn calculateRelevanceScore(self: *Self, title: []const u8, content: []const u8) f32 {
        _ = self;
        
        const title_lower = std.ascii.allocLowerString(std.heap.page_allocator, title) catch return 0.0;
        defer std.heap.page_allocator.free(title_lower);
        
        const content_lower = std.ascii.allocLowerString(std.heap.page_allocator, content) catch return 0.0;
        defer std.heap.page_allocator.free(content_lower);

        var score: f32 = 0.0;

        // High-value keywords contribute 0.3 each
        for (HIGH_VALUE_KEYWORDS) |keyword| {
            const keyword_lower = std.ascii.allocLowerString(std.heap.page_allocator, keyword) catch continue;
            defer std.heap.page_allocator.free(keyword_lower);
            
            if (std.mem.indexOf(u8, title_lower, keyword_lower) != null) {
                score += 0.4; // Title matches are more valuable
            } else if (std.mem.indexOf(u8, content_lower, keyword_lower) != null) {
                score += 0.3;
            }
        }

        // Medium-value keywords contribute 0.1 each
        for (MEDIUM_VALUE_KEYWORDS) |keyword| {
            const keyword_lower = std.ascii.allocLowerString(std.heap.page_allocator, keyword) catch continue;
            defer std.heap.page_allocator.free(keyword_lower);
            
            if (std.mem.indexOf(u8, title_lower, keyword_lower) != null) {
                score += 0.15;
            } else if (std.mem.indexOf(u8, content_lower, keyword_lower) != null) {
                score += 0.1;
            }
        }

        // Low-value keywords contribute 0.05 each
        for (LOW_VALUE_KEYWORDS) |keyword| {
            const keyword_lower = std.ascii.allocLowerString(std.heap.page_allocator, keyword) catch continue;
            defer std.heap.page_allocator.free(keyword_lower);
            
            if (std.mem.indexOf(u8, title_lower, keyword_lower) != null) {
                score += 0.08;
            } else if (std.mem.indexOf(u8, content_lower, keyword_lower) != null) {
                score += 0.05;
            }
        }

        return @min(1.0, score);
    }

    /// Extract relevant keywords found in the content
    pub fn extractKeywords(self: *Self, title: []const u8, content: []const u8) ![][]const u8 {
        var found_keywords = std.ArrayList([]const u8).init(self.allocator);
        defer found_keywords.deinit();

        const title_lower = try std.ascii.allocLowerString(self.allocator, title);
        defer self.allocator.free(title_lower);
        
        const content_lower = try std.ascii.allocLowerString(self.allocator, content);
        defer self.allocator.free(content_lower);

        // Check all keyword categories
        const all_keywords = [_][]const []const u8{ &HIGH_VALUE_KEYWORDS, &MEDIUM_VALUE_KEYWORDS, &LOW_VALUE_KEYWORDS };
        
        for (all_keywords) |keyword_set| {
            for (keyword_set) |keyword| {
                const keyword_lower = try std.ascii.allocLowerString(self.allocator, keyword);
                defer self.allocator.free(keyword_lower);
                
                if (std.mem.indexOf(u8, title_lower, keyword_lower) != null or
                    std.mem.indexOf(u8, content_lower, keyword_lower) != null) {
                    try found_keywords.append(try self.allocator.dupe(u8, keyword));
                }
            }
        }

        return found_keywords.toOwnedSlice();
    }

    /// Get category of AI content based on keywords
    pub fn categorizeContent(self: *Self, title: []const u8, content: []const u8) AIContentCategory {
        _ = self;
        
        const title_lower = std.ascii.allocLowerString(std.heap.page_allocator, title) catch return .general;
        defer std.heap.page_allocator.free(title_lower);
        
        const content_lower = std.ascii.allocLowerString(std.heap.page_allocator, content) catch return .general;
        defer std.heap.page_allocator.free(content_lower);

        // Check for specific categories
        const research_indicators = [_][]const u8{ "paper", "research", "arxiv", "study", "analysis", "experiment" };
        const model_indicators = [_][]const u8{ "model", "gpt", "claude", "llm", "release", "checkpoint" };
        const safety_indicators = [_][]const u8{ "safety", "alignment", "bias", "fairness", "ethics", "responsible" };
        const tool_indicators = [_][]const u8{ "tool", "api", "framework", "library", "platform", "service" };

        for (research_indicators) |indicator| {
            if (std.mem.indexOf(u8, title_lower, indicator) != null or
                std.mem.indexOf(u8, content_lower, indicator) != null) {
                return .research;
            }
        }

        for (model_indicators) |indicator| {
            if (std.mem.indexOf(u8, title_lower, indicator) != null or
                std.mem.indexOf(u8, content_lower, indicator) != null) {
                return .model_release;
            }
        }

        for (safety_indicators) |indicator| {
            if (std.mem.indexOf(u8, title_lower, indicator) != null or
                std.mem.indexOf(u8, content_lower, indicator) != null) {
                return .safety;
            }
        }

        for (tool_indicators) |indicator| {
            if (std.mem.indexOf(u8, title_lower, indicator) != null or
                std.mem.indexOf(u8, content_lower, indicator) != null) {
                return .tools;
            }
        }

        return .general;
    }
};

pub const AIContentCategory = enum {
    research,
    model_release,
    safety,
    tools,
    industry_news,
    general,
    
    pub fn getDescription(self: AIContentCategory) []const u8 {
        return switch (self) {
            .research => "AI Research & Papers",
            .model_release => "Model Releases & Updates",
            .safety => "AI Safety & Ethics",
            .tools => "AI Tools & Platforms",
            .industry_news => "Industry News & Business",
            .general => "General AI Content",
        };
    }
};

test "AI relevance filtering" {
    var filter = AIRelevanceFilter.init(std.testing.allocator);
    defer filter.deinit();

    // Test positive cases
    const ai_title1 = "New GPT-4 Model Released by OpenAI";
    const ai_content1 = "OpenAI has announced the release of GPT-4, a large language model...";
    try std.testing.expect(filter.isAIRelated(ai_title1, ai_content1));

    const ai_title2 = "Machine Learning Breakthrough in Computer Vision";
    const ai_content2 = "Researchers have developed a new neural network architecture...";
    try std.testing.expect(filter.isAIRelated(ai_title2, ai_content2));

    // Test negative cases
    const non_ai_title = "New JavaScript Framework Released";
    const non_ai_content = "Developers have created a lightweight web framework...";
    try std.testing.expect(!filter.isAIRelated(non_ai_title, non_ai_content));

    // Test scoring
    const score = filter.calculateRelevanceScore(ai_title1, ai_content1);
    try std.testing.expect(score > 0.5);
}