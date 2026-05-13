"""Patch harbor's Chat.chat to handle empty or null assistant content.

Reasoning-style models (e.g. gpt-oss-120b) sometimes return responses with
`content` set to "" or null (only `reasoning_content` is populated). Stored as
`{"role": "assistant", "content": ""}` or `{..., "content": null}`, this gets
sent on the *next* call as part of `message_history`. vLLM's strict Pydantic
validation rejects empty/null content with: `String should have at least 1
character`.

For null content, we promote `reasoning_content` into `content` so the agent
sees actual model output. For empty string content (or absent reasoning_content),
we substitute a single-space placeholder. Both preserve message structure while
passing strict validation.

Pinned to harbor 0.5.0 via the project README. If the upstream `Chat.chat`
signature changes, this will fail loudly at import time.
"""

import logging

from harbor.llms.chat import Chat

_logger = logging.getLogger(__name__)
_PLACEHOLDER = " "


def _scrub_messages(messages):
    for m in messages:
        if not isinstance(m, dict):
            continue
        if m.get("content") == "" or m.get("content") is None:
            reasoning = m.get("reasoning_content")
            m["content"] = reasoning if reasoning else _PLACEHOLDER


_original_chat = Chat.chat


async def _patched_chat(self, prompt, *args, **kwargs):
    safe_prompt = prompt if prompt else _PLACEHOLDER
    response = await _original_chat(self, safe_prompt, *args, **kwargs)
    _scrub_messages(self._messages)
    return response


Chat.chat = _patched_chat
_logger.debug("Applied empty-content patch to harbor.llms.chat.Chat.chat")
