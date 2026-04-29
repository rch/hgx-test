"""Patch harbor's Chat.chat to handle empty assistant content.

Reasoning-style models (e.g. gpt-oss-120b) sometimes return responses with
empty `content` (only `reasoning_content` is populated). Stored as
`{"role": "assistant", "content": ""}`, this gets sent on the *next* call as
part of `message_history`. vLLM's strict Pydantic validation rejects empty
content with: `String should have at least 1 character`.

We substitute a single-space placeholder for empty `content` (and empty
`prompt`), which preserves message structure while passing strict validation.

Pinned to harbor 0.5.0 via the project README. If the upstream `Chat.chat`
signature changes, this will fail loudly at import time.
"""

import logging

from harbor.llms.chat import Chat

_logger = logging.getLogger(__name__)
_PLACEHOLDER = " "


def _scrub_messages(messages):
    for m in messages:
        if isinstance(m, dict) and m.get("content") == "":
            m["content"] = _PLACEHOLDER


_original_chat = Chat.chat


async def _patched_chat(self, prompt, *args, **kwargs):
    safe_prompt = prompt if prompt else _PLACEHOLDER
    response = await _original_chat(self, safe_prompt, *args, **kwargs)
    _scrub_messages(self._messages)
    return response


Chat.chat = _patched_chat
_logger.debug("Applied empty-content patch to harbor.llms.chat.Chat.chat")
