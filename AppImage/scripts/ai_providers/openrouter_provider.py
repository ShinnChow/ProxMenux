"""OpenRouter provider implementation.

OpenRouter is an aggregator that provides access to 100+ AI models
using a single API key. Maximum flexibility for choosing models.
Uses OpenAI-compatible API format.
"""
from typing import Optional, List
import json
import urllib.request
import urllib.error
from .base import AIProvider, AIProviderError


class OpenRouterProvider(AIProvider):
    """OpenRouter provider for multi-model access."""
    
    NAME = "openrouter"
    REQUIRES_API_KEY = True
    API_URL = "https://openrouter.ai/api/v1/chat/completions"
    MODELS_URL = "https://openrouter.ai/api/v1/models"
    
    # Exclude non-text models  
    EXCLUDED_PATTERNS = ['image', 'vision', 'audio', 'video', 'embedding', 'moderation']
    
    # Recommended model prefixes (popular, reliable, good for notifications)
    RECOMMENDED_PREFIXES = [
        'meta-llama/llama-3', 'anthropic/claude', 'google/gemini',
        'openai/gpt', 'mistralai/mistral', 'mistralai/mixtral'
    ]
    
    def list_models(self) -> List[str]:
        """List available OpenRouter models for chat completions.
        
        OpenRouter has 300+ models. This filters to text generation models
        and prioritizes popular, reliable options.
        
        Returns:
            List of model IDs suitable for text generation.
        """
        if not self.api_key:
            return []
        
        try:
            req = urllib.request.Request(
                self.MODELS_URL,
                headers={'Authorization': f'Bearer {self.api_key}'},
                method='GET'
            )
            
            with urllib.request.urlopen(req, timeout=10) as resp:
                data = json.loads(resp.read().decode('utf-8'))
            
            models = []
            for model in data.get('data', []):
                model_id = model.get('id', '')
                if not model_id:
                    continue
                
                model_lower = model_id.lower()
                
                # Exclude non-text models
                if any(pattern in model_lower for pattern in self.EXCLUDED_PATTERNS):
                    continue
                
                models.append(model_id)
            
            # Sort with recommended models first
            def sort_key(m):
                m_lower = m.lower()
                for i, prefix in enumerate(self.RECOMMENDED_PREFIXES):
                    if m_lower.startswith(prefix):
                        return (i, m)
                return (len(self.RECOMMENDED_PREFIXES), m)
            
            return sorted(models, key=sort_key)
        except Exception as e:
            print(f"[OpenRouterProvider] Failed to list models: {e}")
            return []
    
    def generate(self, system_prompt: str, user_message: str,
                 max_tokens: int = 200) -> Optional[str]:
        """Generate a response using OpenRouter's API.
        
        OpenRouter uses OpenAI-compatible format with additional
        headers for app identification.
        
        Args:
            system_prompt: System instructions
            user_message: User message to process
            max_tokens: Maximum response length
            
        Returns:
            Generated text or None if failed
            
        Raises:
            AIProviderError: If API key is missing or request fails
        """
        if not self.api_key:
            raise AIProviderError("API key required for OpenRouter")
        
        payload = {
            'model': self.model,
            'messages': [
                {'role': 'system', 'content': system_prompt},
                {'role': 'user', 'content': user_message},
            ],
            'max_tokens': max_tokens,
            'temperature': 0.3,
        }
        
        headers = {
            'Content-Type': 'application/json',
            'Authorization': f'Bearer {self.api_key}',
            'HTTP-Referer': 'https://github.com/MacRimi/ProxMenux',
            'X-Title': 'ProxMenux Monitor',
        }
        
        result = self._make_request(self.API_URL, payload, headers)
        
        try:
            return result['choices'][0]['message']['content'].strip()
        except (KeyError, IndexError) as e:
            raise AIProviderError(f"Unexpected response format: {e}")
