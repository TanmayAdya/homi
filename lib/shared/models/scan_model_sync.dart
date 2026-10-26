import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../../features/assessment/domain/scan/bathroom_scan_review.dart';
import '../../features/assessment/domain/home_safety/home_safety.dart';
import 'export_contract_values.dart';
import 'case_draft.dart';

const scanSyncMaxBytes = 768 * 1024;

class ScanModelState {
  ScanModelState.fromJson(
    Object? raw, {
    required this.caseId,
    RoomInstance? room,
  }) {
    final v = ExportContractValues.object(raw, {
      'schemaVersion',
      'caseId',
      'roomId',
      'caseRevision',
      'modelRevision',
      'reviewJson',
      'reviewSha256',
      'updatedAt',
      'updatedBy',
      'acknowledgedMutationId',
    });
    if (v['schemaVersion'] != '3' ||
        v['caseId'] != caseId ||
        v['roomId'] != room?.id) {
      throw const FormatException();
    }
    roomId = room?.id;
    caseRevision = ExportContractValues.integer(v['caseRevision']);
    modelRevision = ExportContractValues.integer(v['modelRevision'], min: 0);
    reviewJson = v['reviewJson'] as String?;
    if (reviewJson != null) {
      if (utf8.encode(reviewJson!).length > scanSyncMaxBytes ||
          sha256.convert(utf8.encode(reviewJson!)).toString() !=
              v['reviewSha256']) {
        throw const FormatException();
      }
      review = BathroomScanReview.fromJson(
        jsonDecode(reviewJson!),
        caseId,
        room: room,
      );
      if (review!.scene == null || review!.pendingScanId != null) {
        throw const FormatException();
      }
    } else if (v['reviewSha256'] != null) {
      throw const FormatException();
    }
    if (modelRevision == 0) {
      if (reviewJson != null ||
          v['updatedAt'] != null ||
          v['updatedBy'] != null ||
          v['acknowledgedMutationId'] != null) {
        throw const FormatException();
      }
    } else {
      updatedAt = ExportContractValues.instant(v['updatedAt']);
      updatedBy = ExportContractValues.id(v['updatedBy']);
    }
    acknowledgedMutationId = v['acknowledgedMutationId'] as String?;
    if (acknowledgedMutationId != null &&
        !isCaseUuidV4(acknowledgedMutationId!)) {
      throw const FormatException();
    }
  }
  late final String caseId;
  late final String? roomId, reviewJson, acknowledgedMutationId;
  late final int caseRevision, modelRevision;
  BathroomScanReview? review;
  String? updatedAt, updatedBy;
}
