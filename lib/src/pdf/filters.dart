// Stream filter decoding — only what xref streams and object streams need:
// FlateDecode (zlib) with optional TIFF/PNG predictors. Anything else on
// those streams raises UnsupportedPdfException; page content streams are
// never decoded by this library.
import 'dart:io';
import 'dart:typed_data';

import '../cos/objects.dart';
import '../exceptions.dart';

/// Decodes [stream]'s data according to its /Filter and /DecodeParms.
/// [resolve] follows indirect references inside the dict.
Uint8List decodeStream(CosStream stream, CosObject? Function(CosObject?) resolve) {
  final dict = stream.dict;
  var data = stream.rawData;

  final filterObj = resolve(dict['Filter']);
  if (filterObj == null || filterObj is CosNull) return data;

  final filters = <String>[];
  if (filterObj is CosName) {
    filters.add(filterObj.name);
  } else if (filterObj is CosArray) {
    for (final f in filterObj.items) {
      final r = resolve(f);
      if (r is! CosName) throw PdfParseException('bad /Filter entry');
      filters.add(r.name);
    }
  } else {
    throw PdfParseException('bad /Filter value');
  }

  final parmsObj = resolve(dict['DecodeParms'] ?? dict['DP']);
  final parmsList = <CosDict?>[];
  if (parmsObj is CosDict) {
    parmsList.add(parmsObj);
  } else if (parmsObj is CosArray) {
    for (final p in parmsObj.items) {
      final r = resolve(p);
      parmsList.add(r is CosDict ? r : null);
    }
  }

  for (var i = 0; i < filters.length; i++) {
    final name = filters[i];
    final parms = i < parmsList.length ? parmsList[i] : null;
    switch (name) {
      case 'FlateDecode':
      case 'Fl':
        try {
          data = Uint8List.fromList(zlib.decode(data));
        } catch (e) {
          throw PdfParseException('FlateDecode failed: $e');
        }
        data = _applyPredictor(data, parms, resolve);
        break;
      default:
        throw UnsupportedPdfException(
            'stream filter /$name is not supported (only FlateDecode)');
    }
  }
  return data;
}

Uint8List _applyPredictor(
    Uint8List data, CosDict? parms, CosObject? Function(CosObject?) resolve) {
  if (parms == null) return data;
  final predictor = _intFrom(parms, 'Predictor', resolve) ?? 1;
  if (predictor <= 1) return data;

  final colors = _intFrom(parms, 'Colors', resolve) ?? 1;
  final bpc = _intFrom(parms, 'BitsPerComponent', resolve) ?? 8;
  final columns = _intFrom(parms, 'Columns', resolve) ?? 1;
  final bytesPerPixel = (colors * bpc + 7) ~/ 8;
  final rowLength = (columns * colors * bpc + 7) ~/ 8;

  if (predictor == 2) {
    // TIFF predictor: horizontal differencing (8-bit components only).
    if (bpc != 8) {
      throw UnsupportedPdfException('TIFF predictor with BitsPerComponent=$bpc');
    }
    final out = Uint8List.fromList(data);
    for (var r = 0; r + rowLength <= out.length; r += rowLength) {
      for (var i = bytesPerPixel; i < rowLength; i++) {
        out[r + i] = (out[r + i] + out[r + i - bytesPerPixel]) & 0xff;
      }
    }
    return out;
  }

  // PNG predictors (10-15): each row prefixed with a filter-type byte.
  final rows = data.length ~/ (rowLength + 1);
  final out = Uint8List(rows * rowLength);
  var prevRowStart = -1;
  for (var r = 0; r < rows; r++) {
    final inStart = r * (rowLength + 1);
    final filterType = data[inStart];
    final outStart = r * rowLength;
    for (var i = 0; i < rowLength; i++) {
      final raw = data[inStart + 1 + i];
      final left = i >= bytesPerPixel ? out[outStart + i - bytesPerPixel] : 0;
      final up = prevRowStart >= 0 ? out[prevRowStart + i] : 0;
      final upLeft = (prevRowStart >= 0 && i >= bytesPerPixel)
          ? out[prevRowStart + i - bytesPerPixel]
          : 0;
      final int recon;
      switch (filterType) {
        case 0:
          recon = raw;
          break;
        case 1:
          recon = raw + left;
          break;
        case 2:
          recon = raw + up;
          break;
        case 3:
          recon = raw + ((left + up) >> 1);
          break;
        case 4:
          recon = raw + _paeth(left, up, upLeft);
          break;
        default:
          throw PdfParseException('bad PNG filter type $filterType');
      }
      out[outStart + i] = recon & 0xff;
    }
    prevRowStart = outStart;
  }
  return out;
}

int _paeth(int a, int b, int c) {
  final p = a + b - c;
  final pa = (p - a).abs();
  final pb = (p - b).abs();
  final pc = (p - c).abs();
  if (pa <= pb && pa <= pc) return a;
  if (pb <= pc) return b;
  return c;
}

int? _intFrom(
    CosDict dict, String key, CosObject? Function(CosObject?) resolve) {
  final v = resolve(dict[key]);
  return v is CosNumber ? v.asInt : null;
}
