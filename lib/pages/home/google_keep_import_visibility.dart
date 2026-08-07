bool shouldShowGoogleKeepImportAction({
  required bool isSearchMode,
  required bool isAllNotesView,
  required bool hasLabelFilters,
  required bool isInsideFolder,
  required bool isFolderMode,
  required bool hasStoredNotes,
}) =>
    !isSearchMode &&
    isAllNotesView &&
    !hasLabelFilters &&
    !isInsideFolder &&
    !isFolderMode &&
    !hasStoredNotes;
