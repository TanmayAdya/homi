import 'dart:io';
import 'dart:typed_data';

import 'matching_api_client.dart';

class IoMatchingTransport implements MatchingTransport {
  @override
  MatchingExchange post(MatchingHttpRequest request) {
    final client = HttpClient();
    return MatchingExchange(
      response: _send(client, request),
      cancel: () => client.close(force: true),
    );
  }

  Future<MatchingHttpResponse> _send(
    HttpClient client,
    MatchingHttpRequest request,
  ) async {
    try {
      final outgoing = await client.postUrl(request.endpoint);
      outgoing.followRedirects = false;
      outgoing.headers
        ..set(HttpHeaders.authorizationHeader, 'Bearer ${request.bearerToken}')
        ..set(HttpHeaders.contentTypeHeader, 'application/json; charset=utf-8')
        ..set(HttpHeaders.acceptHeader, request.accept)
        ..set(HttpHeaders.acceptEncodingHeader, 'identity');
      outgoing.add(request.body);
      final response = await outgoing.close();
      if (response.statusCode >= 300 && response.statusCode < 400) {
        throw const MatchingTransportException(
          MatchingTransportFailure.redirectBlocked,
        );
      }
      if (response.contentLength > request.maxResponseBytes) {
        throw const MatchingTransportException(
          MatchingTransportFailure.responseTooLarge,
        );
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response) {
        if (bytes.length + chunk.length > request.maxResponseBytes) {
          throw const MatchingTransportException(
            MatchingTransportFailure.responseTooLarge,
          );
        }
        bytes.add(chunk);
      }
      return MatchingHttpResponse(
        statusCode: response.statusCode,
        contentType: response.headers.value(HttpHeaders.contentTypeHeader),
        body: bytes.takeBytes(),
      );
    } on MatchingTransportException {
      rethrow;
    } catch (_) {
      throw const MatchingTransportException(MatchingTransportFailure.network);
    } finally {
      client.close(force: true);
    }
  }
}
