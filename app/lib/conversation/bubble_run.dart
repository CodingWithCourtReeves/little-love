/// Grouping of consecutive messages into runs, iMessage/Telegram style (#84).
///
/// A run is consecutive messages from one sender with nothing between them: a
/// day separator, a gap header or a call-log row breaks it, as does a change
/// of sender. Only the run's last bubble carries the tail, bubbles inside a
/// run sit [inRunGap] apart, and a new sender starts [newRunGap] below.
library;

/// Where a bubble sits in its run.
enum RunPosition {
  /// Alone: both the start and the end of its run.
  single,
  first,
  middle,
  last;

  /// Builds the position from whether a run starts at / ends after the row.
  static RunPosition of({required bool starts, required bool ends}) =>
      switch ((starts, ends)) {
        (true, true) => single,
        (true, false) => first,
        (false, false) => middle,
        (false, true) => last,
      };

  bool get startsRun => this == single || this == first;
  bool get endsRun => this == single || this == last;

  /// Only the run's last bubble (or a lone one) is drawn with a tail.
  bool get hasTail => endsRun;
}

/// Space between two bubbles of the same run.
const double inRunGap = 2;

/// Space above the first bubble of a run, where the sender changed.
const double newRunGap = 10;

/// Space above a row at [position]. A row straight under a day separator or
/// gap header gets none: the separator brings its own spacing.
double runGapAbove(RunPosition position, {required bool afterSeparator}) {
  if (afterSeparator) return 0;
  return position.startsRun ? newRunGap : inRunGap;
}
