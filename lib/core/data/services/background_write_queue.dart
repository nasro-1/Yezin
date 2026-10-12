// lib/core/data/services/background_write_queue.dart

import 'dart:async';
import 'dart:collection';

/// Shared gate that serializes database writes and exclusive lifecycle
/// operations such as close/reopen, mode switching, and restore.
class DatabaseLifecycleCoordinator {
  DatabaseLifecycleCoordinator();

  static final DatabaseLifecycleCoordinator instance = DatabaseLifecycleCoordinator();

  final Queue<_LifecycleRequest> _pendingRequests = Queue();
  final List<Completer<void>> _stateWaiters = <Completer<void>>[];
  bool _dispatching = false;
  int _activeWriteCount = 0;
  bool _exclusiveActive = false;

  bool get isExclusiveActive => _exclusiveActive;
  int get activeWriteCount => _activeWriteCount;

  Future<T> withWriteAccess<T>(Future<T> Function() action) async {
    return _enqueue(action, exclusive: false);
  }

  Future<T> withExclusiveAccess<T>(Future<T> Function() action) async {
    return _enqueue(action, exclusive: true);
  }

  Future<T> _enqueue<T>(Future<T> Function() action, {required bool exclusive}) {
    final request = _LifecycleRequest<T>(
      action: action,
      exclusive: exclusive,
    );
    _pendingRequests.add(request);
    _dispatchIfNeeded();
    return request.future;
  }

  void _dispatchIfNeeded() {
    if (_dispatching) {
      return;
    }

    _dispatching = true;
    _dispatchQueue().whenComplete(() {
      _dispatching = false;
    });
  }

  Future<void> _dispatchQueue() async {
    while (_pendingRequests.isNotEmpty) {
      final request = _pendingRequests.first;
      if (!_canStart(request)) {
        await _waitForStateChange();
        continue;
      }

      _pendingRequests.removeFirst();
      await _executeRequest(request);
    }
  }

  bool _canStart(_LifecycleRequest request) {
    if (request.exclusive) {
      return _activeWriteCount == 0 && !_exclusiveActive;
    }
    return !_exclusiveActive;
  }

  Future<void> _executeRequest(_LifecycleRequest request) async {
    if (request.exclusive) {
      _exclusiveActive = true;
    } else {
      _activeWriteCount += 1;
    }

    try {
      final value = await request.action();
      if (!request.completer.isCompleted) {
        request.completer.complete(value);
      }
    } catch (error, stackTrace) {
      if (!request.completer.isCompleted) {
        request.completer.completeError(error, stackTrace);
      }
    } finally {
      if (request.exclusive) {
        _exclusiveActive = false;
      } else {
        _activeWriteCount -= 1;
      }
      _notifyStateChange();
    }
  }

  Future<void> _waitForStateChange() async {
    final waiter = Completer<void>();
    _stateWaiters.add(waiter);
    await waiter.future;
  }

  void _notifyStateChange() {
    if (_stateWaiters.isEmpty) {
      return;
    }

    final waiters = List<Completer<void>>.from(_stateWaiters);
    _stateWaiters.clear();
    for (final waiter in waiters) {
      if (!waiter.isCompleted) {
        waiter.complete();
      }
    }
  }
}

class _LifecycleRequest<T> {
  _LifecycleRequest({
    required this.action,
    required this.exclusive,
  }) : completer = Completer<T>();

  final Future<T> Function() action;
  final bool exclusive;
  final Completer<T> completer;

  Future<T> get future => completer.future;
}

/// Asynchronous write queue that processes operations without blocking UI.
class BackgroundWriteQueue {
  BackgroundWriteQueue({DatabaseLifecycleCoordinator? lifecycleCoordinator})
      : lifecycleCoordinator = lifecycleCoordinator ?? DatabaseLifecycleCoordinator.instance;

  final Queue<_QueuedWrite> _queue = Queue();
  final DatabaseLifecycleCoordinator lifecycleCoordinator;

  Future<void>? _processing;
  Future<void>? _disposal;
  bool _started = false;
  bool _disposed = false;
  int _processedCount = 0;
  int _failedCount = 0;

  void start() {
    if (_disposed) {
      throw StateError('Cannot start a disposed background write queue.');
    }
    _started = true;
    _startProcessing();
  }

  Future<void> enqueue(Future<void> Function() writeOperation) {
    if (_disposed) {
      return Future<void>.error(
        StateError('Cannot enqueue a write on a disposed background write queue.'),
      );
    }

    final completer = Completer<void>();
    final queuedWrite = _QueuedWrite(
      operation: writeOperation,
      timestamp: DateTime.now(),
      completer: completer,
    );

    _queue.add(queuedWrite);
    scheduleMicrotask(_startProcessing);
    return completer.future;
  }

  void _startProcessing() {
    if (!_started || _processing != null || _queue.isEmpty) return;
    _processing = _processQueue();
  }

  Future<void> _processQueue() async {
    try {
      while (_queue.isNotEmpty) {
        final write = _queue.removeFirst();
        try {
          await lifecycleCoordinator.withWriteAccess(write.operation);
          _processedCount++;
          write.completer.complete();
        } catch (error, stackTrace) {
          _failedCount++;
          write.completer.completeError(error, stackTrace);
        }
      }
    } finally {
      _processing = null;
      _startProcessing();
    }
  }

  Map<String, int> getStats() {
    return {
      'queued': _queue.length,
      'processed': _processedCount,
      'failed': _failedCount,
    };
  }

  void clear() {
    while (_queue.isNotEmpty) {
      _queue.removeFirst().completer.completeError(
            StateError('Queued write was cancelled.'),
          );
    }
  }

  Future<void> dispose() {
    if (_disposal != null) return _disposal!;
    _disposed = true;
    _started = true;
    _startProcessing();
    return _disposal = _processing ?? Future<void>.value();
  }
}

class _QueuedWrite {
  final Future<void> Function() operation;
  final DateTime timestamp;
  final Completer<void> completer;

  _QueuedWrite({
    required this.operation,
    required this.timestamp,
    required this.completer,
  });
}
