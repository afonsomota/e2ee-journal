// lib/config.dart
//
// Shared app configuration constants.

/// Base URL for the FastAPI backend.
///
/// Override via the `API_BASE_URL` compile-time environment variable:
///   flutter run --dart-define=API_BASE_URL=https://api.example.com
const String apiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'http://localhost:8000',
);
