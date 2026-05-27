import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

class DxfLayerSettings {
  final bool enabled;
  final String falzLayer;
  final String gesaegtLayer;
  final String auflageLayer;
  final String unterbauLayer;
  final String bohrungLayer;
  final String konstruktionLayer;
  final int falzColor;
  final int gesaegtColor;
  final int auflageColor;
  final int unterbauColor;
  final int bohrungColor;
  final int konstruktionColor;

  const DxfLayerSettings({
    required this.enabled,
    required this.falzLayer,
    required this.gesaegtLayer,
    required this.auflageLayer,
    required this.unterbauLayer,
    required this.bohrungLayer,
    required this.konstruktionLayer,
    required this.falzColor,
    required this.gesaegtColor,
    required this.auflageColor,
    required this.unterbauColor,
    required this.bohrungColor,
    required this.konstruktionColor,
  });

  DxfLayerSettings copyWith({
    bool? enabled,
    String? falzLayer,
    String? gesaegtLayer,
    String? auflageLayer,
    String? unterbauLayer,
    String? bohrungLayer,
    String? konstruktionLayer,
    int? falzColor,
    int? gesaegtColor,
    int? auflageColor,
    int? unterbauColor,
    int? bohrungColor,
    int? konstruktionColor,
  }) {
    return DxfLayerSettings(
      enabled: enabled ?? this.enabled,
      falzLayer: falzLayer ?? this.falzLayer,
      gesaegtLayer: gesaegtLayer ?? this.gesaegtLayer,
      auflageLayer: auflageLayer ?? this.auflageLayer,
      unterbauLayer: unterbauLayer ?? this.unterbauLayer,
      bohrungLayer: bohrungLayer ?? this.bohrungLayer,
      konstruktionLayer: konstruktionLayer ?? this.konstruktionLayer,
      falzColor: falzColor ?? this.falzColor,
      gesaegtColor: gesaegtColor ?? this.gesaegtColor,
      auflageColor: auflageColor ?? this.auflageColor,
      unterbauColor: unterbauColor ?? this.unterbauColor,
      bohrungColor: bohrungColor ?? this.bohrungColor,
      konstruktionColor: konstruktionColor ?? this.konstruktionColor,
    );
  }
}

enum DxfCutType { surfaceFlush, auflage, unterbau }

class DxfLayerProcessor {
  static const String ausschnittLayer = 'AUSSCHNITT';
  static const double _epsilon = 0.000001;

  static Uint8List rewriteAusschnittLayers(
    Uint8List bytes, {
    required String falzLayer,
    required String gesaegtLayer,
    required String auflageLayer,
    required String unterbauLayer,
    required String bohrungLayer,
    required String konstruktionLayer,
    required int falzColor,
    required int gesaegtColor,
    required int auflageColor,
    required int unterbauColor,
    required int bohrungColor,
    required int konstruktionColor,
    DxfCutType? cutType,
  }) {
    var cleanFalzLayer = falzLayer.trim();
    var cleanGesaegtLayer = gesaegtLayer.trim();
    var cleanAuflageLayer = auflageLayer.trim();
    var cleanUnterbauLayer = unterbauLayer.trim();
    var cleanBohrungLayer = bohrungLayer.trim();
    var cleanKonstruktionLayer = konstruktionLayer.trim();

    if (cleanFalzLayer.isEmpty ||
        cleanGesaegtLayer.isEmpty ||
        cleanAuflageLayer.isEmpty ||
        cleanUnterbauLayer.isEmpty ||
        cleanBohrungLayer.isEmpty ||
        cleanKonstruktionLayer.isEmpty) {
      return bytes;
    }

    final text = latin1.decode(bytes);
    final newline = _detectNewline(text);
    final normalized = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final hadTrailingNewline = normalized.endsWith('\n');
    final lines = normalized.split('\n');

    if (hadTrailingNewline) {
      lines.removeLast();
    }

    final pairs = _readPairs(lines);
    if (pairs.isEmpty) return bytes;

    if (_usesLegacyLayerNames(pairs)) {
      final legacyNames = _legacyUniqueLayerNames([
        cleanFalzLayer,
        cleanGesaegtLayer,
        cleanAuflageLayer,
        cleanUnterbauLayer,
        cleanBohrungLayer,
        cleanKonstruktionLayer,
      ]);

      cleanFalzLayer = legacyNames[0];
      cleanGesaegtLayer = legacyNames[1];
      cleanAuflageLayer = legacyNames[2];
      cleanUnterbauLayer = legacyNames[3];
      cleanBohrungLayer = legacyNames[4];
      cleanKonstruktionLayer = legacyNames[5];
    }

    final candidates = <_PolylineCandidate>[];
    final circleLayerValueLineIndexes = <int>[];
    final constructionLayerValueLineIndexes = <int>[];
    final usedTargetLayers = <String, int>{};

    for (var i = 0; i < pairs.length; i++) {
      final pair = pairs[i];
      if (pair.code != 0) continue;

      final entityType = pair.value.trim().toUpperCase();
      final end = entityType == 'POLYLINE'
          ? _findPolylineEndIndex(pairs, i + 1)
          : _findNextEntityIndex(pairs, i + 1);
      final constructionLayerValueLineIndex =
          _readDashedDimensionLayerValueLineIndex(pairs, i, end);

      if (constructionLayerValueLineIndex != null) {
        constructionLayerValueLineIndexes.add(constructionLayerValueLineIndex);
      }

      if (entityType == 'LWPOLYLINE') {
        final candidate = _readLightweightPolyline(pairs, i, end);
        if (candidate != null) candidates.add(candidate);
        i = end - 1;
      } else if (entityType == 'POLYLINE') {
        final candidate = _readClassicPolyline(pairs, i, end);
        if (candidate != null) candidates.add(candidate);
        i = end - 1;
      } else if (entityType == 'CIRCLE') {
        circleLayerValueLineIndexes.addAll(
          _readAusschnittLayerValueLineIndexes(pairs, i, end),
        );
        i = end - 1;
      } else {
        i = end - 1;
      }
    }

    var changed = false;

    if (circleLayerValueLineIndexes.isNotEmpty) {
      _setLayerValues(circleLayerValueLineIndexes, lines, cleanBohrungLayer);
      usedTargetLayers[cleanBohrungLayer] = bohrungColor;
      changed = true;
    }

    if (constructionLayerValueLineIndexes.isNotEmpty) {
      _setLayerValues(
        constructionLayerValueLineIndexes,
        lines,
        cleanKonstruktionLayer,
      );
      usedTargetLayers[cleanKonstruktionLayer] = konstruktionColor;
      changed = true;
    }

    final effectiveCutType = cutType ?? detectCutType(normalized);
    if (effectiveCutType == DxfCutType.auflage) {
      if (candidates.isNotEmpty) {
        _setCandidateLayers(candidates, lines, cleanAuflageLayer);
        usedTargetLayers[cleanAuflageLayer] = auflageColor;
        changed = true;
      }
    } else if (effectiveCutType == DxfCutType.unterbau) {
      if (candidates.isNotEmpty) {
        _setCandidateLayers(candidates, lines, cleanUnterbauLayer);
        usedTargetLayers[cleanUnterbauLayer] = unterbauColor;
        changed = true;
      }
    } else {
      if (candidates.length >= 2) {
        _setSurfaceFlushLayers(
          candidates,
          lines,
          cleanFalzLayer,
          cleanGesaegtLayer,
        );
        usedTargetLayers[cleanFalzLayer] = falzColor;
        usedTargetLayers[cleanGesaegtLayer] = gesaegtColor;
        changed = true;
      }
    }

    if (!changed) return bytes;

    _syncLayerTableEntries(lines, usedTargetLayers, pairs);

    var result = lines.join(newline);
    if (hadTrailingNewline) result += newline;

    return Uint8List.fromList(latin1.encode(result));
  }

  static DxfCutType detectCutType(String text) {
    final upperText = text.toUpperCase();

    if (upperText.contains('UNTERBAU')) return DxfCutType.unterbau;
    if (upperText.contains('AUFLAGE')) return DxfCutType.auflage;
    if (upperText.contains('FLÄCHEN') ||
        upperText.contains('FLAECHEN') ||
        upperText.contains('FLACHEN')) {
      return DxfCutType.surfaceFlush;
    }

    return DxfCutType.surfaceFlush;
  }

  static void _setCandidateLayers(
    List<_PolylineCandidate> candidates,
    List<String> lines,
    String targetLayer,
  ) {
    for (final candidate in candidates) {
      _setLayerValues(candidate.layerValueLineIndexes, lines, targetLayer);
    }
  }

  static void _setLayerValues(
    List<int> layerValueLineIndexes,
    List<String> lines,
    String targetLayer,
  ) {
    for (final lineIndex in layerValueLineIndexes) {
      lines[lineIndex] = targetLayer;
    }
  }

  static void _setSurfaceFlushLayers(
    List<_PolylineCandidate> candidates,
    List<String> lines,
    String falzLayer,
    String gesaegtLayer,
  ) {
    candidates.sort((a, b) => b.metric.compareTo(a.metric));

    for (var i = 0; i < candidates.length; i++) {
      final targetLayer = i == 0 ? falzLayer : gesaegtLayer;

      for (final lineIndex in candidates[i].layerValueLineIndexes) {
        lines[lineIndex] = targetLayer;
      }
    }
  }

  static String _detectNewline(String text) {
    if (text.contains('\r\n')) return '\r\n';
    if (text.contains('\r')) return '\r';
    return '\n';
  }

  static List<_DxfPair> _readPairs(List<String> lines) {
    final pairs = <_DxfPair>[];

    for (var i = 0; i + 1 < lines.length; i += 2) {
      pairs.add(
        _DxfPair(
          codeLineIndex: i,
          valueLineIndex: i + 1,
          code: int.tryParse(lines[i].trim()),
          value: lines[i + 1],
        ),
      );
    }

    return pairs;
  }

  static void _syncLayerTableEntries(
    List<String> lines,
    Map<String, int> targetLayerColors,
    List<_DxfPair> pairs,
  ) {
    if (targetLayerColors.isEmpty) return;

    final layerTable = _findLayerTable(pairs);
    if (layerTable == null) return;

    final existingLayerNames = <String>{};
    final existingLayerColorLines = <String, int>{};
    for (
      var i = layerTable.firstRecordPairIndex;
      i < layerTable.endPairIndex;
      i++
    ) {
      if (pairs[i].code != 0 ||
          pairs[i].value.trim().toUpperCase() != 'LAYER') {
        continue;
      }

      final recordEnd = _findNextEntityIndex(pairs, i + 1);
      String? layerName;
      int? colorValueLineIndex;

      for (var j = i + 1; j < recordEnd && j < layerTable.endPairIndex; j++) {
        if (pairs[j].code == 2 && layerName == null) {
          layerName = pairs[j].value.trim();
        } else if (pairs[j].code == 62 && colorValueLineIndex == null) {
          colorValueLineIndex = pairs[j].valueLineIndex;
        }
      }

      if (layerName != null) {
        final key = layerName.toUpperCase();
        existingLayerNames.add(key);
        if (colorValueLineIndex != null) {
          existingLayerColorLines[key] = colorValueLineIndex;
        }
      }
    }

    for (final entry in targetLayerColors.entries) {
      final key = entry.key.trim().toUpperCase();
      final colorLineIndex = existingLayerColorLines[key];
      if (colorLineIndex != null) {
        lines[colorLineIndex] = _formatDxfInt(_normalizeAciColor(entry.value));
      }
    }

    final missingLayers = targetLayerColors.entries.where((entry) {
      return !existingLayerNames.contains(entry.key.trim().toUpperCase());
    }).toList();
    if (missingLayers.isEmpty) return;

    var nextHandle = layerTable.supportsHandles ? _nextHandleValue(pairs) : 0;
    final newLayerLines = <String>[];

    for (final entry in missingLayers) {
      newLayerLines.addAll(
        _buildLayerRecordLines(
          layerName: entry.key,
          color: _normalizeAciColor(entry.value),
          tableHandle: layerTable.tableHandle,
          handle: layerTable.supportsHandles
              ? nextHandle.toRadixString(16).toUpperCase()
              : null,
          supportsHandles: layerTable.supportsHandles,
          supportsSubclassMarkers: layerTable.supportsSubclassMarkers,
          supportsLineweight: layerTable.supportsLineweight,
          supportsPlotStyle: layerTable.supportsPlotStyle,
          supportsMaterial: layerTable.supportsMaterial,
          lineTypeName: layerTable.lineTypeName,
        ),
      );
      if (layerTable.supportsHandles) {
        nextHandle++;
      }
    }

    if (layerTable.supportsHandles) {
      _syncHandseed(lines, pairs, nextHandle);
    }
    lines.insertAll(layerTable.endLineIndex, newLayerLines);

    if (layerTable.countValueLineIndex != null) {
      final existingCount =
          int.tryParse(lines[layerTable.countValueLineIndex!].trim()) ??
          existingLayerNames.length;
      lines[layerTable.countValueLineIndex!] = _formatDxfInt(
        existingCount + missingLayers.length,
      );
    }
  }

  static bool _usesLegacyLayerNames(List<_DxfPair> pairs) {
    for (var i = 0; i < pairs.length - 1; i++) {
      if (pairs[i].code == 9 &&
          pairs[i].value.trim().toUpperCase() == r'$ACADVER' &&
          pairs[i + 1].code == 1) {
        final version = pairs[i + 1].value.trim().toUpperCase();
        if (version == 'AC1006' || version == 'AC1009') return true;
      }
    }

    final layerTable = _findLayerTable(pairs);
    return layerTable != null &&
        !layerTable.supportsHandles &&
        !layerTable.supportsSubclassMarkers;
  }

  static List<String> _legacyUniqueLayerNames(List<String> layerNames) {
    final usedNames = <String>{};
    return layerNames
        .map((name) => _legacyLayerName(name, usedNames))
        .toList(growable: false);
  }

  static String _legacyLayerName(String layerName, Set<String> usedNames) {
    const invalidCharacters = '<>/\\":;?*|=,`';
    final buffer = StringBuffer();
    var lastWasUnderscore = false;

    for (final rune in layerName.trim().runes) {
      final replacement = _legacySymbolRuneReplacement(rune, invalidCharacters);

      if (replacement == '_' && lastWasUnderscore) continue;
      buffer.write(replacement);
      lastWasUnderscore = replacement.endsWith('_');
    }

    var clean = buffer.toString();
    clean = clean.replaceAll(RegExp(r'^_+|_+$'), '');
    if (clean.isEmpty) clean = 'LAYER';
    if (clean.length > 31) clean = clean.substring(0, 31);

    var candidate = clean;
    var counter = 2;
    while (usedNames.contains(candidate.toUpperCase())) {
      final suffix = '_$counter';
      final baseLength = math.max(1, 31 - suffix.length);
      candidate =
          '${clean.substring(0, math.min(clean.length, baseLength))}'
          '$suffix';
      counter++;
    }

    usedNames.add(candidate.toUpperCase());
    return candidate;
  }

  static String _legacySymbolRuneReplacement(
    int rune,
    String invalidCharacters,
  ) {
    switch (rune) {
      case 0x00c4:
        return 'Ae';
      case 0x00d6:
        return 'Oe';
      case 0x00dc:
        return 'Ue';
      case 0x00e4:
        return 'ae';
      case 0x00f6:
        return 'oe';
      case 0x00fc:
        return 'ue';
      case 0x00df:
        return 'ss';
      default:
        final isAscii = rune >= 33 && rune <= 126;
        final char = String.fromCharCode(rune);
        return isAscii && !invalidCharacters.contains(char) ? char : '_';
    }
  }

  static _LayerTableInfo? _findLayerTable(List<_DxfPair> pairs) {
    for (var i = 0; i < pairs.length - 1; i++) {
      if (pairs[i].code != 0 ||
          pairs[i].value.trim().toUpperCase() != 'TABLE') {
        continue;
      }

      final next = pairs[i + 1];
      if (next.code != 2 || next.value.trim().toUpperCase() != 'LAYER') {
        continue;
      }

      String? tableHandle;
      int? countValueLineIndex;
      var firstRecordPairIndex = i + 2;
      var supportsHandles = false;
      var supportsSubclassMarkers = false;
      var supportsLineweight = false;
      var supportsPlotStyle = false;
      var supportsMaterial = false;
      var lineTypeName = 'Continuous';

      for (var j = i + 2; j < pairs.length; j++) {
        if (pairs[j].code == 0) {
          firstRecordPairIndex = j;
          break;
        }

        if (pairs[j].code == 5 && tableHandle == null) {
          tableHandle = pairs[j].value.trim();
        } else if (pairs[j].code == 70 && countValueLineIndex == null) {
          countValueLineIndex = pairs[j].valueLineIndex;
        }
      }

      for (var j = firstRecordPairIndex; j < pairs.length; j++) {
        if (pairs[j].code == 0 &&
            pairs[j].value.trim().toUpperCase() == 'ENDTAB') {
          return _LayerTableInfo(
            endPairIndex: j,
            endLineIndex: pairs[j].codeLineIndex,
            firstRecordPairIndex: firstRecordPairIndex,
            tableHandle: tableHandle ?? '2',
            countValueLineIndex: countValueLineIndex,
            supportsHandles: supportsHandles,
            supportsSubclassMarkers: supportsSubclassMarkers,
            supportsLineweight: supportsLineweight,
            supportsPlotStyle: supportsPlotStyle,
            supportsMaterial: supportsMaterial,
            lineTypeName: lineTypeName,
          );
        }

        if (pairs[j].code == 0 &&
            pairs[j].value.trim().toUpperCase() == 'LAYER') {
          final recordEnd = _findNextEntityIndex(pairs, j + 1);
          for (var k = j + 1; k < recordEnd; k++) {
            if (pairs[k].code == 5) {
              supportsHandles = true;
            } else if (pairs[k].code == 100) {
              supportsSubclassMarkers = true;
            } else if (pairs[k].code == 370) {
              supportsLineweight = true;
            } else if (pairs[k].code == 390) {
              supportsPlotStyle = true;
            } else if (pairs[k].code == 347 || pairs[k].code == 348) {
              supportsMaterial = true;
            } else if (pairs[k].code == 6 && pairs[k].value.trim().isNotEmpty) {
              lineTypeName = pairs[k].value.trim();
            }
          }
        }
      }
    }

    return null;
  }

  static int _nextHandleValue(List<_DxfPair> pairs) {
    var maxHandle = 0x100;

    for (final pair in pairs) {
      if (pair.code == 5 || pair.code == 105) {
        final value = int.tryParse(pair.value.trim(), radix: 16);
        if (value != null && value > maxHandle) {
          maxHandle = value;
        }
      }
    }

    return maxHandle + 1;
  }

  static void _syncHandseed(
    List<String> lines,
    List<_DxfPair> pairs,
    int nextHandle,
  ) {
    for (var i = 0; i < pairs.length - 1; i++) {
      if (pairs[i].code == 9 &&
          pairs[i].value.trim().toUpperCase() == r'$HANDSEED' &&
          pairs[i + 1].code == 5) {
        final current = int.tryParse(pairs[i + 1].value.trim(), radix: 16) ?? 0;
        if (nextHandle > current) {
          lines[pairs[i + 1].valueLineIndex] = nextHandle
              .toRadixString(16)
              .toUpperCase();
        }
        return;
      }
    }
  }

  static List<String> _buildLayerRecordLines({
    required String layerName,
    required int color,
    required String tableHandle,
    required String? handle,
    required bool supportsHandles,
    required bool supportsSubclassMarkers,
    required bool supportsLineweight,
    required bool supportsPlotStyle,
    required bool supportsMaterial,
    required String lineTypeName,
  }) {
    final lines = ['  0', 'LAYER'];

    if (supportsHandles && handle != null) {
      lines.addAll(['  5', handle, '330', tableHandle]);
    }

    if (supportsSubclassMarkers) {
      lines.addAll([
        '100',
        'AcDbSymbolTableRecord',
        '100',
        'AcDbLayerTableRecord',
      ]);
    }

    lines.addAll([
      '  2',
      layerName,
      ' 70',
      '     0',
      ' 62',
      _formatDxfInt(color),
      '  6',
      lineTypeName,
    ]);

    if (supportsLineweight) {
      lines.addAll(['370', '    -3']);
    }

    if (supportsPlotStyle) {
      lines.addAll(['390', 'F']);
    }

    if (supportsMaterial) {
      lines.addAll(['347', 'EE', '348', '0']);
    }

    return lines;
  }

  static int _normalizeAciColor(int color) {
    if (color < 1) return 1;
    if (color > 255) return 255;
    return color;
  }

  static String _formatDxfInt(int value) {
    return value.toString().padLeft(6);
  }

  static int _findNextEntityIndex(List<_DxfPair> pairs, int start) {
    for (var i = start; i < pairs.length; i++) {
      if (pairs[i].code == 0) return i;
    }

    return pairs.length;
  }

  static int _findPolylineEndIndex(List<_DxfPair> pairs, int start) {
    for (var i = start; i < pairs.length; i++) {
      if (pairs[i].code == 0 &&
          pairs[i].value.trim().toUpperCase() == 'SEQEND') {
        return math.min(i + 1, pairs.length);
      }
    }

    return pairs.length;
  }

  static List<int> _readAusschnittLayerValueLineIndexes(
    List<_DxfPair> pairs,
    int start,
    int end,
  ) {
    final layerValueLineIndexes = <int>[];

    for (var i = start + 1; i < end; i++) {
      if (pairs[i].code == 8 && _isAusschnittLayer(pairs[i].value)) {
        layerValueLineIndexes.add(pairs[i].valueLineIndex);
      }
    }

    return layerValueLineIndexes;
  }

  static int? _readDashedDimensionLayerValueLineIndex(
    List<_DxfPair> pairs,
    int start,
    int end,
  ) {
    int? layerValueLineIndex;
    var isDimensionLayer = false;
    var isDashed = false;

    for (var i = start + 1; i < end; i++) {
      if (pairs[i].code == 8) {
        layerValueLineIndex = pairs[i].valueLineIndex;
        isDimensionLayer = pairs[i].value.trim().toUpperCase() == 'BEMASSUNG';
      } else if (pairs[i].code == 6) {
        isDashed = _isDashedLineType(pairs[i].value);
      }
    }

    if (isDimensionLayer && isDashed) {
      return layerValueLineIndex;
    }

    return null;
  }

  static bool _isDashedLineType(String value) {
    final lineType = value.trim().toUpperCase();
    if (lineType.isEmpty ||
        lineType == 'BYLAYER' ||
        lineType == 'BYBLOCK' ||
        lineType == 'CONTINUOUS') {
      return false;
    }

    return true;
  }

  static _PolylineCandidate? _readLightweightPolyline(
    List<_DxfPair> pairs,
    int start,
    int end,
  ) {
    final layerValueLineIndexes = <int>[];
    final points = <_Point>[];
    var closed = false;

    for (var i = start + 1; i < end; i++) {
      final pair = pairs[i];

      if (pair.code == 8 && _isAusschnittLayer(pair.value)) {
        layerValueLineIndexes.add(pair.valueLineIndex);
      } else if (pair.code == 70) {
        final flags = int.tryParse(pair.value.trim()) ?? 0;
        closed = flags & 1 == 1;
      } else if (pair.code == 10) {
        final x = double.tryParse(pair.value.trim());
        final next = i + 1 < end ? pairs[i + 1] : null;
        final y = next?.code == 20 ? double.tryParse(next!.value.trim()) : null;

        if (x != null && y != null) {
          points.add(_Point(x, y));
        }
      }
    }

    return _buildCandidate(layerValueLineIndexes, points, closed);
  }

  static _PolylineCandidate? _readClassicPolyline(
    List<_DxfPair> pairs,
    int start,
    int end,
  ) {
    final layerValueLineIndexes = <int>[];
    final points = <_Point>[];
    var closed = false;

    for (var i = start + 1; i < end; i++) {
      final pair = pairs[i];

      if (pair.code == 8 && _isAusschnittLayer(pair.value)) {
        layerValueLineIndexes.add(pair.valueLineIndex);
      } else if (pair.code == 70 && points.isEmpty) {
        final flags = int.tryParse(pair.value.trim()) ?? 0;
        closed = flags & 1 == 1;
      } else if (pair.code == 0 &&
          pair.value.trim().toUpperCase() == 'VERTEX') {
        final vertexEnd = _findNextEntityIndex(pairs, i + 1);
        final point = _readVertexPoint(pairs, i + 1, math.min(vertexEnd, end));
        if (point != null) points.add(point);
        i = vertexEnd - 1;
      }
    }

    return _buildCandidate(layerValueLineIndexes, points, closed);
  }

  static _Point? _readVertexPoint(List<_DxfPair> pairs, int start, int end) {
    double? x;
    double? y;

    for (var i = start; i < end; i++) {
      if (pairs[i].code == 10) {
        x = double.tryParse(pairs[i].value.trim());
      } else if (pairs[i].code == 20) {
        y = double.tryParse(pairs[i].value.trim());
      }
    }

    return x == null || y == null ? null : _Point(x, y);
  }

  static _PolylineCandidate? _buildCandidate(
    List<int> layerValueLineIndexes,
    List<_Point> points,
    bool closed,
  ) {
    if (layerValueLineIndexes.isEmpty || points.length < 2) return null;

    final effectivelyClosed = closed || _samePoint(points.first, points.last);
    final length = _length(points, effectivelyClosed);
    final area = effectivelyClosed ? _area(points) : 0.0;

    if (length <= _epsilon && area <= _epsilon) return null;

    return _PolylineCandidate(
      layerValueLineIndexes: layerValueLineIndexes,
      length: length,
      area: area,
    );
  }

  static bool _isAusschnittLayer(String value) {
    return value.trim().toUpperCase() == ausschnittLayer;
  }

  static bool _samePoint(_Point a, _Point b) {
    return (a.x - b.x).abs() <= _epsilon && (a.y - b.y).abs() <= _epsilon;
  }

  static double _length(List<_Point> points, bool closed) {
    var length = 0.0;

    for (var i = 1; i < points.length; i++) {
      length += points[i - 1].distanceTo(points[i]);
    }

    if (closed && !_samePoint(points.first, points.last)) {
      length += points.last.distanceTo(points.first);
    }

    return length;
  }

  static double _area(List<_Point> points) {
    var sum = 0.0;

    for (var i = 0; i < points.length; i++) {
      final current = points[i];
      final next = points[(i + 1) % points.length];
      sum += current.x * next.y - next.x * current.y;
    }

    return sum.abs() / 2;
  }
}

class _DxfPair {
  final int codeLineIndex;
  final int valueLineIndex;
  final int? code;
  final String value;

  const _DxfPair({
    required this.codeLineIndex,
    required this.valueLineIndex,
    required this.code,
    required this.value,
  });
}

class _PolylineCandidate {
  final List<int> layerValueLineIndexes;
  final double length;
  final double area;

  const _PolylineCandidate({
    required this.layerValueLineIndexes,
    required this.length,
    required this.area,
  });

  double get metric => area > DxfLayerProcessor._epsilon ? area : length;
}

class _LayerTableInfo {
  final int endPairIndex;
  final int endLineIndex;
  final int firstRecordPairIndex;
  final String tableHandle;
  final int? countValueLineIndex;
  final bool supportsHandles;
  final bool supportsSubclassMarkers;
  final bool supportsLineweight;
  final bool supportsPlotStyle;
  final bool supportsMaterial;
  final String lineTypeName;

  const _LayerTableInfo({
    required this.endPairIndex,
    required this.endLineIndex,
    required this.firstRecordPairIndex,
    required this.tableHandle,
    required this.countValueLineIndex,
    required this.supportsHandles,
    required this.supportsSubclassMarkers,
    required this.supportsLineweight,
    required this.supportsPlotStyle,
    required this.supportsMaterial,
    required this.lineTypeName,
  });
}

class _Point {
  final double x;
  final double y;

  const _Point(this.x, this.y);

  double distanceTo(_Point other) {
    final dx = x - other.x;
    final dy = y - other.y;
    return math.sqrt(dx * dx + dy * dy);
  }
}
