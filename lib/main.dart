import 'package:flutter/material.dart';

import 'app_state.dart';
import 'home_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const Mp3SorterApp());
}

class Mp3SorterApp extends StatefulWidget {
  const Mp3SorterApp({super.key});

  @override
  State<Mp3SorterApp> createState() => _Mp3SorterAppState();
}

class _Mp3SorterAppState extends State<Mp3SorterApp> {
  final AppState _app = AppState();

  @override
  void initState() {
    super.initState();
    _app.refreshUndoState();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MP3 Sorter',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF00695C)),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00695C),
          brightness: Brightness.dark,
        ),
      ),
      home: HomeScreen(app: _app),
    );
  }
}
