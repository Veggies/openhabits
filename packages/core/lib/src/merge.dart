import 'change.dart';

/// Decides whether [incoming] should replace [current], the change that last
/// set the same table, row and field. [current] is null if that field has
/// never been written.
///
/// Both the server and every client use this rule. For devices to converge,
/// it must give the same answer no matter what order changes arrive in, and
/// no matter how many times the same change arrives.
bool shouldApply(Change incoming, Change? current) {
  // Last write wins on every field, including the deleted flag, so a later
  // restore (deleted = false) brings a habit back. Equal
  // timestamps mean the same change was delivered twice, so it's ignored.
  return current == null || incoming.hlc > current.hlc;
}
