import 'package:atool_app/ocr_label_rules.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('extracts the Franke sink label article number', () {
    const text = '''
FRANKE
EN 13310 GRANITE (PWD)
135.0680.631
7 612986 227697
MRG61K-MB MRG21K-XO
8721824/30/203314/9,44 KG
18/03/2026 01:51:46
''';

    expect(extractFrankeSinkLabelNumbers(text), ['135.0680.631']);
    expect(recognizedSinkLabelNumber(text), '135.0680.631');

    final match = recognizeSinkLabel(rawText: text, boxes: const []);
    expect(match?.manufacturer, OcrLabelManufacturer.franke);
    expect(match?.number, '135.0680.631');
  });

  test('normalizes common OCR separator mistakes in Franke label numbers', () {
    expect(extractFrankeSinkLabelNumbers('135-0680/631'), ['135.0680.631']);
  });

  test('prioritizes the largest Blanco 00 article number on the label', () {
    const rawText = '''
BLANCO
457002 220 S99
Auftr.-Nr. 116478464
000010
Artikel 00522963
ANDANO 450-U CNS SG SPUELE
Transport 0014936761
Packmittel 00230640
00340206841045736450
''';

    final ranked = rankBlancoSinkLabelNumbers(
      rawText: rawText,
      boxes: const [
        OcrLabelBoxText(text: '00230640', area: 800, height: 18),
        OcrLabelBoxText(text: '00522963', area: 3000, height: 42),
        OcrLabelBoxText(text: '0014936761', area: 900, height: 18),
      ],
    );

    expect(ranked.first, '00522963');
    expect(ranked, contains('00230640'));
    expect(ranked, isNot(contains('00149367')));
    expect(recognizedSinkLabelNumber('Artikel 00522963'), '00522963');

    final match = recognizeSinkLabel(
      rawText: rawText,
      boxes: const [
        OcrLabelBoxText(text: '00230640', area: 800, height: 18),
        OcrLabelBoxText(text: '00522963', area: 3000, height: 42),
      ],
    );
    expect(match?.manufacturer, OcrLabelManufacturer.blanco);
    expect(match?.number, '00522963');
  });

  test('extracts the BORA model number from the Model line', () {
    const text = '''
BORA
Model: PURMU2R
E-Nr.: 007720-10002
Type: PURE
FD 26BAZB02DE
''';

    expect(extractBoraModelNumbers(text), ['PURMU2R']);
    expect(recognizedSinkLabelNumber(text), 'PURMU2R');

    final match = recognizeSinkLabel(rawText: text, boxes: const []);
    expect(match?.manufacturer, OcrLabelManufacturer.bora);
    expect(match?.number, 'PURMU2R');
  });

  test('ignores BORA E numbers and type values', () {
    const text = '''
BORA
Model: PUXU2R
E-Nr.: 007016-10002
Type: PURE
FD 26FAXW0436
(01)04251731223718(240)007016-10002
''';

    expect(extractBoraModelNumbers(text), ['PUXU2R']);
    expect(extractBoraModelNumbers('E-Nr.: 007016-10002 Type: PURE'), isEmpty);
  });

  test('does not classify Bosch PXX model numbers as BORA labels', () {
    expect(extractBoraModelNumbers('Model: PXX82BD56E'), isEmpty);
    expect(recognizedSinkLabelNumber('PXX82BD56E'), isNull);
  });

  test('keeps manufacturer label rules in the expected priority order', () {
    expect(ocrLabelRules.map((rule) => rule.manufacturer).toList(), [
      OcrLabelManufacturer.franke,
      OcrLabelManufacturer.blanco,
      OcrLabelManufacturer.bora,
    ]);
  });
}
