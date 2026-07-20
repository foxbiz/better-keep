/// Returns the number of calendar days from [from] to [to].
///
/// The UTC values are synthetic date keys built from the original year, month,
/// and day. They do not convert either instant to UTC. This keeps daylight-
/// saving offset changes out of date-only recurrence calculations.
int calendarDayDelta(DateTime from, DateTime to) {
  final fromDate = DateTime.utc(from.year, from.month, from.day);
  final toDate = DateTime.utc(to.year, to.month, to.day);
  return toDate.difference(fromDate).inDays;
}
