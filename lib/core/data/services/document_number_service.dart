import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class DocumentNumberService {
  static Future<String> next(
    DatabaseExecutor db, {
    required String sequenceKey,
    required String prefix,
    String? year,
    String? table,
    String column = 'reference',
  }) async {
    final key = year == null ? sequenceKey : '$sequenceKey-$year';
    final rows = await db.query(
      'document_sequences',
      columns: ['next_value'],
      where: 'sequence_key = ?',
      whereArgs: [key],
    );
    var nextValue =
        rows.isEmpty ? 1 : (rows.first['next_value'] as num).toInt();
    final format = year == null ? '$prefix-%06d' : '$prefix-$year-%06d';

    while (true) {
      final candidate =
          format.replaceFirst('%06d', nextValue.toString().padLeft(6, '0'));
      if (table == null) break;
      final existing = await db.query(
        table,
        columns: [column],
        where: '$column = ?',
        whereArgs: [candidate],
        limit: 1,
      );
      if (existing.isEmpty) break;
      nextValue++;
    }

    await db.insert(
      'document_sequences',
      {'sequence_key': key, 'next_value': nextValue + 1},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    return format.replaceFirst('%06d', nextValue.toString().padLeft(6, '0'));
  }
}
