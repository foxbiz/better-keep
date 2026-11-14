import 'dart:convert';

import 'package:xml/xml_events.dart';
import 'package:xml/xml.dart' show XmlException;

import 'sync_provider_adapter.dart';

/// Keeps only one DAV response element in memory. Rejects deep/oversized
/// entries and validates the complete document, including ignored resources.
class DavListingReader implements Sink<List<XmlEvent>> {
  DavListingReader(this.onResponse) {
    _input = utf8.decoder.startChunkedConversion(
      XmlEventDecoder(
        validateDocument: true,
        validateNesting: true,
        validateNamespace: true,
        withNamespace: true,
      ).startChunkedConversion(
        const XmlNormalizeEvents().startChunkedConversion(this),
      ),
    );
  }
  final void Function(String) onResponse;
  late final ByteConversionSink _input;
  String? _root, _rootName;
  int _depth = 0, _size = 0;
  StringBuffer? _response;
  void addBytes(List<int> bytes) => _parse(() => _input.add(bytes));
  void finish() => _parse(_input.close);

  void _parse(void Function() operation) {
    try {
      operation();
    } on XmlException {
      throw const SyncProviderFailure(SyncProviderFailureKind.corruptData);
    } on FormatException {
      throw const SyncProviderFailure(SyncProviderFailureKind.corruptData);
    }
  }

  @override
  void add(List<XmlEvent> events) {
    for (final event in events) {
      if (event is XmlDoctypeEvent) throw const FormatException('DAV doctype');
      if (event is XmlStartElementEvent) {
        if (_depth == 0) {
          if (_root != null ||
              event.localName != 'multistatus' ||
              event.namespaceUri != 'DAV:') {
            throw const FormatException('Invalid DAV document');
          }
          _root = event.toString();
          _rootName = event.name;
        } else if (_depth == 1 &&
            event.localName == 'response' &&
            event.namespaceUri == 'DAV:') {
          _response = StringBuffer();
          _size = 0;
        }
        if (!event.isSelfClosing) _depth++;
        if (_depth > 32) throw const FormatException('DAV nesting limit');
      }
      final response = _response;
      if (response != null) {
        final text = event.toString();
        _size += text.length;
        if (_size > 65536) {
          throw const SyncProviderFailure(SyncProviderFailureKind.unsupported);
        }
        response.write(text);
      }
      if (event is XmlEndElementEvent) _depth--;
      if (_response != null && _depth == 1) {
        onResponse('$_root${_response!}</$_rootName>');
        _response = null;
      }
    }
  }

  @override
  void close() {
    if (_root == null || _depth != 0 || _response != null) {
      throw const FormatException('Incomplete DAV listing');
    }
  }
}
