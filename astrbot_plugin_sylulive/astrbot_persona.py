"""Read the persona chosen in AstrBot. No local persona text or fallback character."""


async def selected_prompt(context, event, conversation=None, *, background=False):
    manager = getattr(context, "persona_manager", None)
    if manager is None:
        return ""
    if background:
        selected = await manager.get_default_persona_v3()
    else:
        # Never take another session's persona selection from a foreign CID.
        own = conversation is not None and getattr(conversation, "user_id", None) == event.unified_msg_origin
        _, selected, _, _ = await manager.resolve_selected_persona(
            umo=event.unified_msg_origin,
            conversation_persona_id=getattr(conversation, "persona_id", None) if own else None,
            platform_name=event.get_platform_name(),
        )
    prompt = selected.get("prompt", "") if isinstance(selected, dict) else ""
    return prompt if isinstance(prompt, str) else ""
