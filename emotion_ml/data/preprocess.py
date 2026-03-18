"""Preprocess GoEmotions into Ekman 7-class splits."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

import pandas as pd
from datasets import load_dataset

from config import EKMAN_MAPPING, SPLITS_DIR


def _get_goemotions_label_names():
    """Get the label name list from GoEmotions simplified."""
    ds = load_dataset("google-research-datasets/go_emotions", "simplified")
    return ds["train"].features["labels"].feature.names


def _map_to_ekman(label_ids: list[int], label_names: list[str]) -> str | None:
    """Map a GoEmotions label id list to a single Ekman label.

    GoEmotions simplified can have multiple labels per example.
    We take the first label that maps to an Ekman category.
    If none map, return None (drop the example).
    """
    for lid in label_ids:
        name = label_names[lid]
        ekman = EKMAN_MAPPING.get(name)
        if ekman is not None:
            return ekman
    return None


def preprocess_goemotions() -> dict[str, pd.DataFrame]:
    """Load, map, and split GoEmotions into Ekman categories.

    Returns dict with keys 'train', 'validation', 'test'.
    """
    ds = load_dataset("google-research-datasets/go_emotions", "simplified")
    label_names = _get_goemotions_label_names()

    splits = {}
    for split_name in ("train", "validation", "test"):
        rows = []
        for example in ds[split_name]:
            ekman = _map_to_ekman(example["labels"], label_names)
            if ekman is not None:
                rows.append({"text": example["text"], "label": ekman})
        df = pd.DataFrame(rows)
        splits[split_name] = df
        print(f"  {split_name}: {len(df)} examples")
        print(f"    Distribution:\n{df['label'].value_counts().to_string()}\n")

    return splits


def save_splits(splits: dict[str, pd.DataFrame]):
    """Save splits as CSV files."""
    SPLITS_DIR.mkdir(parents=True, exist_ok=True)
    for name, df in splits.items():
        path = SPLITS_DIR / f"{name}.csv"
        df.to_csv(path, index=False)
        print(f"Saved {path} ({len(df)} rows)")


if __name__ == "__main__":
    print("Preprocessing GoEmotions → Ekman 7-class...")
    splits = preprocess_goemotions()
    save_splits(splits)
    print("Done.")
