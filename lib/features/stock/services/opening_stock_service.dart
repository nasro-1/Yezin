import 'package:uuid/uuid.dart';

import '../../../core/data/models/activity_log.dart';
import '../../../core/data/services/document_number_service.dart';
import '../../../core/data/services/persistence_initializer.dart';
import '../../../core/data/services/sqlite_manager.dart';
import '../../../core/security/permission_guard.dart';
import '../../../core/services/activity_logger.dart';
import '../../../core/network/authority_context.dart';
import '../../auth/data/models/user_model.dart';
import '../data/models/opening_stock_model.dart';
import '../data/repository/opening_stock_repository.dart';
import 'canonical_stock_posting_service.dart';

class OpeningStockService {
  final OpeningStockRepository repository;
  final CanonicalStockPostingService stockPosting;
  final ActivityLogger activityLogger;
  final Uuid _uuid;
  final SQLiteManager? sqliteManager;
  final AuthorityContext authorityContext;

  OpeningStockService({
    OpeningStockRepository? repository,
    this.stockPosting = const CanonicalStockPostingService(),
    ActivityLogger? activityLogger,
    Uuid? uuid,
    this.sqliteManager,
    AuthorityContext? authorityContext,
  })  : repository = repository ?? OpeningStockRepository(),
        activityLogger = activityLogger ?? ActivityLogger(),
      _uuid = uuid ?? const Uuid(),
      authorityContext = authorityContext ??
        AuthorityContext.fromProductConfig();

  Future<OpeningStockDocument> post({
    required List<OpeningStockLineInput> lines,
    required User user,
    DateTime? openingDate,
    String? reason,
    String? notes,
  }) async {
    PermissionGuard.requireOpeningStockPermission(user);
    if (authorityContext.writesToServer) {
      throw StateError(
        'Opening stock is server-authoritative but no server opening-stock API is configured.',
      );
    }
    _validateLines(lines);
    if (reason?.trim().isEmpty != false) {
      throw ArgumentError('Opening stock reason is required.');
    }

    final db = sqliteManager ??
        PersistenceInitializer.persistenceManager!.sqliteManager;
    final now = DateTime.now();
    final effectiveOpeningDate = openingDate ?? now;
    final documentId = _uuid.v4();
    late OpeningStockDocument document;

    await db.transaction((txn) async {
      final productsById = <String, Map<String, dynamic>>{};
      for (final input in lines) {
        final products = await txn.query(
          'products',
          columns: ['id', 'barcode', 'name'],
          where: 'id = ? AND is_active = 1',
          whereArgs: [input.productId],
          limit: 1,
        );
        if (products.isEmpty) {
          throw StateError('Product ${input.productId} not found.');
        }
        productsById[input.productId] = products.first;
      }
      final referenceNumber = await DocumentNumberService.next(
        txn,
        sequenceKey: 'opening_stock',
        prefix: 'OS',
        year: now.year.toString(),
        table: 'opening_stock_documents',
        column: 'reference_number',
      );
      final postedAt = DateTime.now();
      final documentLines = <OpeningStockLine>[];

      document = OpeningStockDocument(
        id: documentId,
        referenceNumber: referenceNumber,
        status: OpeningStockStatus.posted,
        openingDate: effectiveOpeningDate,
        reason: reason!.trim(),
        notes: notes?.trim().isEmpty == true ? null : notes?.trim(),
        postedAt: postedAt,
        postedBy: user.name,
        createdAt: now,
        lines: documentLines,
      );
      await repository.insertDocument(txn, document);

      for (final input in lines) {
        final product = productsById[input.productId]!;
        final line = OpeningStockLine(
          id: '${documentId}_${input.productId}',
          documentId: documentId,
          productId: input.productId,
          productBarcode: product['barcode'] as String?,
          productName: product['name'] as String,
          quantity: input.quantity,
          unitCost: input.unitCost,
          lineTotal: input.quantity * input.unitCost,
          createdAt: postedAt,
        );
        await repository.insertLine(txn, line);
        await stockPosting.post(
          txn: txn,
          movementId: line.id,
          productId: line.productId,
          quantityChange: line.quantity,
          movementType: 'opening_stock',
          referenceType: 'opening_stock',
          referenceId: documentId,
          notes: '${reason.trim()} - ${notes?.trim() ?? ''}'.trim(),
          userId: user.username,
          unitCost: input.unitCost,
          createdAt: postedAt,
        );
        documentLines.add(line);
      }

      await activityLogger.logActivityInTransaction(
        txn: txn,
        type: ActivityType.openingStockPosted,
        description: 'Posted opening stock: $referenceNumber',
        userName: user.name,
        eventKey: 'openingStockPosted',
        parameters: {
          'user': user.name,
          'reference': referenceNumber,
          'id': documentId,
          'lines': lines.length,
        },
        details: {
          'reference': referenceNumber,
          'lines': documentLines
              .map((line) => {
                    'product': line.productName,
                    'quantity': line.quantity,
                  })
              .toList(),
        },
        timestamp: postedAt,
      );
    });

    return document;
  }

  void _validateLines(List<OpeningStockLineInput> lines) {
    if (lines.isEmpty) {
      throw ArgumentError('Opening stock must contain at least one line.');
    }
    final productIds = <String>{};
    for (final line in lines) {
      if (line.productId.trim().isEmpty || line.quantity <= 0) {
        throw ArgumentError(
          'Opening stock quantities must be greater than zero.',
        );
      }
      if (line.unitCost < 0) {
        throw ArgumentError('Opening stock unit cost cannot be negative.');
      }
      if (!productIds.add(line.productId)) {
        throw ArgumentError(
          'A product can only appear once in an opening stock document.',
        );
      }
    }
  }
}
