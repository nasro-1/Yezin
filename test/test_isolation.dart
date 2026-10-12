import 'dart:async';
import 'dart:io';
import 'package:path/path.dart' as p;

Future<T> withSharedConfigLock<T>(Future<T> Function() action) async {
  final appData = Platform.environment['APPDATA'] ??
      p.join(Platform.environment['USERPROFILE'] ?? 'C:/', 'AppData', 'Roaming');
  final lockFile = File(p.join(appData, 'Bayaa', 'test_config.lock'));
  await lockFile.parent.create(recursive: true);

  RandomAccessFile? handle;
  while (handle == null) {
    try {
      await lockFile.create(exclusive: true);
      handle = await lockFile.open(mode: FileMode.writeOnly);
    } on FileSystemException {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  try {
    return await action();
  } finally {
    await handle.close();
    try {
      await lockFile.delete();
    } on FileSystemException {
      // Another completed waiter may have already removed the lock marker.
    }
  }
}
