from enum import StrEnum


class DocumentStatus(StrEnum):
    DRAFT = "draft"
    POSTED = "posted"
    CANCELLED = "cancelled"
    REVERSED = "reversed"


def can_transition(current: DocumentStatus, target: DocumentStatus) -> bool:
    return (current, target) in {
        (DocumentStatus.DRAFT, DocumentStatus.POSTED),
        (DocumentStatus.DRAFT, DocumentStatus.CANCELLED),
        (DocumentStatus.POSTED, DocumentStatus.REVERSED),
    }


def transition(current: DocumentStatus, target: DocumentStatus) -> DocumentStatus:
    if not can_transition(current, target):
        raise ValueError(f"Invalid document lifecycle transition: {current} -> {target}")
    return target
