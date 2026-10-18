"""统一的 LLM 调用层：key 由调用方提供或环境变量兜底，本项目不落盘。"""

from __future__ import annotations

import json
import os
import urllib.error
import urllib.request

DEFAULT_BASE = "https://api.deepseek.com"
DEFAULT_MODEL = "deepseek-chat"

# 给客户端设置页用：填 key 的下拉选项。改这里就能加 provider。
PROVIDERS = [
    {"id": "deepseek", "name": "DeepSeek", "base_url": "https://api.deepseek.com",
     "model": "deepseek-chat", "key_url": "https://platform.deepseek.com/api_keys"},
    {"id": "qwen", "name": "通义千问", "base_url": "https://dashscope.aliyuncs.com/compatible-mode/v1",
     "model": "qwen-plus", "key_url": "https://bailian.console.aliyun.com/?apiKey=1#/api-key"},
    {"id": "openai", "name": "OpenAI", "base_url": "https://api.openai.com/v1",
     "model": "gpt-4o-mini", "key_url": "https://platform.openai.com/api-keys"},
    {"id": "ollama", "name": "本地 Ollama", "base_url": "http://localhost:11434/v1",
     "model": "qwen2.5:14b", "key_url": ""},
]


def load_env(path=".env") -> None:
    """读本地 .env 兜底配置（CLI 与后端共用）。"""
    from pathlib import Path

    p = Path(path)
    if not p.exists():
        return
    for line in p.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            os.environ.setdefault(k.strip(), v.strip().strip("\"'"))


class NoKey(Exception):
    """没拿到 key。让调用方决定是报错还是提示用户去设置页。"""


def resolve_config(cfg: dict | None = None) -> dict:
    """客户端传的优先，环境变量兜底。"""
    c = cfg or {}
    return {
        "api_key": (c.get("api_key") or os.environ.get("LLM_API_KEY") or "").strip(),
        "base_url": (c.get("base_url") or os.environ.get("LLM_BASE_URL") or DEFAULT_BASE).rstrip("/"),
        "model": (c.get("model") or os.environ.get("LLM_MODEL") or DEFAULT_MODEL).strip(),
    }


def complete(messages: list[dict], temperature: float = 0.9, cfg: dict | None = None,
             json_mode: bool = False) -> str:
    """发一次 chat completion，返回文本内容。

    json_mode 要走结构化输出，但部分 provider 不认 response_format，会自动降级重试。
    """
    c = resolve_config(cfg)
    if not c["api_key"]:
        raise NoKey("没有 API key。在设置页填你自己的 key，或设 LLM_API_KEY 环境变量")

    def _post(use_json_mode: bool) -> str:
        body = {"model": c["model"], "messages": messages, "temperature": temperature}
        if use_json_mode:
            body["response_format"] = {"type": "json_object"}
        req = urllib.request.Request(
            f"{c['base_url']}/chat/completions",
            data=json.dumps(body).encode(),
            headers={"Content-Type": "application/json", "Authorization": f"Bearer {c['api_key']}"},
        )
        with urllib.request.urlopen(req, timeout=180) as r:
            return json.load(r)["choices"][0]["message"]["content"].strip()

    try:
        return _post(json_mode)
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace")[:200]
        if json_mode:
            return _post(False)  # provider 不认时退化成普通调用
        raise RuntimeError(f"{e.code} {detail}") from e
    except urllib.error.URLError as e:
        raise RuntimeError(f"连不上 {c['base_url']}：{e.reason}") from e


if __name__ == "__main__":
    os.environ.pop("LLM_API_KEY", None)
    assert resolve_config()["api_key"] == ""
    try:
        complete([{"role": "user", "content": "hi"}])
        raise AssertionError("没 key 应该抛异常")
    except NoKey:
        pass

    os.environ["LLM_API_KEY"] = "env-key"
    assert resolve_config()["api_key"] == "env-key"
    # 客户端传的必须盖过环境变量
    assert resolve_config({"api_key": "user-key"})["api_key"] == "user-key"
    assert resolve_config({"base_url": "https://x.io/v1/"})["base_url"] == "https://x.io/v1"
    assert resolve_config({"model": "m"})["model"] == "m"

    assert len(PROVIDERS) == 4
    assert all(p["base_url"] for p in PROVIDERS)
    print("llm self-check ok：key 优先级（客户端 > 环境变量）、缺 key 报错、provider 预设")
