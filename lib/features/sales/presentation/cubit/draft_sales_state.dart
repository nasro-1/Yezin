import 'package:equatable/equatable.dart';

import '../../data/models/sale_draft_model.dart';

enum DraftSalesStatus { initial, loading, loaded, saving, error, conflict }

class DraftSalesState extends Equatable {
  const DraftSalesState({
    this.status = DraftSalesStatus.initial,
    this.drafts = const [],
    this.activeDraftId,
    this.message,
    this.conflictDraftId,
  });

  final DraftSalesStatus status;
  final List<SaleDraft> drafts;
  final String? activeDraftId;
  final String? message;
  final String? conflictDraftId;

  SaleDraft? get activeDraft {
    for (final draft in drafts) {
      if (draft.id == activeDraftId) return draft;
    }
    return null;
  }

  List<SaleDraft> get openDrafts =>
      drafts.where((draft) => !draft.isHeld).toList(growable: false);
  List<SaleDraft> get heldDrafts =>
      drafts.where((draft) => draft.isHeld).toList(growable: false);

  DraftSalesState copyWith({
    DraftSalesStatus? status,
    List<SaleDraft>? drafts,
    Object? activeDraftId = _unset,
    Object? message = _unset,
    Object? conflictDraftId = _unset,
  }) =>
      DraftSalesState(
        status: status ?? this.status,
        drafts: List.unmodifiable(drafts ?? this.drafts),
        activeDraftId: identical(activeDraftId, _unset)
            ? this.activeDraftId
            : activeDraftId as String?,
        message: identical(message, _unset) ? this.message : message as String?,
        conflictDraftId: identical(conflictDraftId, _unset)
            ? this.conflictDraftId
            : conflictDraftId as String?,
      );

  static const _unset = Object();

  @override
  List<Object?> get props =>
      [status, drafts, activeDraftId, message, conflictDraftId];
}

class DraftSalesInitial extends DraftSalesState {
  const DraftSalesInitial() : super();
}

class DraftSalesLoaded extends DraftSalesState {
  const DraftSalesLoaded({
    required super.drafts,
    super.activeDraftId,
  }) : super(status: DraftSalesStatus.loaded);
}

class DraftSalesConflict extends DraftSalesState {
  const DraftSalesConflict({
    required super.drafts,
    required super.conflictDraftId,
    super.activeDraftId,
    super.message,
  }) : super(status: DraftSalesStatus.conflict);
}
