/// Cross-layer result type so failures never escape the data layer as bare
/// exceptions. UI reads [Ok] / [Err] and renders accordingly.
sealed class Result<T> {
  const Result();
}

final class Ok<T> extends Result<T> {
  const Ok(this.value);
  final T value;
}

final class Err<T> extends Result<T> {
  const Err(this.error);
  final AppError error;
}

/// Domain-facing error with a message safe to show a user.
class AppError {
  const AppError(this.message, {this.cause});
  final String message;
  final Object? cause;

  @override
  String toString() => message;
}
