import 'package:flutter/material.dart';
import 'ui/modem_home.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const HuaweiE173App());
}

class HuaweiE173App extends StatelessWidget {
  const HuaweiE173App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Huawei E173 Portable Manager',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1D4ED8),
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xFFF8FAFC),
      ),
      home: const ModemHomePage(),
    );
  }
}
