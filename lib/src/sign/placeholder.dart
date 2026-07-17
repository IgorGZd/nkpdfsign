// Builds the signature field objects and wires them into the document
// structure (AcroForm, Catalog, page /Annots) as an incremental update.
import 'dart:convert';
import 'dart:typed_data';

import '../cos/objects.dart';
import '../pdf/document.dart';
import '../pdf/incremental.dart';

class PlaceholderResult {
  PlaceholderResult(this.byteRange, this.contents, this.reservedSignatureBytes,
      this.fieldName);

  /// Marker for `[0 9999999999 9999999999 9999999999]` (patched later).
  final CosRaw byteRange;

  /// Marker for `<000...0>` (CMS DER spliced in later).
  final CosRaw contents;

  final int reservedSignatureBytes;
  final String fieldName;
}

/// Adds an invisible signature field ([rect] 0,0,0,0) to the first page.
PlaceholderResult addSignaturePlaceholder(
  PdfDocument document,
  IncrementalUpdater updater, {
  required String fieldName,
  required int signatureSizeBytes,
  String? reason,
  String? location,
  String? contactInfo,
  String? signerName,
  DateTime? signingTime,
}) {
  final uniqueName = _uniqueFieldName(document, fieldName);

  final byteRangeRaw = CosRaw(Uint8List.fromList(
      latin1.encode('[0 9999999999 9999999999 9999999999]')));
  final contentsRaw = CosRaw(
      Uint8List.fromList(latin1.encode('<${'0' * (signatureSizeBytes * 2)}>')));

  final sigDict = CosDict();
  sigDict['Type'] = const CosName('Sig');
  sigDict['Filter'] = const CosName('Adobe.PPKLite');
  sigDict['SubFilter'] = const CosName('adbe.pkcs7.detached');
  // /Contents must come after /ByteRange (insertion order is preserved).
  sigDict['ByteRange'] = byteRangeRaw;
  sigDict['Contents'] = contentsRaw;
  sigDict['M'] = _pdfDate(signingTime ?? DateTime.now());
  if (signerName != null) sigDict['Name'] = _text(signerName);
  if (reason != null) sigDict['Reason'] = _text(reason);
  if (location != null) sigDict['Location'] = _text(location);
  if (contactInfo != null) sigDict['ContactInfo'] = _text(contactInfo);
  final sigRef = updater.addObject(sigDict);

  final (pageRef, pageDict) = document.firstPage();

  // Merged signature field + widget annotation (invisible: zero rect,
  // /F 132 = PRINT | LOCKED).
  final widget = CosDict();
  widget['Type'] = const CosName('Annot');
  widget['Subtype'] = const CosName('Widget');
  widget['FT'] = const CosName('Sig');
  widget['Rect'] =
      CosArray([CosNumber(0), CosNumber(0), CosNumber(0), CosNumber(0)]);
  widget['F'] = CosNumber(132);
  widget['T'] = _text(uniqueName);
  widget['V'] = sigRef;
  widget['P'] = pageRef;
  final widgetRef = updater.addObject(widget);

  _wireAnnots(document, updater, pageRef, pageDict, widgetRef);
  _wireAcroForm(document, updater, widgetRef);

  return PlaceholderResult(
      byteRangeRaw, contentsRaw, signatureSizeBytes, uniqueName);
}

CosString _text(String s) {
  final bytes = latin1.encode(s); // PDFDocEncoding ~ latin1 for our fields
  return CosString(Uint8List.fromList(bytes));
}

CosString _pdfDate(DateTime t) {
  final u = t.toUtc();
  String p2(int v) => v.toString().padLeft(2, '0');
  final s = 'D:${u.year.toString().padLeft(4, '0')}${p2(u.month)}${p2(u.day)}'
      '${p2(u.hour)}${p2(u.minute)}${p2(u.second)}Z';
  return CosString(Uint8List.fromList(latin1.encode(s)));
}

CosDict _copyDict(CosDict d) => CosDict(Map.of(d.entries));

void _wireAnnots(PdfDocument document, IncrementalUpdater updater,
    CosRef pageRef, CosDict pageDict, CosRef widgetRef) {
  final annots = pageDict['Annots'];
  if (annots is CosRef) {
    final arr = document.resolve(annots);
    final newArr =
        CosArray([...(arr is CosArray ? arr.items : <CosObject>[]), widgetRef]);
    updater.updateObject(annots, newArr);
  } else if (annots is CosArray) {
    final newPage = _copyDict(pageDict);
    newPage['Annots'] = CosArray([...annots.items, widgetRef]);
    updater.updateObject(pageRef, newPage);
  } else {
    final newPage = _copyDict(pageDict);
    newPage['Annots'] = CosArray([widgetRef]);
    updater.updateObject(pageRef, newPage);
  }
}

void _wireAcroForm(
    PdfDocument document, IncrementalUpdater updater, CosRef fieldRef) {
  final acroObj = document.catalog['AcroForm'];

  if (acroObj is CosRef) {
    final acro = document.resolve(acroObj);
    if (acro is! CosDict) {
      _attachNewAcroForm(document, updater, fieldRef);
      return;
    }
    final newAcro = _copyDict(acro);
    _appendField(document, updater, newAcro, fieldRef);
    newAcro['SigFlags'] = CosNumber(3);
    updater.updateObject(acroObj, newAcro);
  } else if (acroObj is CosDict) {
    final newAcro = _copyDict(acroObj);
    _appendField(document, updater, newAcro, fieldRef);
    newAcro['SigFlags'] = CosNumber(3);
    final newCatalog = _copyDict(document.catalog);
    newCatalog['AcroForm'] = newAcro;
    updater.updateObject(document.catalogRef, newCatalog);
  } else {
    _attachNewAcroForm(document, updater, fieldRef);
  }
}

void _attachNewAcroForm(
    PdfDocument document, IncrementalUpdater updater, CosRef fieldRef) {
  final acro = CosDict();
  acro['Fields'] = CosArray([fieldRef]);
  acro['SigFlags'] = CosNumber(3);
  final acroRef = updater.addObject(acro);
  final newCatalog = _copyDict(document.catalog);
  newCatalog['AcroForm'] = acroRef;
  updater.updateObject(document.catalogRef, newCatalog);
}

/// Appends [fieldRef] to /Fields, whether the array is direct or indirect.
void _appendField(PdfDocument document, IncrementalUpdater updater,
    CosDict acroForm, CosRef fieldRef) {
  final fields = acroForm['Fields'];
  if (fields is CosRef) {
    final arr = document.resolve(fields);
    final newArr =
        CosArray([...(arr is CosArray ? arr.items : <CosObject>[]), fieldRef]);
    updater.updateObject(fields, newArr);
  } else if (fields is CosArray) {
    acroForm['Fields'] = CosArray([...fields.items, fieldRef]);
  } else {
    acroForm['Fields'] = CosArray([fieldRef]);
  }
}

String _uniqueFieldName(PdfDocument document, String base) {
  final existing = <String>{};
  void collect(CosObject? fieldsObj, int depth) {
    if (depth > 32) return;
    final fields = document.resolve(fieldsObj);
    if (fields is! CosArray) return;
    for (final f in fields.items) {
      final field = document.resolve(f);
      if (field is! CosDict) continue;
      final t = field['T'];
      if (t is CosString) {
        existing.add(latin1.decode(t.bytes, allowInvalid: true));
      }
      collect(field['Kids'], depth + 1);
    }
  }

  final acro = document.resolve(document.catalog['AcroForm']);
  if (acro is CosDict) collect(acro['Fields'], 0);

  if (!existing.contains(base)) return base;
  // "Signature1" -> try Signature2, Signature3, ...
  final match = RegExp(r'^(.*?)(\d+)$').firstMatch(base);
  final stem = match != null ? match.group(1)! : base;
  var n = match != null ? int.parse(match.group(2)!) + 1 : 2;
  while (existing.contains('$stem$n')) {
    n++;
  }
  return '$stem$n';
}
