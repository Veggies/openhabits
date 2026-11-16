import 'package:core/core.dart';

/// An in-memory store holding the winning change for each field, for
/// testing the merge rule. The server and apps keep the same state in SQL.
class FieldStore {
  final _fields = <(String, String, String), Change>{};

  /// Applies [change] if it wins under [shouldApply]. Returns whether it did.
  bool apply(Change change) {
    final key = (change.table, change.rowId, change.field);
    if (!shouldApply(change, _fields[key])) return false;
    _fields[key] = change;
    return true;
  }

  /// The current value of every field in a row, or null if the row is
  /// unknown or deleted.
  Map<String, Object?>? row(String table, String rowId) {
    final fields = {
      for (final MapEntry(:key, :value) in _fields.entries)
        if (key.$1 == table && key.$2 == rowId) key.$3: value.value,
    };
    if (fields.isEmpty || fields[deletedField] == true) return null;
    return fields..remove(deletedField);
  }
}
