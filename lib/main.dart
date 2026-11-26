import 'package:flutter/material.dart';

import 'ui/home_screen.dart';
import 'ui/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const Mp3SorterApp());
}

class Mp3SorterApp extends StatelessWidget {
  const Mp3SorterApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'mp3sorter',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: const HomeScreen(),
    );
  }
}
