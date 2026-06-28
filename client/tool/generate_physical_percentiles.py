#!/usr/bin/env python3
"""生成体测百分位匿名统计资产。

脚本只输出项目分布数组和样本量，不保留姓名、学号、班级、院系等个人信息。
"""

from __future__ import annotations

import argparse
import json
import math
import re
from collections import defaultdict
from datetime import datetime
from pathlib import Path
from typing import Any

import pandas as pd


METRICS: dict[str, dict[str, Any]] = {
    "height": {
        "label": "身高",
        "unit": "cm",
        "higher_is_better": True,
        "category": "body",
        "aliases": ["身高"],
    },
    "weight": {
        "label": "体重",
        "unit": "kg",
        "higher_is_better": True,
        "category": "body",
        "aliases": ["体重", "BMI", "体重指数"],
    },
    "vital_capacity": {
        "label": "肺活量",
        "unit": "mL",
        "higher_is_better": True,
        "category": "sport",
        "aliases": ["肺活量"],
    },
    "run_50m": {
        "label": "50 米跑",
        "unit": "秒",
        "higher_is_better": False,
        "category": "sport",
        "aliases": ["50米跑", "50 米跑", "50m", "50M"],
    },
    "sit_reach": {
        "label": "坐位体前屈",
        "unit": "cm",
        "higher_is_better": True,
        "category": "sport",
        "aliases": ["坐位体前屈", "坐体前屈", "体前屈"],
    },
    "standing_jump": {
        "label": "立定跳远",
        "unit": "cm",
        "higher_is_better": True,
        "category": "sport",
        "aliases": ["立定跳远"],
    },
    "pull_up": {
        "label": "引体向上",
        "unit": "次",
        "higher_is_better": True,
        "category": "sport",
        "aliases": ["引体向上"],
    },
    "run_1000m": {
        "label": "1000 米",
        "unit": "秒",
        "higher_is_better": False,
        "category": "sport",
        "aliases": ["1000米跑", "1000 米跑", "1000米", "1000"],
    },
    "sit_up": {
        "label": "1 分钟仰卧起坐",
        "unit": "次",
        "higher_is_better": True,
        "category": "sport",
        "aliases": ["一分钟仰卧起坐", "1分钟仰卧起坐", "仰卧起坐"],
    },
    "run_800m": {
        "label": "800 米",
        "unit": "秒",
        "higher_is_better": False,
        "category": "sport",
        "aliases": ["800米跑", "800 米跑", "800米", "800"],
    },
}

RUN_METRICS = {"run_50m", "run_800m", "run_1000m"}
ZERO_ALLOWED = {"pull_up", "sit_up"}
MALE_ONLY_METRICS = {"pull_up", "run_1000m"}
FEMALE_ONLY_METRICS = {"sit_up", "run_800m"}
FORBIDDEN_PRIVACY_TERMS = [
    "姓名",
    "学号",
    "班级",
    "院系",
    "院系名称",
    "学院号",
    "专业号",
    "班级号",
    "student_id",
    "name",
]


def normalize_metric_id(raw_name: Any) -> str | None:
    text = str(raw_name).strip()
    if not text:
        return None
    compact = (
        text.lower()
        .replace(" ", "")
        .replace("ｍ", "m")
        .replace("米", "m")
        .replace("公尺", "m")
    )

    if "身高" in compact:
        return "height"
    if "体重" in compact or "bmi" in compact:
        return "weight"
    if "肺活量" in compact:
        return "vital_capacity"
    if "50m" in compact or compact == "50" or "50米" in text:
        return "run_50m"
    if "坐体前屈" in text or "坐位体前屈" in text or "体前屈" in text:
        return "sit_reach"
    if "立定跳远" in text or "跳远" in text:
        return "standing_jump"
    if "引体" in text:
        return "pull_up"
    if "仰卧" in text:
        return "sit_up"
    if compact == "1000" or "1000m" in compact or "1000米" in text:
        return "run_1000m"
    if compact == "800" or "800m" in compact or "800米" in text:
        return "run_800m"
    return None


def parse_gender(raw: Any) -> str | None:
    if raw is None or (isinstance(raw, float) and math.isnan(raw)):
        return None
    text = str(raw).strip().lower()
    if text in {"男", "男生", "m", "male", "1"}:
        return "male"
    if text in {"女", "女生", "f", "female", "2"}:
        return "female"
    return None


def infer_gender(row: pd.Series, metric_columns: dict[str, str]) -> str | None:
    male_score = 0
    female_score = 0
    for metric_id in ("run_1000m", "pull_up"):
        column = metric_columns.get(metric_id)
        if column and parse_value(metric_id, row.get(column)) is not None:
            male_score += 1
    for metric_id in ("run_800m", "sit_up"):
        column = metric_columns.get(metric_id)
        if column and parse_value(metric_id, row.get(column)) is not None:
            female_score += 1
    if male_score > female_score:
        return "male"
    if female_score > male_score:
        return "female"
    return None


def parse_value(metric_id: str, raw: Any) -> float | None:
    if raw is None:
        return None
    if isinstance(raw, float) and math.isnan(raw):
        return None
    if isinstance(raw, int | float):
        value = float(raw)
    else:
        text = str(raw).strip()
        if not text or text in {"--", "null", "None"}:
            return None
        value = parse_run_seconds(metric_id, text) if metric_id in RUN_METRICS else parse_number(text)

    if value is None or math.isnan(value) or math.isinf(value):
        return None
    if value < 0:
        return None
    if value == 0 and metric_id not in ZERO_ALLOWED:
        return None
    if not is_reasonable(metric_id, value):
        return None
    return round(value, 2)


def parse_number(text: str) -> float | None:
    normalized = text.replace("，", ".").replace(",", ".")
    match = re.search(r"-?\d+(?:\.\d+)?", normalized)
    if not match:
        return None
    return float(match.group(0))


def parse_run_seconds(metric_id: str, text: str) -> float | None:
    normalized = (
        text.strip()
        .replace("′", "'")
        .replace("’", "'")
        .replace("‘", "'")
        .replace("″", '"')
        .replace("”", '"')
        .replace("“", '"')
        .replace("分", "'")
        .replace("秒", "")
    )
    normalized = re.sub(r"\s+", "", normalized)
    minute_match = re.match(r'^(\d+)[\':](\d+(?:\.\d+)?)"?$', normalized)
    if minute_match:
        return int(minute_match.group(1)) * 60 + float(minute_match.group(2))

    try:
        numeric = float(normalized.replace(",", "."))
    except ValueError:
        return parse_number(normalized)

    # 中长跑旧表常把 4.23 写作 4 分 23 秒；50 米保留十进制秒。
    if metric_id != "run_50m" and "." in normalized and 3 <= numeric < 20:
        left, right, *_ = normalized.split(".")
        if right.isdigit() and len(right) <= 2:
            seconds = int(right.ljust(2, "0"))
            if seconds < 60:
                return int(left) * 60 + seconds
    return numeric


def is_reasonable(metric_id: str, value: float) -> bool:
    ranges = {
        "height": (120, 230),
        "weight": (30, 180),
        "vital_capacity": (500, 9999),
        "run_50m": (5, 20),
        "sit_reach": (-30, 50),
        "standing_jump": (50, 400),
        "pull_up": (0, 80),
        "run_1000m": (120, 600),
        "sit_up": (0, 120),
        "run_800m": (100, 500),
    }
    low, high = ranges[metric_id]
    return low <= value <= high


def metric_columns_for(df: pd.DataFrame) -> dict[str, str]:
    columns: dict[str, str] = {}
    for column in df.columns:
        metric_id = normalize_metric_id(column)
        if metric_id and metric_id not in columns:
            columns[metric_id] = column
    return columns


def read_workbooks(dataset_dir: Path) -> list[pd.DataFrame]:
    frames: list[pd.DataFrame] = []
    for path in sorted(dataset_dir.glob("*.xls*")):
        sheets = pd.read_excel(path, sheet_name=None)
        for sheet_name, frame in sheets.items():
            if frame.empty:
                continue
            frame = frame.dropna(how="all")
            if frame.empty:
                continue
            normalized_columns = [str(column).strip() for column in frame.columns]
            frame.columns = normalized_columns
            if not metric_columns_for(frame):
                continue
            frame = frame.copy()
            frame["_source_file"] = path.name
            frame["_source_sheet"] = sheet_name
            frames.append(frame)
    return frames


def build_dataset(frames: list[pd.DataFrame]) -> dict[str, Any]:
    groups: dict[str, dict[str, list[float]]] = {
        "male": defaultdict(list),
        "female": defaultdict(list),
        "all": defaultdict(list),
    }

    rows_seen = 0
    rows_used = 0

    for frame in frames:
        metric_columns = metric_columns_for(frame)
        if not metric_columns:
            continue

        gender_column = next(
            (column for column in frame.columns if str(column).strip() in {"性别", "gender", "sex"}),
            None,
        )

        for _, row in frame.iterrows():
            rows_seen += 1
            gender = parse_gender(row.get(gender_column)) if gender_column else None
            if gender is None:
                gender = infer_gender(row, metric_columns)
            if gender not in {"male", "female"}:
                continue

            row_used = False
            for metric_id, column in metric_columns.items():
                if metric_id in MALE_ONLY_METRICS and gender != "male":
                    continue
                if metric_id in FEMALE_ONLY_METRICS and gender != "female":
                    continue
                value = parse_value(metric_id, row.get(column))
                if value is None:
                    continue
                groups[gender][metric_id].append(value)
                groups["all"][metric_id].append(value)
                row_used = True
            if row_used:
                rows_used += 1

    serializable_groups: dict[str, dict[str, list[float]]] = {}
    sample_counts: dict[str, dict[str, int]] = {}
    for group, metrics in groups.items():
        serializable_groups[group] = {}
        sample_counts[group] = {}
        for metric_id in METRICS:
            values = sorted(metrics.get(metric_id, []))
            serializable_groups[group][metric_id] = values
            sample_counts[group][metric_id] = len(values)

    public_metrics = {
        metric_id: {
            key: value
            for key, value in config.items()
            if key in {"label", "unit", "higher_is_better", "category"}
        }
        for metric_id, config in METRICS.items()
    }

    return {
        "version": 1,
        "generated_at": datetime.now().astimezone().isoformat(timespec="seconds"),
        "source_summary": {
            "file_count": len(frames),
            "rows_seen": rows_seen,
            "rows_used": rows_used,
        },
        "metrics": public_metrics,
        "groups": serializable_groups,
        "sample_counts": sample_counts,
    }


def assert_no_privacy_terms(output: dict[str, Any]) -> None:
    raw = json.dumps(output, ensure_ascii=False)
    found = [term for term in FORBIDDEN_PRIVACY_TERMS if term in raw]
    if found:
        raise RuntimeError(f"输出 JSON 含疑似隐私字段: {', '.join(found)}")


def main() -> None:
    parser = argparse.ArgumentParser(description="生成体测匿名百分位 JSON")
    parser.add_argument(
        "--dataset-dir",
        default=r"C:\Users\zhy23\Desktop\体测数据集",
        help="体测 Excel 数据目录",
    )
    parser.add_argument(
        "--output",
        default=str(Path(__file__).resolve().parents[1] / "assets" / "data" / "physical_percentiles.json"),
        help="输出 JSON 路径",
    )
    args = parser.parse_args()

    dataset_dir = Path(args.dataset_dir)
    output_path = Path(args.output)
    frames = read_workbooks(dataset_dir)
    if not frames:
        raise RuntimeError(f"未在 {dataset_dir} 读取到可用体测数据")

    output = build_dataset(frames)
    assert_no_privacy_terms(output)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(
        json.dumps(output, ensure_ascii=False, separators=(",", ":")),
        encoding="utf-8",
    )

    counts = output["sample_counts"]
    print(f"生成完成: {output_path}")
    print(f"读取 sheet 数: {len(frames)}")
    print(f"全体样本: {max(counts['all'].values()) if counts['all'] else 0}")
    for group in ("male", "female", "all"):
        summary = ", ".join(
            f"{metric_id}={count}"
            for metric_id, count in counts[group].items()
            if count
        )
        print(f"{group}: {summary}")


if __name__ == "__main__":
    main()
