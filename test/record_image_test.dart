import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:scoreyomipm/ui/record_image.dart';

import 'fake_play_record_repository.dart';

void main() {
  testWidgets(
    'RecordImage: 画像がある場合は Image.memory を表示する',
    (tester) async {
      final repo = FakePlayRecordRepository();
      repo.images['test.png'] = Uint8List.fromList(<int>[0x89, 0x50, 0x4E, 0x47]);

      await tester.pumpWidget(
        MaterialApp(
          home: RecordImage(repository: repo, imageName: 'test.png'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(Image), findsOneWidget);
    },
  );

  testWidgets(
    'RecordImage: 画像がない場合（マップ未登録）は fallback アイコンを表示する',
    (tester) async {
      final repo = FakePlayRecordRepository();
      // images マップに入れない → 欠損

      await tester.pumpWidget(
        MaterialApp(
          home: RecordImage(repository: repo, imageName: 'missing.png'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
    },
  );
}
