import 'package:flutter/services.dart';

/// The native side checks OS-authorized containers and atomically writes and
/// reads back the file. A successful plugin call alone is not proof of sharing.
class DailySpendingWidgetBridge {
  static const channel = MethodChannel('com.beecount.daily_spending_widget');

  static Future<Map<String, dynamic>> diagnostics() async =>
      Map<String, dynamic>.from(
          await channel.invokeMapMethod<String, dynamic>('diagnostics') ?? {});

  static Future<void> chooseGroup(String group) async {
    await channel.invokeMethod<void>('chooseGroup', {'group': group});
  }

  static Future<void> publish(String payload) async {
    final result = await channel.invokeMapMethod<String, dynamic>(
        'publish', {'payload': payload});
    if (result?['verified'] != true) {
      throw PlatformException(code: 'writeFailed', message: '共享数据写入校验失败');
    }
  }
}
