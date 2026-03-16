// native/fhe_wrapper.cpp
//
// Thin C API over concrete-ml's FHEModelClient, implemented via Python
// embedding (Python.h).  This lets the Dart app call FHE operations directly
// without an HTTP sidecar, while still relying on the concrete-ml Python
// package for the actual TFHE runtime.
//
// Public API (declared as extern "C"):
//
//   int      fhe_init(const char* helper_py_path,
//                     const char* client_zip_path,
//                     const char* key_dir);
//   uint8_t* fhe_get_eval_key(int* key_len);
//   uint8_t* fhe_encrypt(const float* features, int n, int* out_len);
//   float*   fhe_decrypt(const uint8_t* in, int in_len, int* n_classes);
//   void     fhe_free(void* ptr);
//
// Memory contract:
//   fhe_get_eval_key, fhe_encrypt, fhe_decrypt allocate and return a heap
//   buffer.  The caller (Dart FFI) must release it with fhe_free().
//
// Python environment:
//   Set FHE_PYTHON_HOME to the venv root before loading this library so that
//   Python finds concrete-ml.  E.g.:
//     export FHE_PYTHON_HOME=/path/to/fhe_client/.venv

#include <Python.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// ── Internal state ─────────────────────────────────────────────────────────

static PyObject* g_module = nullptr; // fhe_helper module
static int g_python_initialized = 0;

// ── Helpers ────────────────────────────────────────────────────────────────

/// Print Python exception and clear it.
static void print_and_clear_err() {
  if (PyErr_Occurred()) {
    PyErr_Print();
    PyErr_Clear();
  }
}

/// Copy a PyBytes object into a newly malloc'd C buffer; return it.
/// Sets *len.  Returns nullptr on failure.
static uint8_t* bytes_to_buf(PyObject* py_bytes, int* len) {
  if (!py_bytes || !PyBytes_Check(py_bytes)) {
    print_and_clear_err();
    *len = 0;
    return nullptr;
  }
  Py_ssize_t size = PyBytes_Size(py_bytes);
  uint8_t* buf = reinterpret_cast<uint8_t*>(malloc(size));
  if (buf) {
    memcpy(buf, PyBytes_AsString(py_bytes), size);
    *len = static_cast<int>(size);
  } else {
    *len = 0;
  }
  return buf;
}

// ── Exported API ───────────────────────────────────────────────────────────

extern "C" {

/// Initialise the Python interpreter, import fhe_helper.py, and call setup().
///
/// helper_py_path  : absolute path to fhe_helper.py (extracted from assets)
/// client_zip_path : absolute path to client.zip    (extracted from assets)
/// key_dir         : directory for storing FHE key files
///
/// Returns 0 on success, -1 on failure.
int fhe_init(const char* helper_py_path,
             const char* client_zip_path,
             const char* key_dir) {
  // ── Python initialisation (once) ─────────────────────────────────────────
  if (!g_python_initialized) {
    // Honour FHE_PYTHON_HOME to point at the venv (sets sys.prefix).
    const char* python_home = getenv("FHE_PYTHON_HOME");
    if (python_home) {
      wchar_t* wide = Py_DecodeLocale(python_home, nullptr);
      if (wide) {
        Py_SetPythonHome(wide);
        // Note: Py_SetPythonHome transfers ownership of the wide string to
        // CPython so we must NOT call PyMem_RawFree here.
      }
    }
    Py_Initialize();
    g_python_initialized = 1;
  }

  // ── Add helper_py directory to sys.path ──────────────────────────────────
  char dir[4096];
  strncpy(dir, helper_py_path, sizeof(dir) - 1);
  dir[sizeof(dir) - 1] = '\0';
  char* last_sep = strrchr(dir, '/');
  if (!last_sep) last_sep = strrchr(dir, '\\');
  if (last_sep) *last_sep = '\0';

  PyObject* sys_path = PySys_GetObject("path"); // borrowed ref
  if (sys_path) {
    PyObject* py_dir = PyUnicode_FromString(dir);
    PyList_Insert(sys_path, 0, py_dir);
    Py_DECREF(py_dir);
  }

  // ── Import (or reload) the fhe_helper module ─────────────────────────────
  Py_XDECREF(g_module);
  g_module = PyImport_ImportModule("fhe_helper");
  if (!g_module) {
    print_and_clear_err();
    fprintf(stderr, "[fhe_wrapper] Failed to import fhe_helper from %s\n", dir);
    return -1;
  }

  // ── Call fhe_helper.setup(client_zip_path, key_dir) ──────────────────────
  PyObject* result = PyObject_CallMethod(
      g_module, "setup", "ss", client_zip_path, key_dir);
  if (!result) {
    print_and_clear_err();
    fprintf(stderr, "[fhe_wrapper] fhe_helper.setup() failed\n");
    Py_DECREF(g_module);
    g_module = nullptr;
    return -1;
  }
  Py_DECREF(result);
  return 0;
}

/// Return the serialised evaluation key.  Caller must fhe_free() the buffer.
uint8_t* fhe_get_eval_key(int* key_len) {
  if (!g_module) { *key_len = 0; return nullptr; }

  PyObject* res = PyObject_CallMethod(g_module, "get_eval_key", nullptr);
  uint8_t* buf = bytes_to_buf(res, key_len);
  Py_XDECREF(res);
  return buf;
}

/// Quantise, encrypt and serialise float32 features.
/// features[0..n-1] must be the 200-dim L2-normalised LSA vector.
/// Caller must fhe_free() the returned buffer.
uint8_t* fhe_encrypt(const float* features, int n, int* out_len) {
  if (!g_module) { *out_len = 0; return nullptr; }

  // Pass raw float bytes to Python; fhe_helper.encrypt() wraps them into numpy
  PyObject* input_bytes = PyBytes_FromStringAndSize(
      reinterpret_cast<const char*>(features),
      static_cast<Py_ssize_t>(n) * sizeof(float));
  if (!input_bytes) { *out_len = 0; return nullptr; }

  PyObject* res = PyObject_CallMethod(g_module, "encrypt", "O", input_bytes);
  Py_DECREF(input_bytes);

  uint8_t* buf = bytes_to_buf(res, out_len);
  Py_XDECREF(res);
  return buf;
}

/// Deserialise, decrypt and dequantise an FHE inference result.
/// Returns a float buffer of length *n_classes (5 for this model).
/// Caller must fhe_free() the returned buffer.
float* fhe_decrypt(const uint8_t* in, int in_len, int* n_classes) {
  if (!g_module) { *n_classes = 0; return nullptr; }

  PyObject* input_bytes = PyBytes_FromStringAndSize(
      reinterpret_cast<const char*>(in),
      static_cast<Py_ssize_t>(in_len));
  if (!input_bytes) { *n_classes = 0; return nullptr; }

  PyObject* res = PyObject_CallMethod(g_module, "decrypt", "O", input_bytes);
  Py_DECREF(input_bytes);

  int len = 0;
  uint8_t* raw = bytes_to_buf(res, &len);
  Py_XDECREF(res);

  if (!raw) { *n_classes = 0; return nullptr; }
  *n_classes = len / static_cast<int>(sizeof(float));
  return reinterpret_cast<float*>(raw);
}

/// Release a buffer returned by fhe_get_eval_key, fhe_encrypt, or fhe_decrypt.
void fhe_free(void* ptr) { free(ptr); }

} // extern "C"
