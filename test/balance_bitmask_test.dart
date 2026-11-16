import 'package:flutter_test/flutter_test.dart';
import 'package:jbd_bms_android/models/bms_data.dart';

List<int> _frame(List<int> payload) {
  final len = payload.length;
  return [0xDD, 0xA5, 0x00, len, ...payload, 0x00, 0x00, 0x77];
}

void main() {
  test('parseBasicInfo extrai bitmask de balanceamento por célula', () {
    // Células 1 e 5 balanceando (bits 0 e 4) -> mask 0x00000011
    final payload = <int>[
      0x14, 0x30, // total voltage 51.68V
      0x00, 0x64, // current
      0x1F, 0x40, // residual cap
      0x27, 0x10, // nominal cap
      0x00, 0x0A, // cycles
      0x00, 0x00, // date
      0x00, 0x00, 0x00, 0x11, // balance bitmask: bits 0 e 4
      0x00, 0x00, // protection
      0x08, // version
      0x50, // soc 80%
      0x03, // fet status
      0x04, // células
      0x00, 0x02, // ntc count = 2
      0x0B, 0xB8, // temp1
      0x0B, 0xC8, // temp2
    ];

    final d = JbdParser.parseBasicInfo(_frame(payload));

    expect(d, isNotNull);
    expect(d!.balanceBitmask, 0x11);
    expect(d.balancer, isTrue);
    expect(d.isCellBalancing(0), isTrue);  // célula 1
    expect(d.isCellBalancing(4), isTrue);  // célula 5
    expect(d.isCellBalancing(1), isFalse);
    expect(d.isCellBalancing(15), isFalse);

    // Sem balanceamento -> mask zero
    final payload2 = List<int>.from(payload)..[15] = 0; // byte baixo do mask
    final d2 = JbdParser.parseBasicInfo(_frame(payload2));
    expect(d2!.balanceBitmask, 0x00);
    expect(d2.isCellBalancing(0), isFalse);
  });
}
