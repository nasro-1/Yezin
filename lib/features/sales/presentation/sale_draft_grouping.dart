import '../data/models/sale_draft_model.dart';

class SaleDraftGroup {
  const SaleDraftGroup(this.title, this.drafts);

  final String title;
  final List<SaleDraft> drafts;
}

List<SaleDraft> uniqueSaleDrafts(Iterable<SaleDraft> drafts) {
  final unique = <SaleDraft>[];
  final seenIds = <String>{};
  for (final draft in drafts) {
    if (seenIds.add(draft.id)) {
      unique.add(draft);
    }
  }
  return unique;
}

List<SaleDraft> selectableSaleDrafts(Iterable<SaleDraftGroup> groups) =>
    uniqueSaleDrafts(groups.expand((group) => group.drafts));

List<SaleDraftGroup> groupSaleDrafts(
  List<SaleDraft> drafts, {
  required String? userId,
  required String? role,
}) {
  final uniqueDrafts = uniqueSaleDrafts(drafts);
  if (role?.toLowerCase() == 'admin') {
    return [SaleDraftGroup('All Open Sales', List.unmodifiable(uniqueDrafts))];
  }

  final mine = uniqueDrafts.where((draft) => draft.ownerId == userId).toList();
  final shared = uniqueDrafts
      .where((draft) =>
          draft.ownerId != userId &&
          draft.visibility == SaleDraftVisibility.shared)
      .toList();
  return [
    if (mine.isNotEmpty)
      SaleDraftGroup('My Open Sales', List.unmodifiable(mine)),
    if (shared.isNotEmpty)
      SaleDraftGroup('Shared Sales', List.unmodifiable(shared)),
  ];
}
