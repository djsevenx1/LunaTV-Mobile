// v2.2.5 修复的端到端验证 — 把 unwrapCfWorker + wrap 拉出来跑全 case
// 不依赖 Flutter SDK, 纯 dart:io + dart:core

import 'dart:io';

String? unwrapCfWorker(String url, String workerDomain) {
  if (workerDomain.isEmpty) return null;
  final cleanWorker = workerDomain.trim();
  if (cleanWorker.isEmpty) return null;
  final patterns = <String>[
    'https://$cleanWorker/?url=',
    'http://$cleanWorker/?url=',
    'https://$cleanWorker/m3u8?url=',
    'http://$cleanWorker/m3u8?url=',
  ];
  String? inner;
  for (final p in patterns) {
    if (url.startsWith(p)) {
      inner = url.substring(p.length);
      break;
    }
  }
  if (inner == null) return null;
  try {
    return Uri.decodeComponent(inner);
  } catch (_) {
    return null;
  }
}

String? wrap(String url, String localBase, String workerDomain) {
  if (url.isEmpty) return url;
  final unwrapped = unwrapCfWorker(url, workerDomain);
  if (unwrapped != null) {
    url = unwrapped;
  }
  Uri u;
  try {
    if (url.startsWith('http://') || url.startsWith('https://')) {
      u = Uri.parse(url);
    } else {
      return null;
    }
  } catch (_) {
    return null;
  }
  if (u.host == '127.0.0.1' || u.host == 'localhost') return null;
  if (workerDomain.isNotEmpty && u.host == workerDomain.trim()) return null;
  final pathLower = u.path.toLowerCase();
  final isM3u8Url = pathLower.endsWith('.m3u8') ||
      pathLower.endsWith('.m3u') ||
      pathLower.contains('/m3u8');
  final endpoint = isM3u8Url ? '/m3u8' : '/';
  return '$localBase$endpoint?url=${Uri.encodeComponent(u.toString())}';
}

int passed = 0;
int failed = 0;

void check(String name, String? got, String expected) {
  final ok = got == expected;
  if (ok) {
    passed++;
    print('  PASS: $name');
  } else {
    failed++;
    print('  FAIL: $name');
    print('    got:      $got');
    print('    expected: $expected');
  }
}

void main() {
  const worker = 'api.fn0.qzz.io';
  const localBase = 'http://127.0.0.1:34459';

  print('=== Test 1: unwrapCfWorker 4 pattern ===');
  // 1.1 /?url= 形式 (旧)
  check('1.1 /?url= form',
    unwrapCfWorker('https://$worker/?url=https%3A%2F%2Fplay.ly166.com%3A65%2Ftest.m3u8', worker),
    'https://play.ly166.com:65/test.m3u8');
  // 1.2 /?url= http
  check('1.2 /?url= http',
    unwrapCfWorker('http://$worker/?url=https%3A%2F%2Fcdn.com%2Fseg.ts', worker),
    'https://cdn.com/seg.ts');
  // 1.3 /m3u8?url= 形式 (新)
  check('1.3 /m3u8?url= form',
    unwrapCfWorker('https://$worker/m3u8?url=https%3A%2F%2Fv4.lbb2026.com%2F20250106%2FauVHhrkA%2F2000kb%2Fhls%2Findex.m3u8', worker),
    'https://v4.lbb2026.com/20250106/auVHhrkA/2000kb/hls/index.m3u8');
  // 1.4 /m3u8?url= http
  check('1.4 /m3u8?url= http',
    unwrapCfWorker('http://$worker/m3u8?url=https%3A%2F%2Fcdn.com%2Fmaster.m3u8', worker),
    'https://cdn.com/master.m3u8');
  // 1.5 不认识的形式
  check('1.5 unrelated URL',
    unwrapCfWorker('https://other.com/?url=foo', worker),
    null);
  // 1.6 worker 域但非 ?url=
  check('1.6 worker root',
    unwrapCfWorker('https://$worker/', worker),
    null);

  print('');
  print('=== Test 2: wrap 端点选择 ===');
  // 2.1 .m3u8 → /m3u8?url=
  check('2.1 .m3u8 → /m3u8?url=',
    wrap('https://v4.lbb2026.com/20250106/auVHhrkA/index.m3u8', localBase, worker),
    '$localBase/m3u8?url=${Uri.encodeComponent('https://v4.lbb2026.com/20250106/auVHhrkA/index.m3u8')}');
  // 2.2 .m3u → /m3u8?url=
  check('2.2 .m3u → /m3u8?url=',
    wrap('https://cdn.com/playlist.m3u', localBase, worker),
    '$localBase/m3u8?url=${Uri.encodeComponent('https://cdn.com/playlist.m3u')}');
  // 2.3 .ts → /?url=
  check('2.3 .ts → /?url=',
    wrap('https://cdn.com/seg001.ts', localBase, worker),
    '$localBase/?url=${Uri.encodeComponent('https://cdn.com/seg001.ts')}');
  // 2.4 .key → /?url=
  check('2.4 .key → /?url=',
    wrap('https://cdn.com/key.key', localBase, worker),
    '$localBase/?url=${Uri.encodeComponent('https://cdn.com/key.key')}');
  // 2.5 .jpeg → /?url=
  check('2.5 .jpeg → /?url=',
    wrap('https://play.ly166.com:65/screen.jpeg', localBase, worker),
    '$localBase/?url=${Uri.encodeComponent('https://play.ly166.com:65/screen.jpeg')}');
  // 2.6 .mp4 → /?url=
  check('2.6 .mp4 → /?url=',
    wrap('https://cdn.com/video.mp4', localBase, worker),
    '$localBase/?url=${Uri.encodeComponent('https://cdn.com/video.mp4')}');

  print('');
  print('=== Test 3: wrap 双重解 worker wrap ===');
  // 3.1 worker /?url= (m3u8 段) → 解到原 m3u8 → 包成 /?url= (段)
  check('3.1 unwrap /?url= (seg) → /?url=',
    wrap('https://$worker/?url=https%3A%2F%2Fcdn.com%2Fseg.ts', localBase, worker),
    '$localBase/?url=${Uri.encodeComponent('https://cdn.com/seg.ts')}');
  // 3.2 worker /m3u8?url= (variant) → 解到原 m3u8 → 包成 /m3u8?url= (m3u8)
  // 这是 v2.2.5 关键修: 之前 variant 被解完会包成 /?url= (错), 现在包成 /m3u8?url= (对)
  check('3.2 unwrap /m3u8?url= (variant) → /m3u8?url=',
    wrap('https://$worker/m3u8?url=https%3A%2F%2Fv4.lbb2026.com%2F2000kb%2Fhls%2Findex.m3u8', localBase, worker),
    '$localBase/m3u8?url=${Uri.encodeComponent('https://v4.lbb2026.com/2000kb/hls/index.m3u8')}');
  // 3.3 本地代理 URL → 跳过
  check('3.3 local proxy URL skipped',
    wrap('$localBase/m3u8?url=foo', localBase, worker),
    null);
  check('3.3b local proxy seg URL skipped',
    wrap('$localBase/?url=foo', localBase, worker),
    null);

  print('');
  print('=== Test 4: 主入口端到端 ===');
  // 4.1 master playlist 的 variant 改写 (v2.2.5 主修)
  String variantRaw = 'https://$worker/m3u8?url=https%3A%2F%2Fv4.lbb2026.com%2F20250106%2FauVHhrkA%2F%2F2000kb%2Fhls%2Findex.m3u8';
  String? variantRewritten = wrap(variantRaw, localBase, worker);
  print('  master playlist variant:');
  print('    raw:       $variantRaw');
  print('    rewritten: $variantRewritten');
  // 验证: 应该是 local proxy /m3u8?url=<encoded v4.lbb2026.com 2000kb>
  final expect4_1 = '$localBase/m3u8?url=${Uri.encodeComponent('https://v4.lbb2026.com/20250106/auVHhrkA//2000kb/hls/index.m3u8')}';
  check('4.1 variant end-to-end', variantRewritten, expect4_1);

  // 4.2 jpeg 段改写
  String segRaw = 'https://$worker/?url=https%3A%2F%2Fplay.ly166.com%3A65%2F...%2Findex.jpeg';
  String? segRewritten = wrap(segRaw, localBase, worker);
  print('  jpeg segment:');
  print('    raw:       $segRaw');
  print('    rewritten: $segRewritten');
  check('4.2 jpeg seg → /?url=',
    segRewritten,
    '$localBase/?url=${Uri.encodeComponent('https://play.ly166.com:65/.../index.jpeg')}');

  // 4.3 AES-128 key 改写
  String keyRaw = 'https://$worker/?url=https%3A%2F%2Fv4.lbb2026.com%2F...%2Fkey.key';
  String? keyRewritten = wrap(keyRaw, localBase, worker);
  print('  AES-128 key:');
  print('    raw:       $keyRaw');
  print('    rewritten: $keyRewritten');
  check('4.3 AES-128 key → /?url=',
    keyRewritten,
    '$localBase/?url=${Uri.encodeComponent('https://v4.lbb2026.com/.../key.key')}');

  print('');
  print('=== 总结 ===');
  print('passed: $passed');
  print('failed: $failed');
  if (failed > 0) {
    exit(1);
  }
}
