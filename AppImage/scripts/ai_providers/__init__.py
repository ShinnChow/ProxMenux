"""AI Providers for ProxMenux notification enhancement.

This module provides a pluggable architecture for different AI providers
to enhance and translate notification messages.

Supported providers:
- Groq: Fast inference, generous free tier (30 req/min)
- OpenAI: Industry standard, widely used
- Anthropic: Excellent for text generation, Claude Haiku is fast and affordable
- Gemini: Google's model, free tier available, good quality/price ratio
- Ollama: 100% local execution, no costs, complete privacy
- OpenRouter: Aggregator with access to 100+ models using a single API key
"""
from .base import AIProvider, AIProviderError
from .groq_provider import GroqProvider
from .openai_provider import OpenAIProvider
from .anthropic_provider import AnthropicProvider
from .gemini_provider import GeminiProvider
from .ollama_provider import OllamaProvider
from .openrouter_provider import OpenRouterProvider

PROVIDERS = {
    'groq': GroqProvider,
    'openai': OpenAIProvider,
    'anthropic': AnthropicProvider,
    'gemini': GeminiProvider,
    'ollama': OllamaProvider,
    'openrouter': OpenRouterProvider,
}

# Provider metadata for UI display
# Note: No hardcoded models - users load models dynamically from each provider
PROVIDER_INFO = {
    'groq': {
        'name': 'Groq',
        'description': 'Fast inference, generous free tier (30 req/min). Ideal to get started.',
        'requires_api_key': True,
    },
    'openai': {
        'name': 'OpenAI',
        'description': 'Industry standard. Very accurate and widely used.',
        'requires_api_key': True,
    },
    'anthropic': {
        'name': 'Anthropic (Claude)',
        'description': 'Excellent for writing and translation. Fast and affordable.',
        'requires_api_key': True,
    },
    'gemini': {
        'name': 'Google Gemini',
        'description': 'Free tier available, very good quality/price ratio.',
        'requires_api_key': True,
    },
    'ollama': {
        'name': 'Ollama (Local)',
        'description': '100% local execution. No costs, complete privacy, no internet required.',
        'requires_api_key': False,
    },
    'openrouter': {
        'name': 'OpenRouter',
        'description': 'Aggregator with access to 100+ models using a single API key. Maximum flexibility.',
        'requires_api_key': True,
    },
}


def get_provider(name: str, **kwargs) -> AIProvider:
    """Factory function to get provider instance.
    
    Args:
        name: Provider name (groq, openai, anthropic, gemini, ollama, openrouter)
        **kwargs: Provider-specific arguments (api_key, model, base_url)
        
    Returns:
        AIProvider instance
        
    Raises:
        AIProviderError: If provider name is unknown
    """
    if name not in PROVIDERS:
        raise AIProviderError(f"Unknown provider: {name}. Available: {list(PROVIDERS.keys())}")
    return PROVIDERS[name](**kwargs)


def get_provider_info(name: str = None) -> dict:
    """Get provider metadata for UI display.
    
    Args:
        name: Optional provider name. If None, returns all providers info.
        
    Returns:
        Provider info dict or dict of all providers
    """
    if name:
        return PROVIDER_INFO.get(name, {})
    return PROVIDER_INFO


__all__ = [
    'AIProvider', 
    'AIProviderError', 
    'PROVIDERS', 
    'PROVIDER_INFO',
    'get_provider',
    'get_provider_info',
]
