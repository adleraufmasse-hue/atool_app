class OcrLabelBoxText {
  final String text;
  final double area;
  final double height;

  const OcrLabelBoxText({
    required this.text,
    required this.area,
    required this.height,
  });
}

enum OcrLabelManufacturer {
  franke('Franke'),
  blanco('Blanco'),
  bora('BORA');

  final String displayName;

  const OcrLabelManufacturer(this.displayName);
}

class OcrLabelMatch {
  final OcrLabelManufacturer manufacturer;
  final String number;
  final List<String> candidates;

  const OcrLabelMatch({
    required this.manufacturer,
    required this.number,
    required this.candidates,
  });
}

typedef OcrLabelCandidateRanker =
    List<String> Function({
      required String rawText,
      required List<OcrLabelBoxText> boxes,
    });

class OcrLabelRule {
  final OcrLabelManufacturer manufacturer;
  final OcrLabelCandidateRanker rankCandidates;

  const OcrLabelRule({
    required this.manufacturer,
    required this.rankCandidates,
  });
}

final List<OcrLabelRule> ocrLabelRules = [
  OcrLabelRule(
    manufacturer: OcrLabelManufacturer.franke,
    rankCandidates: _rankFrankeSinkLabelNumbers,
  ),
  OcrLabelRule(
    manufacturer: OcrLabelManufacturer.blanco,
    rankCandidates: _rankBlancoSinkLabelNumbers,
  ),
  OcrLabelRule(
    manufacturer: OcrLabelManufacturer.bora,
    rankCandidates: _rankBoraModelNumbers,
  ),
];

OcrLabelMatch? recognizeSinkLabel({
  required String rawText,
  required List<OcrLabelBoxText> boxes,
}) {
  for (final rule in ocrLabelRules) {
    final candidates = rule.rankCandidates(rawText: rawText, boxes: boxes);
    if (candidates.isEmpty) continue;

    return OcrLabelMatch(
      manufacturer: rule.manufacturer,
      number: candidates.first,
      candidates: candidates,
    );
  }

  return null;
}

List<String> extractFrankeSinkLabelNumbers(String input) {
  final labels = <String>[];

  void addLabel(RegExpMatch match) {
    final first = match.group(1);
    final second = match.group(2);
    final third = match.group(3);
    if (first == null || second == null || third == null) return;

    final label = '$first.$second.$third';
    if (!labels.contains(label)) labels.add(label);
  }

  for (final match in RegExp(
    r'\b(\d{3})\s*[.\-/]\s*(\d{4})\s*[.\-/]\s*(\d{3})\b',
  ).allMatches(input)) {
    addLabel(match);
  }

  return labels;
}

List<String> _rankFrankeSinkLabelNumbers({
  required String rawText,
  required List<OcrLabelBoxText> boxes,
}) {
  final labels = <String>[];

  void addLabels(String value) {
    for (final label in extractFrankeSinkLabelNumbers(value)) {
      if (!labels.contains(label)) labels.add(label);
    }
  }

  for (final box in boxes) {
    addLabels(box.text);
  }
  addLabels(rawText);

  return labels;
}

List<String> extractBlancoSinkLabelNumbers(String input) {
  final labels = <String>[];

  for (final match in RegExp(r'\b00\d{6}\b').allMatches(input)) {
    final label = match.group(0);
    if (label != null && !labels.contains(label)) labels.add(label);
  }

  return labels;
}

List<String> rankBlancoSinkLabelNumbers({
  required String rawText,
  required List<OcrLabelBoxText> boxes,
}) => _rankBlancoSinkLabelNumbers(rawText: rawText, boxes: boxes);

List<String> _rankBlancoSinkLabelNumbers({
  required String rawText,
  required List<OcrLabelBoxText> boxes,
}) {
  final candidateScores = <String, double>{};

  void addCandidate(String value, double score) {
    for (final label in extractBlancoSinkLabelNumbers(value)) {
      final existingScore = candidateScores[label];
      if (existingScore == null || score > existingScore) {
        candidateScores[label] = score;
      }
    }
  }

  for (final box in boxes) {
    addCandidate(box.text, box.height * 1000000 + box.area);
  }
  addCandidate(rawText, 0);

  return candidateScores.keys.toList()..sort((a, b) {
    final scoreCompare = (candidateScores[b] ?? 0).compareTo(
      candidateScores[a] ?? 0,
    );
    if (scoreCompare != 0) return scoreCompare;
    return a.compareTo(b);
  });
}

List<String> extractBoraModelNumbers(String input) {
  final models = <String>[];

  void addModel(String value) {
    final model = value.trim().toUpperCase().replaceAll(
      RegExp(r'[^A-Z0-9]'),
      '',
    );
    if (!_looksLikeBoraModelCode(model)) return;
    if (!models.contains(model)) models.add(model);
  }

  final normalized = input.toUpperCase().replaceAll(RegExp(r'\s+'), ' ');

  for (final match in RegExp(
    r'\b(?:MODEL|MODELL)\b\s*[:\-]?\s*([A-Z0-9][A-Z0-9._\/\-]{2,24})',
  ).allMatches(normalized)) {
    final value = match.group(1);
    if (value == null) continue;
    addModel(value);
  }

  return models;
}

List<String> rankBoraModelNumbers({
  required String rawText,
  required List<OcrLabelBoxText> boxes,
}) => _rankBoraModelNumbers(rawText: rawText, boxes: boxes);

List<String> _rankBoraModelNumbers({
  required String rawText,
  required List<OcrLabelBoxText> boxes,
}) {
  final models = <String>[];

  void addModels(String value) {
    for (final model in extractBoraModelNumbers(value)) {
      if (!models.contains(model)) models.add(model);
    }
  }

  for (final box in boxes) {
    addModels(box.text);
  }
  addModels(rawText);

  return models;
}

bool _looksLikeBoraModelCode(String value) {
  if (value.length < 5 || value.length > 14) return false;
  const boraPrefixes = ['PU', 'PK', 'CK', 'BF', 'BH'];
  if (!boraPrefixes.any(value.startsWith)) return false;
  if (!RegExp(r'\d').hasMatch(value)) return false;
  if (!RegExp(r'^[A-Z0-9]+$').hasMatch(value)) return false;

  const ignored = {'PURE'};
  return !ignored.contains(value);
}

String? recognizedSinkLabelNumber(String input) {
  return recognizeSinkLabel(rawText: input, boxes: const [])?.number;
}
