"""
Experiment: FHE compile time, circuit complexity, and artifact sizes.

For each model configuration, measures:
1. FHE compile time (model.compile())
2. Circuit complexity (model.fhe_circuit attributes)
3. Artifact sizes (client.zip and server.zip via FHEModelDev)
4. Clear-mode predict time (single batch of 200 samples)

Phase 1: n_bits=3 configs (faster to compile)
Phase 2: n_bits=8 on representative configs (may be slow)

NOTE: FHEModelDev must be imported AFTER model.fit() completes.
Importing it before fit() causes an LLVM crash on Apple Silicon
with Concrete ML 1.9.0 / concrete-python 2.10.0.
"""

import json
import shutil
import sys
import tempfile
import time
from pathlib import Path

import numpy as np
import pandas as pd
from sklearn.decomposition import TruncatedSVD
from sklearn.feature_extraction.text import TfidfVectorizer
from sklearn.metrics import accuracy_score, f1_score
from sklearn.preprocessing import LabelEncoder, Normalizer
from sklearn.utils.class_weight import compute_sample_weight

sys.path.insert(0, str(Path(__file__).parent.parent))
from config import LABELS, SPLITS_DIR

# IMPORTANT: Only import FHEXGBClassifier here.
# FHEModelDev is imported lazily after model.fit() to avoid LLVM crash.
from concrete.ml.sklearn import XGBClassifier as FHEXGBClassifier

# ── Experiment grid ─────────────────────────────────────────────────────────

PHASE1_GRID = [
    {"lsa": 50,  "n_estimators": 50,  "max_depth": 3, "n_bits": 3, "tag": "p1_lsa50_e50_d3_b3"},
    {"lsa": 50,  "n_estimators": 50,  "max_depth": 5, "n_bits": 3, "tag": "p1_lsa50_e50_d5_b3"},
    {"lsa": 200, "n_estimators": 50,  "max_depth": 3, "n_bits": 3, "tag": "p1_lsa200_e50_d3_b3"},
    {"lsa": 200, "n_estimators": 200, "max_depth": 3, "n_bits": 3, "tag": "p1_lsa200_e200_d3_b3"},
]

PHASE2_GRID = [
    {"lsa": 50,  "n_estimators": 50,  "max_depth": 3, "n_bits": 8, "tag": "p2_lsa50_e50_d3_b8"},
    {"lsa": 200, "n_estimators": 200, "max_depth": 3, "n_bits": 8, "tag": "p2_lsa200_e200_d3_b8"},
]

TFIDF_KWARGS = dict(
    max_features=5000,
    ngram_range=(1, 2),
    sublinear_tf=True,
    strip_accents="unicode",
    min_df=5,
)

CALIBRATION_SAMPLES = 200
PREDICT_SAMPLES = 200


def load_raw_data():
    """Load train/test CSVs and encode labels."""
    train_df = pd.read_csv(SPLITS_DIR / "train.csv")
    test_df = pd.read_csv(SPLITS_DIR / "test.csv")

    le = LabelEncoder()
    le.classes_ = np.array(LABELS)
    y_train = le.transform(train_df["label"].values)
    y_test = le.transform(test_df["label"].values)

    sample_weights = compute_sample_weight("balanced", y_train)

    print(f"Train: {len(y_train)} samples, Test: {len(y_test)} samples")
    return train_df["text"].values, y_train, test_df["text"].values, y_test, sample_weights


def build_features(texts_train, texts_test, n_components):
    """Fit TF-IDF + TruncatedSVD + L2 normalizer and transform both sets."""
    tfidf = TfidfVectorizer(**TFIDF_KWARGS)
    X_train_tfidf = tfidf.fit_transform(texts_train)
    X_test_tfidf = tfidf.transform(texts_test)

    svd = TruncatedSVD(n_components=n_components, random_state=42)
    X_train_svd = svd.fit_transform(X_train_tfidf)
    X_test_svd = svd.transform(X_test_tfidf)

    normalizer = Normalizer(norm="l2")
    X_train = normalizer.fit_transform(X_train_svd)
    X_test = normalizer.transform(X_test_svd)

    return X_train, X_test


def format_bytes(n):
    """Human-readable byte size."""
    if n < 1024:
        return f"{n} B"
    elif n < 1024 * 1024:
        return f"{n / 1024:.1f} KB"
    else:
        return f"{n / (1024 * 1024):.1f} MB"


def inspect_circuit(model):
    """Extract circuit info from a compiled model."""
    info = {}

    circuit = getattr(model, "fhe_circuit", None)
    if circuit is None:
        info["status"] = "no fhe_circuit attribute"
        return info

    info["status"] = "compiled"

    # Numeric attributes
    for attr in [
        "complexity",
        "size_of_secret_keys", "size_of_bootstrap_keys",
        "size_of_keyswitch_keys", "size_of_inputs", "size_of_outputs",
        "programmable_bootstrap_count", "key_switch_count",
        "packing_key_switch_count", "clear_addition_count",
        "encrypted_addition_count", "clear_multiplication_count",
        "encrypted_negation_count",
    ]:
        val = getattr(circuit, attr, None)
        if val is not None:
            try:
                info[attr] = float(val) if isinstance(val, float) else int(val)
            except (TypeError, ValueError):
                info[attr] = str(val)

    # Error probabilities
    for attr in ["global_p_error", "p_error"]:
        val = getattr(circuit, attr, None)
        if val is not None:
            info[attr] = float(val)

    # Graph representation
    try:
        circuit_str = str(circuit)
        if len(circuit_str) < 5000:
            info["graph"] = circuit_str
    except Exception:
        pass

    # Statistics dict
    try:
        stats = circuit.statistics
        if isinstance(stats, dict):
            info["statistics"] = {str(k): str(v) for k, v in stats.items()}
    except Exception:
        pass

    return info


def save_and_measure_artifacts(model, tag):
    """Save FHE model to temp dir and return artifact sizes.

    IMPORTANT: Imports FHEModelDev lazily to avoid LLVM crash.
    """
    from concrete.ml.deployment import FHEModelDev  # Lazy import!

    tmpdir = tempfile.mkdtemp(prefix=f"fhe_exp_{tag}_")
    try:
        dev = FHEModelDev(path_dir=tmpdir, model=model)
        dev.save()

        sizes = {}
        for name in ["client.zip", "server.zip"]:
            p = Path(tmpdir) / name
            sizes[name] = p.stat().st_size if p.exists() else 0

        total = sum(f.stat().st_size for f in Path(tmpdir).rglob("*") if f.is_file())
        sizes["total_dir_bytes"] = total

        file_list = {}
        for f in sorted(Path(tmpdir).rglob("*")):
            if f.is_file():
                file_list[f.name] = f.stat().st_size
        sizes["files"] = file_list

        return sizes
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)


def run_config(combo, X_train, X_test, y_train, y_test, sample_weights):
    """Run a single config: train, compile, inspect, measure artifacts."""
    lsa = combo["lsa"]
    n_est = combo["n_estimators"]
    depth = combo["max_depth"]
    n_bits = combo["n_bits"]
    tag = combo["tag"]

    entry = {
        "tag": tag,
        "lsa_components": lsa,
        "n_estimators": n_est,
        "max_depth": depth,
        "n_bits": n_bits,
    }

    # ── Train ───────────────────────────────────────────────────────────
    print(f"  Training FHE XGBoost...", end=" ", flush=True)
    t0 = time.time()
    model = FHEXGBClassifier(
        n_bits=n_bits,
        n_estimators=n_est,
        max_depth=depth,
    )
    model.fit(X_train, y_train, sample_weight=sample_weights)
    train_time = time.time() - t0
    entry["train_time_s"] = round(train_time, 2)
    print(f"done ({train_time:.1f}s)")

    # ── Clear-mode predict ──────────────────────────────────────────────
    print(f"  Clear-mode predict ({PREDICT_SAMPLES} samples)...", end=" ", flush=True)
    rng = np.random.RandomState(123)
    pred_idx = rng.choice(len(X_test), min(PREDICT_SAMPLES, len(X_test)), replace=False)
    X_pred = X_test[pred_idx]
    y_pred_true = y_test[pred_idx]

    t0 = time.time()
    y_pred = model.predict(X_pred)
    predict_time = time.time() - t0
    entry["clear_predict_time_s"] = round(predict_time, 3)
    entry["clear_predict_per_sample_ms"] = round(predict_time / len(X_pred) * 1000, 3)

    acc = float(accuracy_score(y_pred_true, y_pred))
    f1 = float(f1_score(y_pred_true, y_pred, average="macro"))
    entry["accuracy"] = round(acc, 4)
    entry["f1_macro"] = round(f1, 4)
    print(f"acc={acc:.4f}, f1={f1:.4f} ({predict_time:.2f}s)")

    # ── Compile ─────────────────────────────────────────────────────────
    print(f"  Compiling FHE circuit...", end=" ", flush=True)
    rng = np.random.RandomState(42)
    cal_idx = rng.choice(len(X_train), CALIBRATION_SAMPLES, replace=False)
    X_cal = X_train[cal_idx]

    t0 = time.time()
    try:
        model.compile(X_cal)
        compile_time = time.time() - t0
        entry["compile_time_s"] = round(compile_time, 2)
        entry["compile_status"] = "success"
        print(f"done ({compile_time:.1f}s)")
    except Exception as e:
        compile_time = time.time() - t0
        entry["compile_time_s"] = round(compile_time, 2)
        entry["compile_status"] = f"error: {str(e)[:200]}"
        print(f"FAILED after {compile_time:.1f}s: {e}")
        return entry

    # ── Circuit inspection ──────────────────────────────────────────────
    print(f"  Inspecting circuit...", flush=True)
    circuit_info = inspect_circuit(model)
    entry["circuit_info"] = circuit_info

    # Print key circuit stats
    ci = circuit_info
    for k in ["size_of_secret_keys", "size_of_bootstrap_keys",
              "size_of_keyswitch_keys", "size_of_inputs", "size_of_outputs"]:
        if k in ci and isinstance(ci[k], (int, float)):
            print(f"    {k}: {format_bytes(int(ci[k]))}")
    if "programmable_bootstrap_count" in ci:
        print(f"    PBS count: {ci['programmable_bootstrap_count']}")
    if "complexity" in ci:
        print(f"    complexity: {ci['complexity']}")

    # ── Artifact sizes ──────────────────────────────────────────────────
    print(f"  Saving artifacts and measuring sizes...", end=" ", flush=True)
    t0 = time.time()
    artifact_sizes = save_and_measure_artifacts(model, tag)
    save_time = time.time() - t0
    entry["artifact_sizes"] = {
        "client_zip_bytes": artifact_sizes.get("client.zip", 0),
        "server_zip_bytes": artifact_sizes.get("server.zip", 0),
        "total_dir_bytes": artifact_sizes.get("total_dir_bytes", 0),
        "client_zip_human": format_bytes(artifact_sizes.get("client.zip", 0)),
        "server_zip_human": format_bytes(artifact_sizes.get("server.zip", 0)),
        "total_dir_human": format_bytes(artifact_sizes.get("total_dir_bytes", 0)),
        "files": artifact_sizes.get("files", {}),
    }
    entry["save_time_s"] = round(save_time, 2)
    print(f"done ({save_time:.1f}s)")
    print(f"    client.zip: {entry['artifact_sizes']['client_zip_human']}")
    print(f"    server.zip: {entry['artifact_sizes']['server_zip_human']}")
    print(f"    total:      {entry['artifact_sizes']['total_dir_human']}")

    return entry


def run_experiment():
    texts_train, y_train, texts_test, y_test, sample_weights = load_raw_data()

    feature_cache = {}
    all_results = []

    all_grids = [
        ("PHASE 1: n_bits=3 configs", PHASE1_GRID, 1),
        ("PHASE 2: n_bits=8 configs", PHASE2_GRID, 2),
    ]

    for phase_title, grid, phase_num in all_grids:
        print(f"\n{'='*80}")
        print(phase_title)
        print("=" * 80)

        for combo in grid:
            lsa = combo["lsa"]
            tag = combo["tag"]

            print(f"\n{'─'*70}")
            print(f"Config: LSA={lsa}, n_estimators={combo['n_estimators']}, "
                  f"max_depth={combo['max_depth']}, n_bits={combo['n_bits']} ({tag})")
            print(f"{'─'*70}")

            if lsa not in feature_cache:
                print(f"  Fitting TF-IDF + LSA({lsa}) + L2 norm...", end=" ", flush=True)
                t0 = time.time()
                X_train, X_test = build_features(texts_train, texts_test, lsa)
                feat_time = time.time() - t0
                feature_cache[lsa] = (X_train, X_test)
                print(f"done ({feat_time:.1f}s, features={X_train.shape[1]})")
            else:
                X_train, X_test = feature_cache[lsa]
                print(f"  Using cached LSA({lsa}) features ({X_train.shape[1]} dims)")

            entry = run_config(combo, X_train, X_test, y_train, y_test, sample_weights)
            entry["phase"] = phase_num
            all_results.append(entry)

            # Save intermediate results
            _save_results(all_results)

    # ── Summary ─────────────────────────────────────────────────────────
    _print_summary(all_results)


def _save_results(all_results):
    """Save results to JSON (called after each config for safety)."""
    # Make circuit_info JSON-serializable
    for e in all_results:
        ci = e.get("circuit_info", {})
        for k, v in list(ci.items()):
            if not isinstance(v, (str, int, float, bool, dict, list, type(None))):
                ci[k] = str(v)

    results = {
        "experiment": "fhe_compile_timing",
        "calibration_samples": CALIBRATION_SAMPLES,
        "predict_samples": PREDICT_SAMPLES,
        "configs": all_results,
    }

    out_path = Path(__file__).parent / "exp_fhe_compile_timing_results.json"
    with open(out_path, "w") as f:
        json.dump(results, f, indent=2)


def _print_summary(all_results):
    """Print formatted summary tables."""
    print("\n" + "=" * 130)
    print("SUMMARY TABLE")
    print("=" * 130)

    header = (
        f"{'Tag':<28} {'LSA':>4} {'nEst':>5} {'Dep':>4} {'nB':>3}"
        f" {'Acc':>7} {'F1':>7}"
        f" {'Train(s)':>9} {'Compile(s)':>11}"
        f" {'client.zip':>12} {'server.zip':>12}"
        f" {'PBS':>8} {'Complexity':>12}"
    )
    print(header)
    print("-" * len(header))

    for e in all_results:
        acc = e.get("accuracy", 0)
        f1 = e.get("f1_macro", 0)
        train_s = e.get("train_time_s", 0)

        status = e.get("compile_status", "?")
        if status == "success":
            compile_str = f"{e['compile_time_s']:>9.1f}s"
        else:
            compile_str = f"{'FAIL':>10}"

        client_str = e.get("artifact_sizes", {}).get("client_zip_human", "N/A")
        server_str = e.get("artifact_sizes", {}).get("server_zip_human", "N/A")

        ci = e.get("circuit_info", {})
        pbs = ci.get("programmable_bootstrap_count", "N/A")
        complexity = ci.get("complexity", "N/A")
        if isinstance(complexity, (int, float)):
            if complexity > 1e9:
                complexity_str = f"{complexity / 1e9:.2f}G"
            elif complexity > 1e6:
                complexity_str = f"{complexity / 1e6:.1f}M"
            else:
                complexity_str = f"{complexity:.0f}"
        else:
            complexity_str = str(complexity)

        print(
            f"{e['tag']:<28} {e.get('lsa_components', 0):>4} {e.get('n_estimators', 0):>5} "
            f"{e.get('max_depth', 0):>4} {e.get('n_bits', 0):>3}"
            f" {acc:>7.4f} {f1:>7.4f}"
            f" {train_s:>8.1f}s {compile_str:>11}"
            f" {client_str:>12} {server_str:>12}"
            f" {str(pbs):>8} {complexity_str:>12}"
        )

    # ── Key sizes ───────────────────────────────────────────────────────
    print(f"\n{'='*130}")
    print("KEY & CIRCUIT DETAILS")
    print("=" * 130)
    for e in all_results:
        ci = e.get("circuit_info", {})
        if ci.get("status") != "compiled":
            continue
        print(f"\n{e['tag']}:")
        for k in ["size_of_secret_keys", "size_of_bootstrap_keys",
                   "size_of_keyswitch_keys", "size_of_inputs", "size_of_outputs"]:
            v = ci.get(k)
            if v is not None:
                print(f"  {k}: {format_bytes(int(v))}")
        for k in ["programmable_bootstrap_count", "key_switch_count",
                   "packing_key_switch_count", "clear_addition_count",
                   "encrypted_addition_count", "clear_multiplication_count",
                   "encrypted_negation_count", "complexity",
                   "global_p_error", "p_error"]:
            v = ci.get(k)
            if v is not None:
                print(f"  {k}: {v}")

    out_path = Path(__file__).parent / "exp_fhe_compile_timing_results.json"
    print(f"\nResults saved to {out_path}")


if __name__ == "__main__":
    run_experiment()
