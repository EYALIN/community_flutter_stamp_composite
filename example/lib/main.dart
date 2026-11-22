import 'dart:io';

import 'package:community_flutter_stamp_composite/community_flutter_stamp_composite.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() => runApp(const MaterialApp(home: ExamplePage()));

/// Composites the bundled 48 MP test JPEG to 4000 px with a stamp band and shows the result + timings.
class ExamplePage extends StatefulWidget {
  const ExamplePage({super.key});

  @override
  State<ExamplePage> createState() => _ExamplePageState();
}

class _ExamplePageState extends State<ExamplePage> {
  String _status = 'Tap to composite';
  String? _out;

  Future<void> _run() async {
    setState(() => _status = 'Working…');
    try {
      final dir = await Directory.systemTemp.createTemp('stamp');
      final src = File('${dir.path}/src.jpg');
      await src.writeAsBytes((await rootBundle.load('assets/src_48mp_o1.jpg')).buffer.asUint8List());
      final o = await CommunityFlutterStampComposite.orientedSize(src.path);
      final size = StampGeometry.outputSize(
        srcOrientedW: o['width']! as int, srcOrientedH: o['height']! as int, maxLongEdge: 4000, extraRotation: 0,
      );
      final bandH = size.height ~/ 10;
      final band = Uint8List(size.width * bandH * 4);
      for (var i = 0; i < band.length; i += 4) {
        band[i] = 0;
        band[i + 1] = 0;
        band[i + 2] = 0;
        band[i + 3] = 160; // premultiplied translucent black
      }
      final out = '${dir.path}/out.jpg';
      final r = await CommunityFlutterStampComposite.composite({
        'src': src.path, 'out': out, 'outWidth': size.width, 'outHeight': size.height, 'mirror': false, 'extraRotation': 0,
        'overlayRgba': band, 'overlayWidth': size.width, 'overlayHeight': bandH, 'overlayLeft': 0,
        'overlayTop': size.height - bandH, 'quality': 90,
        'exif': {'lat': 51.5007, 'lon': -0.1246, 'capturedLocal': '2026:11:01 12:00:00', 'utcOffset': '+02:00'},
      });
      setState(() {
        _out = out;
        _status = '${r['width']}x${r['height']} ${r['decodeMode']} total ${(r['totalMs']! as num).toStringAsFixed(0)} ms';
      });
    } on PlatformException catch (e) {
      setState(() => _status = '${e.code}: ${e.message}');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Stamp composite')),
    body: Column(
      children: [
        Padding(padding: const EdgeInsets.all(16), child: Text(_status)),
        ElevatedButton(onPressed: _run, child: const Text('Composite')),
        if (_out != null) Expanded(child: Image.file(File(_out!), key: ValueKey(_out))),
      ],
    ),
  );
}
