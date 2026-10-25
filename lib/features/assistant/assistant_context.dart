import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../../shared/models/case_draft.dart';
import '../../shared/services/case_coordinator.dart';

String assistantExcerpt(String value, int limit) {
  final runes = value.trim().runes;
  return runes.length <= limit
      ? value.trim()
      : '${String.fromCharCodes(runes.take(limit - 1))}…';
}

class AssistantContext {
  const AssistantContext({required this.key, this.findings = const []});
  final String key;
  final List<String> findings;

  factory AssistantContext.fromDraft(CaseDraft draft, String scope) =>
      AssistantContext(
        key:
            '$scope:${sha256.convert(utf8.encode(jsonEncode(draft.toJson())))}',
        findings: List.unmodifiable(
          draft.findings
              .where((finding) => finding.reviewState == 'confirmed')
              .take(4)
              .map((finding) => assistantExcerpt(finding.observation, 220)),
        ),
      );

  String get modelFindings => jsonEncode(findings);
}

AssistantContext? assistantContextFor(CaseCoordinator coordinator) {
  final draft = coordinator.draft;
  if (!coordinator.isCurrent || draft == null) return null;
  final scope = '${coordinator.generation}:${coordinator.snapshot?.revision}';
  if (coordinator.hasUndurableEdits ||
      coordinator.busy ||
      coordinator.conflict ||
      coordinator.uncertain) {
    return AssistantContext(key: '$scope:unsettled');
  }
  return AssistantContext.fromDraft(draft, scope);
}
