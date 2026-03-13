"""Download and cache datasets for emotion classification."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

from datasets import load_dataset


def download_goemotions():
    """Download GoEmotions simplified from Hugging Face."""
    print("Downloading GoEmotions (simplified)...")
    ds = load_dataset("google-research-datasets/go_emotions", "simplified")
    print(f"  Train: {len(ds['train'])} examples")
    print(f"  Validation: {len(ds['validation'])} examples")
    print(f"  Test: {len(ds['test'])} examples")
    return ds


if __name__ == "__main__":
    ds = download_goemotions()
    print("Done. Dataset cached by Hugging Face datasets library.")
