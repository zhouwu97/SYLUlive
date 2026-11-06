"""Permission-only configuration, validated and persisted through AstrBotConfig."""
import copy
import hashlib
import json
import re

from .permissions import CAPABILITY_LABELS, _compile

DEFAULTS = {
    "allow_multi_user": True, "allow_group_binding": False,
    "public_read_all_sessions": False, "public_read_group_ids": [],
    "allow_checkin": False, "allow_personal_queries": False,
    "allow_proposals": False, "allow_private_review": False,
    "group_personal_delivery": "confirm", "binding_link_delivery": "auto",
    "access_default": "inherit", "access_rules": [],
}
CHOICES = {"group_personal_delivery": {"confirm", "direct", "private"},
           "binding_link_delivery": {"auto", "group", "private"},
           "access_default": {"inherit", "deny"}}
RULE_KEYS = {"name", "enabled", "effect", "subjects", "capabilities",
             "chat_types", "user_ids", "group_ids", "__template_key"}


class PolicyError(Exception):
    def __init__(self, code, status=422):
        self.code, self.status = code, status
        super().__init__(code)


def document(config):
    return copy.deepcopy({key: config.get(key, value) for key, value in DEFAULTS.items()})


def revision(policy):
    return hashlib.sha256(json.dumps(policy, sort_keys=True, ensure_ascii=False).encode()).hexdigest()


def snapshot(config):
    policy = document(config)
    return {"policy": policy, "revision": revision(policy),
            "capabilities": [{"id": key, "label": label} for key, label in CAPABILITY_LABELS.items()]}


def ids(value):
    if not isinstance(value, list) or len(value) > 256 or any(
        not isinstance(item, str) or not re.fullmatch(r"[1-9][0-9]{4,14}", item) for item in value
    ) or len(value) != len(set(value)):
        raise PolicyError("invalid_id_list")
    return list(value)


def validate(policy):
    if not isinstance(policy, dict) or set(policy) != set(DEFAULTS):
        raise PolicyError("invalid_policy_fields")
    result = copy.deepcopy(policy)
    for key, default in DEFAULTS.items():
        if type(default) is bool and type(result[key]) is not bool:
            raise PolicyError("invalid_feature_flag")
    for key, options in CHOICES.items():
        if not isinstance(result[key], str) or result[key] not in options:
            raise PolicyError("invalid_policy_choice")
    result["public_read_group_ids"] = ids(result["public_read_group_ids"])
    rules = result["access_rules"]
    if not isinstance(rules, list) or len(rules) > 128:
        raise PolicyError("invalid_rule_count")
    normalized = []
    for index, rule in enumerate(rules):
        if not isinstance(rule, dict) or set(rule) - RULE_KEYS:
            raise PolicyError("invalid_rule_fields")
        row = {"name": "", "enabled": True, "user_ids": [], "group_ids": [], **rule}
        if row.get("__template_key", "access_rule") != "access_rule":
            raise PolicyError("invalid_rule_template")
        try:
            # Disabled rules are validated too: enabling one later must be safe.
            _compile({**row, "enabled": True}, index)
        except (TypeError, ValueError):
            raise PolicyError("invalid_rule") from None
        if type(row["enabled"]) is not bool:
            raise PolicyError("invalid_rule")
        row["user_ids"], row["group_ids"] = ids(row["user_ids"]), ids(row["group_ids"])
        if row["group_ids"] and "group" not in row["chat_types"]:
            raise PolicyError("group_rule_requires_group_chat")
        row["__template_key"] = "access_rule"
        normalized.append(row)
    result["access_rules"] = normalized
    return result


def save(config, body):
    if not isinstance(body, dict) or set(body) != {"revision", "policy"}:
        raise PolicyError("invalid_save_fields")
    if not isinstance(body["revision"], str) or not re.fullmatch(r"[a-f0-9]{64}", body["revision"]):
        raise PolicyError("invalid_revision")
    policy = validate(body["policy"])
    if revision(document(config)) != body["revision"]:
        raise PolicyError("policy_conflict", 409)
    persist = getattr(config, "save_config", None)
    if not callable(persist):
        raise PolicyError("configuration_not_writable", 503)
    before = {key: (key in config, copy.deepcopy(config.get(key))) for key in DEFAULTS}
    try:
        # No await between compare and save; AstrBot's synchronous save serializes
        # the in-memory snapshot and atomically replaces its configuration file.
        persist(policy)
    except Exception:
        for key, (existed, value) in before.items():
            if existed:
                config[key] = value
            else:
                config.pop(key, None)
        raise PolicyError("policy_save_failed", 503) from None
    return snapshot(config)
