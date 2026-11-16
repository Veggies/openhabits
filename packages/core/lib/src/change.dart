import 'hlc.dart';

/// Field name used to mark a row as deleted (a "tombstone"). Rows are never
/// removed outright, so a deletion can sync to other devices like any edit.
const deletedField = '_deleted';

/// One field-level edit: the unit of sync.
///
/// Creating a habit produces one change per field. Editing its name produces
/// one change, and deleting it sets [deletedField] to true.
class Change {
  final String table;
  final String rowId;
  final String field;

  /// Any JSON-encodable value.
  final Object? value;
  final Hlc hlc;

  const Change({
    required this.table,
    required this.rowId,
    required this.field,
    required this.value,
    required this.hlc,
  });

  Map<String, Object?> toJson() => {
    'table': table,
    'rowId': rowId,
    'field': field,
    'value': value,
    'hlc': hlc.pack(),
  };

  factory Change.fromJson(Map<String, Object?> json) => Change(
    table: json['table'] as String,
    rowId: json['rowId'] as String,
    field: json['field'] as String,
    value: json['value'],
    hlc: Hlc.parse(json['hlc'] as String),
  );

  @override
  String toString() => '$table/$rowId.$field=$value @$hlc';
}
