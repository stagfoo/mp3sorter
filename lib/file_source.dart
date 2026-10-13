/// A [ByteSource] backed by a real file.
///
/// The one place in the quality analyser that knows what a file is, kept
/// apart so `bitrate.dart` stays pure and testable against bytes built in
/// a test.
library;

import 'dart:io';
import 'dart:typed_data';

import 'bitrate.dart';

class FileByteSource implements ByteSource {
  FileByteSource(File file)
      : length = file.lengthSync(),
        _raf = file.openSync();

  final RandomAccessFile _raf;

  @override
  final int length;

  @override
  Uint8List read(int offset, int count) {
    if (offset < 0 || offset >= length) return Uint8List(0);
    final want = count > length - offset ? length - offset : count;
    _raf.setPositionSync(offset);
    // Copied into a plain list rather than handed back as-is. `readSync`
    // returns an externally-backed Uint8List, and the frame scanner's hot
    // loop over one of those crashes the Dart JIT outright — the VM dies
    // in FlowGraph::InsertConversion with "illegal conversion
    // untagged->tagged" while selecting representations for the
    // PointerBase.data load. AOT builds are unaffected, so a release APK
    // would have shipped fine and every debug run would have died.
    //
    // The copy is a few tens of kilobytes per read and does not show up
    // against the disk access it follows.
    return Uint8List.fromList(_raf.readSync(want));
  }

  void close() => _raf.closeSync();
}
