import 'dart:io';

import 'package:bayaa_pos/core/logging/file_logger.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('logger drains accepted writes and repeated shutdown is safe', () async {
    final directory =
        await Directory.systemTemp.createTemp('bayaa_file_logger_');
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });

    final logger = FileLogger.instance;
    await logger.initialize(directory.path);
    for (var index = 0; index < 1000; index++) {
      FileLogger.info('accepted-write-$index');
    }

    final firstShutdown = logger.shutdown();
    final secondShutdown = logger.shutdown();
    await Future.wait([firstShutdown, secondShutdown]);
    await logger.shutdown();

    final log = File(
      p.join(
        directory.path,
        'bayaa_${DateTime.now().year}'
        '${DateTime.now().month.toString().padLeft(2, '0')}'
        '${DateTime.now().day.toString().padLeft(2, '0')}.log',
      ),
    );
    final contents = await log.readAsString();
    expect(contents, contains('accepted-write-0'));
    expect(contents, contains('accepted-write-999'));
    expect(contents, contains('FileLogger shutting down'));

    for (var cycle = 0; cycle < 3; cycle++) {
      await logger.initialize(directory.path);
      FileLogger.info('reinitialize-cycle-$cycle');
      await logger.shutdown();
    }
  });
}
