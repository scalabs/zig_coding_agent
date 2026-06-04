pub const Provider = enum {
    ollama,
    openai,
    openrouter,
    claude,
    bedrock,
    llama_cpp,
};

pub const LoopMode = enum {
    basic,
    agent,
    react,
};
