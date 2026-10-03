// probe.dart — 격리(lg-test.sb) 탐침. 격리 안에서 시험 코드가 할 법한 짓을 하나씩 해 보고 결과만 낸다.
// sandboxed-run.mjs 의 canary()·음성 시험이 임시 폴더에 복사해 `dart probe.dart '<JSON 배열>'` 로 부른다.
// 입력: [{"op": "net", "a": ["1.1.1.1", "80"]}, …]  출력: 한 줄 JSON 배열 [{"op","a","ok","err"}].
// 읽은 내용·받은 응답은 내지 않는다(비밀이 출력으로 새지 않게) — 됐는지(ok)와 오류 종류만.
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

final _libc = DynamicLibrary.process();
final _malloc = _libc.lookupFunction<Pointer<Uint8> Function(IntPtr), Pointer<Uint8> Function(int)>('malloc');
final _link = _libc.lookupFunction<Int32 Function(Pointer<Uint8>, Pointer<Uint8>), int Function(Pointer<Uint8>, Pointer<Uint8>)>('link');

Pointer<Uint8> _cstr(String s) {
  final b = utf8.encode(s);
  final p = _malloc(b.length + 1);
  for (var i = 0; i < b.length; i++) {
    p[i] = b[i];
  }
  p[b.length] = 0;
  return p;
}

// 돌려주는 글은 'info' 칸으로 나간다(값이 아니라 이름만 — env 는 변수 이름 목록).
Future<String?> _one(String op, List<String> a) async {
  switch (op) {
    case 'env':
      return (Platform.environment.keys.toList()..sort()).join(',');
    case 'net': // TCP 연결(IPv4·IPv6)
      final s = await Socket.connect(a[0], int.parse(a[1]), timeout: const Duration(seconds: 4));
      s.destroy();
    case 'loopback': // 대조군: 새 루프백 포트를 열고 자기에게 연결(flutter test 가 쓰는 길) — 되어야 한다
      final srv = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final s = await Socket.connect(InternetAddress.loopbackIPv4, srv.port, timeout: const Duration(seconds: 4));
      s.destroy();
      await srv.close();
    case 'bind': // 그 포트에 대신 리슨(로컬 서비스 가로채기) — 막혀야 한다
      final srv = await ServerSocket.bind(a[0], int.parse(a[1]));
      await srv.close();
    case 'unix': // 유닉스 소켓 연결(ssh-agent·docker·mDNSResponder)
      final s = await Socket.connect(InternetAddress(a[0], type: InternetAddressType.unix), 0, timeout: const Duration(seconds: 4));
      s.destroy();
    case 'dns':
      final l = await InternetAddress.lookup(a[0]);
      if (l.isEmpty) throw 'empty';
    case 'read': // 파일이면 내용, 폴더면 목록
      if (FileSystemEntity.typeSync(a[0]) == FileSystemEntityType.directory) {
        Directory(a[0]).listSync();
      } else {
        File(a[0]).readAsBytesSync();
      }
    case 'stat': // 메타데이터만(있는지·크기) — 내용 읽기와 따로 막힌다
      File(a[0]).lengthSync();
    case 'write':
      File(a[0]).writeAsStringSync('lg-probe');
    case 'append':
      File(a[0]).writeAsStringSync('\n# lg-probe\n', mode: FileMode.append);
    case 'mkdir':
      Directory(a[0]).createSync(recursive: true);
    case 'rename':
      if (FileSystemEntity.typeSync(a[0], followLinks: false) == FileSystemEntityType.directory) {
        Directory(a[0]).renameSync(a[1]);
      } else {
        File(a[0]).renameSync(a[1]);
      }
    case 'delete':
      File(a[0]).deleteSync();
    case 'exec': // 실행 허용 목록 밖이면 여기서 막힌다
      final r = Process.runSync(a[0], a.sublist(1));
      if (r.exitCode != 0) throw 'exit ${r.exitCode}';
    case 'hardlink': // 밖 파일을 사본 안으로 하드링크(경로 검사 우회 시도)
      if (_link(_cstr(a[0]), _cstr(a[1])) != 0) throw 'link failed';
    case 'symlink-read': // 사본 안에 밖을 가리키는 바로가기를 만들고 그걸로 읽기
      Link(a[1]).createSync(a[0]);
      File(a[1]).readAsBytesSync();
    default:
      throw 'unknown op';
  }
  return null;
}

Future<void> main(List<String> args) async {
  final ops = (jsonDecode(args[0]) as List).cast<Map<String, dynamic>>();
  final out = <Map<String, Object?>>[];
  for (final o in ops) {
    final op = o['op'] as String;
    final a = ((o['a'] ?? const []) as List).map((e) => '$e').toList();
    // 격리가 막으면 OS 오류가 'Operation not permitted'(EPERM)다. 파일 권한으로 막히면 'Permission denied'(EACCES) — 둘을 구분해 낸다.
    String? err, info;
    try {
      info = await _one(op, a);
    } on FileSystemException catch (e) {
      err = '${e.runtimeType}: ${e.osError?.message ?? e.message}';
    } on SocketException catch (e) {
      err = 'SocketException: ${e.osError?.message ?? e.message.split('(').first.trim()}';
    } on ProcessException catch (e) {
      err = 'ProcessException: ${e.message}';
    } catch (e) {
      err = '${e.runtimeType}: ${'$e'.split('\n').first}';
    }
    out.add({'op': op, 'a': a, 'ok': err == null, if (err != null) 'err': err, if (info != null) 'info': info});
  }
  stdout.writeln(jsonEncode(out));
}
