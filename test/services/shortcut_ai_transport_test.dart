import 'dart:convert';
import 'dart:io';
import 'package:beecount/ai/providers/ai_provider_config.dart';
import 'package:beecount/data/db.dart';
import 'package:beecount/data/repositories/local/local_repository.dart';
import 'package:beecount/providers/database_providers.dart';
import 'package:beecount/services/automation/shortcut_service.dart';
import 'package:beecount/services/system/logger_service.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _RealHttp extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'configured OpenAI transport separates OCR and image and hides upstream errors',
      () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final db = BeeDatabase.forTesting(NativeDatabase.memory());
      final repo = LocalRepository(db);
      final container = ProviderContainer(
          overrides: [repositoryProvider.overrideWithValue(repo)]);
      final directory =
          await Directory.systemTemp.createTemp('shortcut-transport-');
      final requests = <Map<String, dynamic>>[];
      var fail = false;
      var failStatus = 500;
      server.listen((request) async {
        expect(request.uri.path, '/v1/chat/completions');
        requests.add(jsonDecode(await utf8.decoder.bind(request).join())
            as Map<String, dynamic>);
        request.response.headers.contentType = ContentType.json;
        if (fail) {
          request.response.statusCode = failStatus;
          request.response.write(jsonEncode({
            'error': {'message': 'private upstream bill text'}
          }));
        } else {
          request.response.write(jsonEncode({
            'choices': [
              {
                'message': {
                  'content': jsonEncode([
                    {
                      'type': 'expense',
                      'amount': '12.30',
                      'currency': 'CNY',
                      'note': '账单原文'
                    }
                  ])
                }
              }
            ]
          }));
        }
        await request.response.close();
      });
      try {
        final config = AIServiceProviderConfig(
            id: 'local-test',
            name: 'local-test',
            apiKey: 'test-only',
            baseUrl: ' http://127.0.0.1:' + server.port.toString() + '/v1/ ',
            textModel: 'text-test',
            visionModel: 'vision-test',
            createdAt: DateTime(2026));
        SharedPreferences.setMockInitialValues({
          'ai_providers_v2': jsonEncode([config.toJson()]),
          'ai_capability_binding_v2': jsonEncode({
            'textProviderId': 'local-test',
            'visionProviderId': 'local-test'
          }),
        });
        final ledger = await repo.createLedger(name: 'Test');
        final family = await repo.createTag(name: '家庭');
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(
            shortcutDefaultsKey,
            jsonEncode({
              'tagIds': [family],
              'excludeFromBudget': true
            }));
        final service = ShortcutService(container);
        final text = await service.handle({
          'operation': 'recognize',
          'mode': 'text',
          'ledgerId': ledger,
          'text': 'private OCR 12.30'
        });
        expect(text['status'], 'draft');
        expect(requests.single['model'], 'text-test');
        expect(requests.single['messages'][0]['content'], isA<String>());
        expect(jsonEncode(requests.single), isNot(contains('image_url')));
        final image = File(directory.path + '/test.jpg');
        await image.writeAsBytes([255, 216, 255, 217]);
        final vision = await service.handle({
          'operation': 'recognize',
          'mode': 'image',
          'ledgerId': ledger,
          'imagePath': image.path,
          'tagIds': <int>[],
          'excludeFromBudget': false
        });
        expect(vision['status'], 'draft');
        final candidate = (vision['candidates'] as List).single;
        expect(candidate['amountMinor'], 1230);
        expect(candidate['tagIds'], isEmpty);
        expect(candidate['excludeFromBudget'], false);
        expect(requests.last['model'], 'vision-test');
        final content = requests.last['messages'][0]['content'] as List;
        expect(content.last['type'], 'image_url');
        expect(content.last['image_url']['url'],
            startsWith('data:image/jpeg;base64,'));
        fail = true;
        final failure = await service.handle({
          'operation': 'recognize',
          'mode': 'text',
          'ledgerId': ledger,
          'text': 'private OCR 12.30'
        });
        expect(failure['code'], 'AI_UNAVAILABLE');
        failStatus = 401;
        final unauthorized = await service.handle({
          'operation': 'recognize',
          'mode': 'image',
          'ledgerId': ledger,
          'imagePath': image.path
        });
        expect(unauthorized['message'], contains('密钥验证失败'));
        expect(
            logger.logs.any((l) =>
                l.toFormattedString().contains('private upstream bill text')),
            false);
        expect(await db.select(db.transactions).get(), isEmpty);
      } finally {
        container.dispose();
        await db.close();
        await server.close(force: true);
        await directory.delete(recursive: true);
      }
    }, _RealHttp());
  });
}
