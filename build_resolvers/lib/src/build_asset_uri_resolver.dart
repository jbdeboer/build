// Copyright (c) 2018, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';

// ignore: deprecated_member_use
import 'package:analyzer/analyzer.dart' show parseDirectives;
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/file_system/memory_file_system.dart';
import 'package:analyzer/src/generated/source.dart';
import 'package:build/build.dart' show AssetId, BuildStep;
import 'package:path/path.dart' as p;

class BuildAssetUriResolver extends UriResolver {
  final _cachedAssetDependencies = <AssetId, Set<AssetId>>{};
  final _cachedAssetContents = <AssetId, String>{};
  final resourceProvider = MemoryResourceProvider();

  /// The assets which are known to be readable at some point during the build.
  ///
  /// When actions can run out of order an asset can move from being readable
  /// (in the later phase) to being unreadable (in the earlier phase which ran
  /// later). If this happens we don't want to hide the asset from the analyzer.
  final seenAssets = Set<AssetId>();

  Future<void> performResolve(BuildStep buildStep, List<AssetId> entryPoints) {
    // Basic approach is to start at the first file, update it's contents
    // and see if it changed, then walk all files accessed by it.
    var visited = Set<AssetId>();
    var visiting = FutureGroup();

    void processAsset(AssetId assetId) {
      visited.add(assetId);

      visiting.add(buildStep.readAsString(assetId).then((contents) {
        var unit = parseDirectives(contents, suppressErrors: true);
        if (_cachedAssetContents[assetId] != contents) {
          if (_cachedAssetContents.containsKey(assetId)) {
            resourceProvider.updateFile(assetPath(assetId), contents);
          } else {
            resourceProvider.newFile(assetPath(assetId), contents);
          }
          _cachedAssetContents[assetId] = contents;
          var dependencies = unit.directives
              .whereType<UriBasedDirective>()
              .where((d) => !Uri.parse(d.uri.stringValue).isScheme('dart'))
              .map((d) => AssetId.resolve(d.uri.stringValue, from: assetId))
              .where((id) => id != null)
              .toSet();
          _cachedAssetDependencies[assetId] = dependencies;
        }
        _cachedAssetDependencies[assetId]
            .where((id) => !visited.contains(id))
            .forEach(processAsset);
      }, onError: (e) {
        if (seenAssets.contains(assetId)) return;
        _cachedAssetDependencies.remove(assetId);
        _cachedAssetContents.remove(assetId);
        final path = assetPath(assetId);
        if (resourceProvider.getFile(path).exists) {
          resourceProvider.deleteFile(path);
        }
      }));
    }

    entryPoints.forEach(processAsset);
    return visiting.future;
  }

  /// Attempts to parse [uri] into an [AssetId] and returns it if it is cached.
  ///
  /// Handles 'package:' or 'asset:' URIs, as well as 'file:' URIs that have the
  /// same pattern used by [assetPath].
  ///
  /// Returns null if the Uri cannot be parsed or is not cached.
  AssetId lookupAsset(Uri uri) {
    if (uri.isScheme('dart')) return null;
    if (uri.isScheme('package') || uri.isScheme('asset')) {
      final assetId = AssetId.resolve('$uri');
      return _cachedAssetContents.containsKey(assetId) ? assetId : null;
    }
    if (uri.isScheme('file')) {
      final parts = p.split(uri.path);
      final assetId = AssetId(parts[1], p.joinAll(parts.skip(2)));
      return _cachedAssetContents.containsKey(assetId) ? assetId : null;
    }
    return null;
  }

  @override
  Source resolveAbsolute(Uri uri, [Uri actualUri]) {
    final cachedId = lookupAsset(uri);
    if (cachedId == null) return null;
    return resourceProvider
        .getFile(assetPath(cachedId))
        .createSource(cachedId.uri);
  }

  @override
  Uri restoreAbsolute(Source source) => lookupAsset(source.uri)?.uri;
}

String assetPath(AssetId assetId) =>
    p.join('/${assetId.package}', assetId.path);

/// A completer that waits until all added [Future]s complete.
// TODO(blois): Copied from quiver. Remove from here when it gets
// added to dart:core. (See #6626.)
class FutureGroup<E> {
  static const _FINISHED = -1;

  int _pending = 0;
  Future _failedTask;
  final Completer<List<E>> _completer = Completer<List<E>>();
  final List<E> results = [];

  /// The task that failed, if any.
  Future get failedTask => _failedTask;

  /// Wait for [task] to complete.
  ///
  /// If this group has already been marked as completed, a [StateError] will
  /// be thrown.
  ///
  /// If this group has a [failedTask], new tasks will be ignored, because the
  /// error has already been signaled.
  void add(Future<E> task) {
    if (_failedTask != null) return;
    if (_pending == _FINISHED) throw StateError('Future already completed');

    _pending++;
    var i = results.length;
    results.add(null);
    task.then((res) {
      results[i] = res;
      if (_failedTask != null) return;
      _pending--;
      if (_pending == 0) {
        _pending = _FINISHED;
        _completer.complete(results);
      }
    }, onError: (e, s) {
      if (_failedTask != null) return;
      _failedTask = task;
      _completer.completeError(e, s as StackTrace);
    });
  }

  /// A Future that completes with a List of the values from all the added
  /// tasks, when they have all completed.
  ///
  /// If any task fails, this Future will receive the error. Only the first
  /// error will be sent to the Future.
  Future<List<E>> get future => _completer.future;
}
