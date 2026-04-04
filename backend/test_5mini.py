"""Test gpt-5-mini alone to debug empty output."""
import os, time, warnings
warnings.filterwarnings("ignore")
from openai import AzureOpenAI

client = AzureOpenAI(
    api_key=os.environ["AZURE_OPENAI_KEY"],
    api_version="2025-04-01-preview",
    azure_endpoint="https://anote-openai.openai.azure.com/",
)

print("Calling gpt-5-mini with 8000 token limit...", flush=True)
start = time.time()
response = client.chat.completions.create(
    model="gpt-5-mini",
    messages=[
        {"role": "system", "content": "Jsi asistent. Odpověz krátce v češtině."},
        {"role": "user", "content": "Co je Praha? Odpověz jednou větou."},
    ],
    max_completion_tokens=8000,
)
elapsed = time.time() - start
choice = response.choices[0]
print(f"TIME: {elapsed:.2f}s")
print(f"PROMPT_TOKENS: {response.usage.prompt_tokens}")
print(f"COMPLETION_TOKENS: {response.usage.completion_tokens}")
if hasattr(response.usage, 'completion_tokens_details') and response.usage.completion_tokens_details:
    print(f"TOKEN_DETAILS: {response.usage.completion_tokens_details}")
print(f"FINISH_REASON: {choice.finish_reason}")
print(f"CONTENT: [{choice.message.content}]")
print(f"REFUSAL: [{choice.message.refusal}]")
