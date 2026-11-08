"""Public DTO allowlists for chat; public-memory storage stays text-only."""

from .client import IntegrationProblem


def number(value, *, minimum=0):
    if type(value) is not int or value < minimum:
        raise IntegrationProblem("invalid_public_response")
    return value


def data_object(response):
    if not isinstance(response, dict) or not isinstance(response.get("data"), dict):
        raise IntegrationProblem("invalid_public_response")
    return response["data"]


def text_field(source, key, limit, *, required=False):
    value = source.get(key, "")
    if not isinstance(value, str) or (required and not value) or (key == "source_version" and len(value) > limit):
        raise IntegrationProblem("invalid_public_response")
    return value[:limit]


def presentation(source, *, reply=False, post_id=None):
    if not isinstance(source, dict):
        raise IntegrationProblem("invalid_public_response")
    ident = number(source.get("post_id"), minimum=1)
    if post_id is not None and ident != post_id:
        raise IntegrationProblem("public_scope_refused")
    result = {
        "post_id": ident,
        "status": source.get("status"),
        "source_version": text_field(source, "source_version", 100, required=True),
    }
    if reply:
        result["reply_id"] = number(source.get("reply_id"), minimum=1)
        if result["status"] == "deleted":
            # Even a malformed upstream tombstone cannot restore deleted content.
            return result
    if result["status"] != "normal":
        raise IntegrationProblem("public_scope_refused")
    limit = 2000 if reply else 10000
    content = source.get("content", "")
    if not isinstance(content, str):
        raise IntegrationProblem("invalid_public_response")
    result.update(
        content=content[:limit],
        created_at=text_field(source, "created_at", 40),
        truncated=source.get("truncated") is True or source.get("partial") is True or len(content) > limit,
    )
    if not reply:
        result.update(
            title=text_field(source, "title", 200),
            post_type=text_field(source, "post_type", 100, required=True),
            partial=result["truncated"],
        )
    for key in (
        ["like_count", "parent_reply_id", "reply_to_reply_id"]
        if reply
        else ["like_count", "reply_count", "revision"]
    ):
        if key in source and source[key] is not None:
            result[key] = number(source[key])
    if reply and isinstance(source.get("sticker_id"), str):
        result["sticker_id"] = source["sticker_id"][:100]
    author = source.get("author")
    if isinstance(author, dict) and isinstance(author.get("nickname"), str):
        result["author"] = {"nickname": author["nickname"][:100]}
        identity = author.get("ai_bot")
        if isinstance(identity, dict):
            # Trust only the server-projected identity, never nickname prefixes.
            bot = {}
            if type(identity.get("owner_id")) is int and identity["owner_id"] > 0:
                bot["owner_id"] = identity["owner_id"]
            if isinstance(identity.get("owner_nickname"), str):
                bot["owner_nickname"] = identity["owner_nickname"][:100]
            result["author"]["ai_bot"] = bot
    images = source.get("images", [])
    if not isinstance(images, list) or len(images) > 20:
        raise IntegrationProblem("invalid_public_response")
    result["images"] = []
    for image in images:
        if not isinstance(image, dict):
            raise IntegrationProblem("invalid_public_response")
        url = image.get("url")
        if (
            not isinstance(url, str)
            or not url.startswith("/uploads/")
            or len(url) > 1000
            or any(v in url for v in ("..", "\\", "?", "#", "%"))
        ):
            raise IntegrationProblem("invalid_public_image")
        row = {"url": url}
        for key in ("index", "width", "height"):
            if key in image:
                # Older public uploads have no stored dimensions (zero); the
                # actual image decoder, rather than metadata, validates pixels.
                row[key] = number(image[key], minimum=1 if key == "index" else 0)
        if isinstance(image.get("mime_type"), str):
            row["mime_type"] = image["mime_type"][:60]
        result["images"].append(row)
    return result


def page_cursor(data):
    if not isinstance(data, dict):
        raise IntegrationProblem("invalid_public_response")
    return number(data.get("next_after_id", 0))
