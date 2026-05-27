import 'dart:convert';
import 'dart:typed_data';

import 'package:atool_app/dxf_layer_processor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('assigns the larger AUSSCHNITT polyline to the Falz layer', () {
    final dxf = [
      '0',
      'SECTION',
      '2',
      'ENTITIES',
      ..._lwPolyline([(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)]),
      ..._lwPolyline([(0.0, 0.0), (4.0, 0.0), (4.0, 4.0), (0.0, 4.0)]),
      '0',
      'ENDSEC',
      '0',
      'EOF',
    ].join('\n');

    final rewritten = DxfLayerProcessor.rewriteAusschnittLayers(
      Uint8List.fromList(latin1.encode(dxf)),
      falzLayer: 'KUNDE Falz',
      gesaegtLayer: 'KUNDE gesaegt',
      auflageLayer: 'KUNDE Auflage',
      unterbauLayer: 'KUNDE Unterbau',
      bohrungLayer: 'KUNDE Bohrung',
      konstruktionLayer: 'KUNDE Konstruktion',
      falzColor: 1,
      gesaegtColor: 2,
      auflageColor: 3,
      unterbauColor: 4,
      bohrungColor: 5,
      konstruktionColor: 6,
    );

    expect(_layerValues(rewritten), ['KUNDE Falz', 'KUNDE gesaegt']);
  });

  test('adds missing target layers to the LAYER table', () {
    final dxf = [
      '0',
      'SECTION',
      '2',
      'HEADER',
      '9',
      r'$HANDSEED',
      '5',
      '12',
      '0',
      'ENDSEC',
      '0',
      'SECTION',
      '2',
      'TABLES',
      ..._layerTable(['0', 'AUSSCHNITT'], modern: true),
      '0',
      'ENDSEC',
      '0',
      'SECTION',
      '2',
      'ENTITIES',
      ..._lwPolyline([(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)]),
      ..._lwPolyline([(0.0, 0.0), (4.0, 0.0), (4.0, 4.0), (0.0, 4.0)]),
      '0',
      'ENDSEC',
      '0',
      'EOF',
    ].join('\n');

    final rewritten = DxfLayerProcessor.rewriteAusschnittLayers(
      Uint8List.fromList(latin1.encode(dxf)),
      falzLayer: 'KUNDE Falz',
      gesaegtLayer: 'KUNDE gesaegt',
      auflageLayer: 'KUNDE Auflage',
      unterbauLayer: 'KUNDE Unterbau',
      bohrungLayer: 'KUNDE Bohrung',
      konstruktionLayer: 'KUNDE Konstruktion',
      falzColor: 1,
      gesaegtColor: 2,
      auflageColor: 3,
      unterbauColor: 4,
      bohrungColor: 5,
      konstruktionColor: 6,
    );

    expect(
      _layerTableNames(rewritten),
      containsAll(['KUNDE Falz', 'KUNDE gesaegt']),
    );
    expect(_layerTableColors(rewritten)['KUNDE Falz'], 1);
    expect(_layerTableColors(rewritten)['KUNDE gesaegt'], 2);
    expect(_layerRecordHasCode(rewritten, 'KUNDE Falz', '390'), isTrue);
    expect(_layerRecordHasCode(rewritten, 'KUNDE gesaegt', '390'), isTrue);
    expect(_handseed(rewritten), '103');
  });

  test('adds AC1009 target layers as legacy-safe table names', () {
    final dxf = [
      '0',
      'SECTION',
      '2',
      'TABLES',
      ..._layerTable(['0', 'AUSSCHNITT']),
      '0',
      'ENDSEC',
      '0',
      'SECTION',
      '2',
      'ENTITIES',
      ..._mText('Auflage'),
      ..._lwPolyline([(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)]),
      '0',
      'ENDSEC',
      '0',
      'EOF',
    ].join('\n');

    final rewritten = DxfLayerProcessor.rewriteAusschnittLayers(
      Uint8List.fromList(latin1.encode(dxf)),
      falzLayer: 'KUNDE Falz',
      gesaegtLayer: 'KUNDE gesaegt',
      auflageLayer: 'AUSSCHNITT Auflage',
      unterbauLayer: 'KUNDE Unterbau',
      bohrungLayer: 'KUNDE Bohrung',
      konstruktionLayer: 'KUNDE Konstruktion',
      falzColor: 1,
      gesaegtColor: 2,
      auflageColor: 3,
      unterbauColor: 4,
      bohrungColor: 5,
      konstruktionColor: 6,
    );

    expect(_layerValues(rewritten), contains('AUSSCHNITT_Auflage'));
    expect(_layerTableNames(rewritten), contains('AUSSCHNITT_Auflage'));
    expect(_layerTableNames(rewritten), isNot(contains('AUSSCHNITT Auflage')));
    expect(
      _layerRecordHasCode(rewritten, 'AUSSCHNITT_Auflage', '330'),
      isFalse,
    );
    expect(
      _layerRecordHasCode(rewritten, 'AUSSCHNITT_Auflage', '100'),
      isFalse,
    );
    expect(
      _layerRecordHasCode(rewritten, 'AUSSCHNITT_Auflage', '390'),
      isFalse,
    );
  });

  test('leaves DXF unchanged when only one AUSSCHNITT polyline exists', () {
    final dxf = [
      '0',
      'SECTION',
      '2',
      'ENTITIES',
      ..._lwPolyline([(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)]),
      '0',
      'ENDSEC',
      '0',
      'EOF',
    ].join('\r\n');

    final bytes = Uint8List.fromList(latin1.encode(dxf));

    final rewritten = DxfLayerProcessor.rewriteAusschnittLayers(
      bytes,
      falzLayer: 'KUNDE Falz',
      gesaegtLayer: 'KUNDE gesaegt',
      auflageLayer: 'KUNDE Auflage',
      unterbauLayer: 'KUNDE Unterbau',
      bohrungLayer: 'KUNDE Bohrung',
      konstruktionLayer: 'KUNDE Konstruktion',
      falzColor: 1,
      gesaegtColor: 2,
      auflageColor: 3,
      unterbauColor: 4,
      bohrungColor: 5,
      konstruktionColor: 6,
    );

    expect(latin1.decode(rewritten), dxf);
  });

  test('assigns Auflage DXF to the Auflage layer', () {
    final dxf = [
      '0',
      'SECTION',
      '2',
      'ENTITIES',
      ..._mText('Auflage BLANCO Claron 500-IF'),
      ..._lwPolyline([(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)]),
      '0',
      'ENDSEC',
      '0',
      'EOF',
    ].join('\n');

    final rewritten = DxfLayerProcessor.rewriteAusschnittLayers(
      Uint8List.fromList(latin1.encode(dxf)),
      falzLayer: 'KUNDE Falz',
      gesaegtLayer: 'KUNDE gesaegt',
      auflageLayer: 'KUNDE Auflage',
      unterbauLayer: 'KUNDE Unterbau',
      bohrungLayer: 'KUNDE Bohrung',
      konstruktionLayer: 'KUNDE Konstruktion',
      falzColor: 1,
      gesaegtColor: 2,
      auflageColor: 3,
      unterbauColor: 4,
      bohrungColor: 5,
      konstruktionColor: 6,
    );

    expect(_layerValues(rewritten), ['BEMASSUNG', 'KUNDE Auflage']);
  });

  test('uses provided cut type instead of reading it from DXF text', () {
    final dxf = [
      '0',
      'SECTION',
      '2',
      'ENTITIES',
      ..._lwPolyline([(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)]),
      '0',
      'ENDSEC',
      '0',
      'EOF',
    ].join('\n');

    final rewritten = DxfLayerProcessor.rewriteAusschnittLayers(
      Uint8List.fromList(latin1.encode(dxf)),
      falzLayer: 'KUNDE Falz',
      gesaegtLayer: 'KUNDE gesaegt',
      auflageLayer: 'KUNDE Auflage',
      unterbauLayer: 'KUNDE Unterbau',
      bohrungLayer: 'KUNDE Bohrung',
      konstruktionLayer: 'KUNDE Konstruktion',
      falzColor: 1,
      gesaegtColor: 2,
      auflageColor: 3,
      unterbauColor: 4,
      bohrungColor: 5,
      konstruktionColor: 6,
      cutType: DxfCutType.unterbau,
    );

    expect(_layerValues(rewritten), ['KUNDE Unterbau']);
  });

  test('assigns Unterbau DXF to the Unterbau layer', () {
    final dxf = [
      '0',
      'SECTION',
      '2',
      'ENTITIES',
      ..._mText('Unterbau BLANCO Etagon 500-U'),
      ..._lwPolyline([(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)]),
      '0',
      'ENDSEC',
      '0',
      'EOF',
    ].join('\n');

    final rewritten = DxfLayerProcessor.rewriteAusschnittLayers(
      Uint8List.fromList(latin1.encode(dxf)),
      falzLayer: 'KUNDE Falz',
      gesaegtLayer: 'KUNDE gesaegt',
      auflageLayer: 'KUNDE Auflage',
      unterbauLayer: 'KUNDE Unterbau',
      bohrungLayer: 'KUNDE Bohrung',
      konstruktionLayer: 'KUNDE Konstruktion',
      falzColor: 1,
      gesaegtColor: 2,
      auflageColor: 3,
      unterbauColor: 4,
      bohrungColor: 5,
      konstruktionColor: 6,
    );

    expect(_layerValues(rewritten), ['BEMASSUNG', 'KUNDE Unterbau']);
  });

  test('assigns circles on AUSSCHNITT to the Bohrung layer', () {
    final dxf = [
      '0',
      'SECTION',
      '2',
      'ENTITIES',
      ..._mText('Auflage BLANCO Claron 500-IF'),
      ..._circle('AUSSCHNITT'),
      ..._circle('BEMASSUNG'),
      ..._lwPolyline([(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)]),
      '0',
      'ENDSEC',
      '0',
      'EOF',
    ].join('\n');

    final rewritten = DxfLayerProcessor.rewriteAusschnittLayers(
      Uint8List.fromList(latin1.encode(dxf)),
      falzLayer: 'KUNDE Falz',
      gesaegtLayer: 'KUNDE gesaegt',
      auflageLayer: 'KUNDE Auflage',
      unterbauLayer: 'KUNDE Unterbau',
      bohrungLayer: 'KUNDE Bohrung',
      konstruktionLayer: 'KUNDE Konstruktion',
      falzColor: 1,
      gesaegtColor: 2,
      auflageColor: 3,
      unterbauColor: 4,
      bohrungColor: 5,
      konstruktionColor: 6,
    );

    expect(_layerValues(rewritten), [
      'BEMASSUNG',
      'KUNDE Bohrung',
      'BEMASSUNG',
      'KUNDE Auflage',
    ]);
  });

  test('assigns dashed entities on BEMASSUNG to the construction layer', () {
    final dxf = [
      '0',
      'SECTION',
      '2',
      'TABLES',
      ..._layerTable(['0', 'AUSSCHNITT', 'BEMASSUNG']),
      '0',
      'ENDSEC',
      '0',
      'SECTION',
      '2',
      'ENTITIES',
      ..._line(layer: 'BEMASSUNG', lineType: 'ACAD_ISO03W100'),
      ..._circle('AUSSCHNITT'),
      '0',
      'ENDSEC',
      '0',
      'EOF',
    ].join('\n');

    final rewritten = DxfLayerProcessor.rewriteAusschnittLayers(
      Uint8List.fromList(latin1.encode(dxf)),
      falzLayer: 'KUNDE Falz',
      gesaegtLayer: 'KUNDE gesaegt',
      auflageLayer: 'KUNDE Auflage',
      unterbauLayer: 'KUNDE Unterbau',
      bohrungLayer: 'KUNDE Bohrung',
      konstruktionLayer: 'KUNDE Konstruktion',
      falzColor: 1,
      gesaegtColor: 2,
      auflageColor: 3,
      unterbauColor: 4,
      bohrungColor: 5,
      konstruktionColor: 6,
    );

    expect(_layerValues(rewritten), ['KUNDE_Konstruktion', 'KUNDE_Bohrung']);
    expect(_layerTableColors(rewritten)['KUNDE_Konstruktion'], 6);
  });
}

List<String> _lwPolyline(List<(double, double)> points) {
  return [
    '0',
    'LWPOLYLINE',
    '8',
    'AUSSCHNITT',
    '70',
    '1',
    for (final point in points) ...['10', '${point.$1}', '20', '${point.$2}'],
  ];
}

List<String> _mText(String value) {
  return ['0', 'MTEXT', '8', 'BEMASSUNG', '1', value];
}

List<String> _circle(String layer) {
  return ['0', 'CIRCLE', '8', layer, '10', '0.0', '20', '0.0', '40', '5.0'];
}

List<String> _line({required String layer, required String lineType}) {
  return [
    '0',
    'LINE',
    '8',
    layer,
    '6',
    lineType,
    '10',
    '0.0',
    '20',
    '0.0',
    '11',
    '10.0',
    '21',
    '10.0',
  ];
}

List<String> _layerTable(List<String> layerNames, {bool modern = false}) {
  return [
    '0',
    'TABLE',
    '2',
    'LAYER',
    if (modern) ...['5', '2', '330', '0', '100', 'AcDbSymbolTable'],
    '70',
    '${layerNames.length}',
    for (var i = 0; i < layerNames.length; i++) ...[
      '0',
      'LAYER',
      if (modern) ...[
        '5',
        '${10 + i}',
        '330',
        '2',
        '100',
        'AcDbSymbolTableRecord',
        '100',
        'AcDbLayerTableRecord',
      ],
      '2',
      layerNames[i],
      '70',
      '0',
      '62',
      '7',
      '6',
      'Continuous',
      if (modern) ...['370', '-3', '390', 'F', '347', 'EE', '348', '0'],
    ],
    '0',
    'ENDTAB',
  ];
}

List<String> _layerValues(Uint8List bytes) {
  final lines = latin1.decode(bytes).split('\n');
  final layerValues = <String>[];

  for (var i = 0; i + 1 < lines.length; i++) {
    if (lines[i].trim() == '8') {
      layerValues.add(lines[i + 1]);
    }
  }

  return layerValues;
}

List<String> _layerTableNames(Uint8List bytes) {
  final lines = latin1.decode(bytes).split('\n');
  final names = <String>[];
  var inLayerTable = false;

  for (var i = 0; i + 1 < lines.length; i += 2) {
    final code = lines[i].trim();
    final value = lines[i + 1];

    if (code == '0' && value.trim() == 'TABLE') {
      inLayerTable =
          i + 3 < lines.length &&
          lines[i + 2].trim() == '2' &&
          lines[i + 3].trim() == 'LAYER';
    } else if (inLayerTable && code == '0' && value.trim() == 'ENDTAB') {
      inLayerTable = false;
    } else if (inLayerTable && code == '2' && value.trim() != 'LAYER') {
      names.add(value);
    }
  }

  return names;
}

Map<String, int> _layerTableColors(Uint8List bytes) {
  final lines = latin1.decode(bytes).split('\n');
  final colors = <String, int>{};
  var inLayerTable = false;
  String? currentLayer;

  for (var i = 0; i + 1 < lines.length; i += 2) {
    final code = lines[i].trim();
    final value = lines[i + 1];

    if (code == '0' && value.trim() == 'TABLE') {
      inLayerTable =
          i + 3 < lines.length &&
          lines[i + 2].trim() == '2' &&
          lines[i + 3].trim() == 'LAYER';
    } else if (inLayerTable && code == '0' && value.trim() == 'ENDTAB') {
      inLayerTable = false;
      currentLayer = null;
    } else if (inLayerTable && code == '0' && value.trim() == 'LAYER') {
      currentLayer = null;
    } else if (inLayerTable && code == '2' && value.trim() != 'LAYER') {
      currentLayer = value;
    } else if (inLayerTable && code == '62' && currentLayer != null) {
      colors[currentLayer] = int.parse(value.trim());
    }
  }

  return colors;
}

bool _layerRecordHasCode(Uint8List bytes, String layerName, String targetCode) {
  final lines = latin1.decode(bytes).split('\n');
  var inLayerTable = false;
  var inTargetLayer = false;

  for (var i = 0; i + 1 < lines.length; i += 2) {
    final code = lines[i].trim();
    final value = lines[i + 1];

    if (code == '0' && value.trim() == 'TABLE') {
      inLayerTable =
          i + 3 < lines.length &&
          lines[i + 2].trim() == '2' &&
          lines[i + 3].trim() == 'LAYER';
      inTargetLayer = false;
    } else if (inLayerTable && code == '0' && value.trim() == 'ENDTAB') {
      return false;
    } else if (inLayerTable && code == '0' && value.trim() == 'LAYER') {
      inTargetLayer = false;
    } else if (inLayerTable && code == '2' && value == layerName) {
      inTargetLayer = true;
    } else if (inTargetLayer && code == targetCode) {
      return true;
    }
  }

  return false;
}

String? _handseed(Uint8List bytes) {
  final lines = latin1.decode(bytes).split('\n');

  for (var i = 0; i + 3 < lines.length; i += 2) {
    if (lines[i].trim() == '9' && lines[i + 1].trim() == r'$HANDSEED') {
      return lines[i + 3].trim();
    }
  }

  return null;
}
