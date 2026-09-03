#!/usr/bin/env python3
from __future__ import annotations

import json
import urllib.request
from typing import Any

import httpx
from openai import OpenAI
from prompt_toolkit import PromptSession
from prompt_toolkit.formatted_text import HTML
from prompt_toolkit.key_binding import KeyBindings

BASE_URL = "http://127.0.0.1:8000/v1"
API_KEY = "EMPTY"
TIMEOUT = 300.0
TEMPERATURE = 0.6
TOP_P = 0.95
TOP_K = 20
MAX_TOKENS = 30000
CONTEXT_CHAR_LIMIT = 300000
CONTEXT_KEEP_RECENT = 6
DEFAULT_THINKING_ENABLED = True
DEFAULT_SHOW_THINKING_OUTPUT = False


def get_model_info() -> tuple[str, Any, Any]:
    with urllib.request.urlopen(f"{BASE_URL}/models", timeout=10) as r:
        data = json.loads(r.read().decode("utf-8"))
    models = data.get("data") or []
    if not models:
        raise RuntimeError("/v1/models returned empty data")
    model = models[0]
    return model.get("id"), model.get("max_model_len"), model.get("root")


def trim_history(messages: list[dict[str, str]]) -> list[dict[str, str]]:
    # Keep system + latest N non-system messages when context is too long.
    if len(messages) <= CONTEXT_KEEP_RECENT + 1:
        return messages
    return messages[:1] + messages[-CONTEXT_KEEP_RECENT:]


def main() -> int:
    http_client = httpx.Client(trust_env=False, timeout=TIMEOUT)
    client = OpenAI(base_url=BASE_URL, api_key=API_KEY, http_client=http_client)

    model, max_model_len, model_root = get_model_info()
    if not model:
        raise RuntimeError("Failed to detect model id from /v1/models")

    thinking_enabled = DEFAULT_THINKING_ENABLED
    thinking_output_enabled = DEFAULT_SHOW_THINKING_OUTPUT
    messages: list[dict[str, str]] = [
        {
            "role": "system",
            "content": "你是一个严谨、友好、擅长中文技术解释的本地大模型助手。回答尽量直接，不要输出冗长思考过程。",
        }
    ]

    kb = KeyBindings()

    send_key_hint = "Ctrl+Enter"
    try:
        @kb.add("c-enter")
        def _(event):
            event.current_buffer.validate_and_handle()
    except ValueError:
        # Many terminals/prompt_toolkit builds don't expose Ctrl+Enter distinctly.
        send_key_hint = "Ctrl+J"

        @kb.add("c-j")
        def _(event):
            event.current_buffer.validate_and_handle()

    prompt_session = PromptSession(multiline=True, key_bindings=kb)

    print("terminal chat started.")
    print(f"Model: {model}")
    print(f"max_model_len: {max_model_len}")
    print(f"root: {model_root}")
    print(
        f"defaults: think={'on' if DEFAULT_THINKING_ENABLED else 'off'}, "
        f"showthink={'on' if DEFAULT_SHOW_THINKING_OUTPUT else 'off'}"
    )
    print("命令：/q 或 /exit 退出，/clear 清空历史，/history 查看历史")
    print("      /think on|off 或 /思考 开|关：控制模型是否启用 thinking")
    print("      /showthink on|off 或 /显示思考 开|关：控制是否打印 thinking 过程")
    print(f"输入：支持多行；按 {send_key_hint} 发送，Ctrl+C 退出。")
    print("-" * 60)

    while True:
        try:
            user_input = prompt_session.prompt(
                HTML("\n<ansicyan>你：</ansicyan> ")
            ).strip()
        except KeyboardInterrupt:
            print("\n已退出。")
            break
        except EOFError:
            print("\n已退出。")
            break

        if user_input.lower() in {"/exit", "/quit", "/q", "exit", "quit", "q"}:
            print("已退出。")
            break

        if user_input.lower() == "/clear":
            messages = messages[:1]
            print("已清空对话历史。")
            continue

        if user_input.lower() == "/history":
            total_chars = sum(len(m.get("content", "")) for m in messages)
            print(f"messages: {len(messages)}, approx chars: {total_chars}")
            continue

        if user_input.lower() in {"/think on", "/思考 开"}:
            thinking_enabled = True
            print("thinking 已开启。")
            continue

        if user_input.lower() in {"/think off", "/思考 关"}:
            thinking_enabled = False
            print("thinking 已关闭。")
            continue

        if user_input.lower() in {"/showthink on", "/显示思考 开"}:
            thinking_output_enabled = True
            print("思考过程显示已开启。")
            continue

        if user_input.lower() in {"/showthink off", "/显示思考 关"}:
            thinking_output_enabled = False
            print("思考过程显示已关闭。")
            continue

        if not user_input:
            continue

        total_chars = sum(len(m.get("content", "")) for m in messages)
        if total_chars > CONTEXT_CHAR_LIMIT:
            print(f"历史过长，自动保留 system + 最近 {CONTEXT_KEEP_RECENT} 条消息。")
            messages = trim_history(messages)

        messages.append({"role": "user", "content": user_input})

        print("\n模型：", end="", flush=True)
        full_content = ""
        full_reasoning = ""
        printed_reasoning_header = False
        thinking_status_printed = False

        try:
            stream = client.chat.completions.create(
                model=model,
                messages=messages,
                temperature=TEMPERATURE,
                top_p=TOP_P,
                max_tokens=MAX_TOKENS,
                extra_body={
                    "top_k": TOP_K,
                    "chat_template_kwargs": {"enable_thinking": thinking_enabled},
                },
                stream=True,
            )

            if thinking_enabled and thinking_output_enabled:
                print("\n[提示] 模型正在思考...", end="", flush=True)
                thinking_status_printed = True

            for chunk in stream:
                if not chunk.choices:
                    continue
                delta = chunk.choices[0].delta

                reasoning = getattr(delta, "reasoning_content", None) or getattr(delta, "reasoning", None)
                content = getattr(delta, "content", None)

                if reasoning:
                    if thinking_enabled and thinking_output_enabled:
                        if not printed_reasoning_header:
                            print("\n[思考]\n", end="", flush=True)
                            printed_reasoning_header = True
                        print(reasoning, end="", flush=True)
                        full_reasoning += reasoning
                    elif not thinking_enabled:
                        # Some vLLM/Qwen streams put the final answer in delta.reasoning.
                        print(reasoning, end="", flush=True)
                        full_content += reasoning

                if content:
                    if printed_reasoning_header:
                        print("\n[回答]\n", end="", flush=True)
                        printed_reasoning_header = False
                    elif thinking_status_printed:
                        print("\n[回答]\n", end="", flush=True)
                        thinking_status_printed = False
                    print(content, end="", flush=True)
                    full_content += content

            print()

            if full_content.strip():
                messages.append({"role": "assistant", "content": full_content})
            elif full_reasoning.strip():
                print("\n注意：本轮只有 reasoning_content，没有普通 content。建议保持 /think off。")
                snippet = full_reasoning[:200].replace("\n", " ")
                messages.append({"role": "assistant", "content": f"[仅思考输出摘要] {snippet}"})
            else:
                print("\n注意：本轮没有收到 content 或 reasoning_content。")

        except KeyboardInterrupt:
            print("\n已中断。")
            break
        except Exception as e:
            print(f"\n请求失败：{repr(e)}")
            if messages and messages[-1].get("role") == "user":
                messages.pop()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
