import 'package:flutter/material.dart';
import 'screens/kds_main_screen.dart';

void main() => runApp(const KdsApp());

class KdsApp extends StatelessWidget {
  const KdsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      home: const KdsMainScreen(),
    );
  }
}