import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'home_screen.dart';
import 'library.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ReaderApp());
}

class ReaderApp extends StatelessWidget {
  const ReaderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flipbook Reader',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorSchemeSeed: const Color(0xFF1565C0),
        useMaterial3: true,
      ),
      home: ChangeNotifierProvider(create: (_) => Library(), child: const HomeScreen()),
    );
  }
}
